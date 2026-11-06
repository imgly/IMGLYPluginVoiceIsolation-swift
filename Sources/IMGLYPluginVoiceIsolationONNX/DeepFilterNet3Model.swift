import Accelerate
import Foundation

// SPM ships the ONNX Runtime Obj-C bindings as `OnnxRuntimeBindings`, the `onnxruntime-objc` pod as `onnxruntime_objc`.
#if canImport(OnnxRuntimeBindings)
  import OnnxRuntimeBindings
#elseif canImport(onnxruntime_objc)
  import onnxruntime_objc
#endif

/// DeepFilterNet3 (Rikorose/DeepFilterNet, MIT or Apache-2.0) on its ONNX export: `enc.onnx`, `erb_dec.onnx`,
/// `df_dec.onnx` and `config.ini`. The STFT, the features and the two enhancement stages are a port of libDF
/// (`lib.rs` and `tract.rs`), with the defaults of the `deep-filter` 0.5.6 binary: no post-filter, no attenuation
/// limit.
///
/// The exported graphs have no inputs for their recurrent state, so they cannot run one frame per call. They run over
/// chunks of `chunkFrames` frames instead, each started `warmUpFrames` early so that the recurrent state settles; the
/// warm-up output is dropped. Over a whole clip the graphs would take about 16 MB per second of audio on a Mac. A
/// chunk's state differs from a whole-clip run's: on the speech-with-music test fixture, the output after a chunk
/// boundary has 34 dB SI-SDR against the upstream Python package, and the boundaries do not click. The analysis, the
/// features, the enhancement stages and the synthesis run hop by hop, like libDF's streaming loop, so ``Stream`` keeps
/// only the frames of one chunk and its warm-up. The `deep-filter` 0.5.6 binary outputs
/// zeros for every hop whose mean square is below 1e-7 (about -70 dBFS) and holds its state, so after such a hop its
/// output differs from this port, which processes every hop.
final class DeepFilterNet3Model {
  static let sampleRate = 48000
  /// 10 s per graph run, which bounds the graphs' memory.
  private static let chunkFrames = 1000
  /// 5 s of earlier frames before each chunk.
  private static let warmUpFrames = 500

  private enum Error: LocalizedError {
    case runtime
    case config(String)
    case unexpectedModel(String)
    case missingOutput(String)
    case unexpectedOutput(String)

    var errorDescription: String? {
      switch self {
      case .runtime: "ONNX Runtime or the FFT is not available."
      case let .config(key): "The DeepFilterNet3 config.ini has no usable value for \(key)."
      case let .unexpectedModel(name): "The DeepFilterNet3 model \(name) does not have the expected inputs."
      case let .missingOutput(name): "The DeepFilterNet3 model did not return \(name)."
      case let .unexpectedOutput(name): "The DeepFilterNet3 output \(name) does not have the expected size."
      }
    }
  }

  /// The values of `config.ini` that the DSP uses.
  private struct Config {
    let fftSize: Int
    let hopSize: Int
    let erbBands: Int
    let minBinsPerErbBand: Int
    /// The number of low bins that deep filtering replaces.
    let dfBins: Int
    let dfOrder: Int
    let convLookahead: Int
    let dfLookahead: Int
    /// The smoothing factor of the feature normalisation, per frame.
    let alpha: Float

    var bins: Int {
      fftSize / 2 + 1
    }

    /// The frames that the model sees after a frame before it enhances that frame.
    var lookahead: Int {
      max(convLookahead, dfLookahead)
    }

    init(contentsOf url: URL) throws {
      let sections = try Self.parse(String(contentsOf: url, encoding: .utf8))
      func value(_ key: String, in names: [String]) throws -> String {
        guard let value = names.lazy.compactMap({ sections[$0]?[key] }).first else {
          throw Error.config(key)
        }
        return value
      }
      func integer(_ key: String, in names: [String] = ["df"]) throws -> Int {
        guard let integer = try Int(value(key, in: names)) else {
          throw Error.config(key)
        }
        return integer
      }
      guard try value("model", in: ["train"]) == "deepfilternet3" else {
        throw Error.config("model")
      }
      let sampleRate = try integer("sr")
      fftSize = try integer("fft_size")
      hopSize = try integer("hop_size")
      // The analysis window is the previous hop and the current hop.
      guard sampleRate == DeepFilterNet3Model.sampleRate, hopSize > 0, fftSize == 2 * hopSize else {
        throw Error.config("sr, fft_size and hop_size")
      }
      erbBands = try integer("nb_erb")
      minBinsPerErbBand = try integer("min_nb_erb_freqs")
      dfBins = try integer("nb_df")
      dfOrder = try integer("df_order", in: ["df", "deepfilternet"])
      convLookahead = try integer("conv_lookahead", in: ["deepfilternet"])
      dfLookahead = try integer("df_lookahead", in: ["df", "deepfilternet"])
      // A self-hosted model folder can hold any values, and the arrays of the model are sized and indexed by them.
      // The normalisation states start on ramps across at least two bands and two bins.
      guard erbBands > 1, (2 ... fftSize / 2 + 1).contains(dfBins), dfOrder > 0, convLookahead >= 0,
            dfLookahead >= 0 else {
        throw Error.config("nb_erb, nb_df, df_order, conv_lookahead and df_lookahead")
      }
      if let alpha = try? Float(value("norm_alpha", in: ["df"])) {
        self.alpha = alpha
      } else {
        guard let tau = try Float(value("norm_tau", in: ["df"])), tau > 0 else {
          throw Error.config("norm_tau")
        }
        alpha = Self.normAlpha(sampleRate: sampleRate, hopSize: hopSize, tau: tau)
      }
      // A factor of 0 or below keeps no state, and one of 1 or above never lets the state follow the audio.
      guard alpha > 0, alpha < 1 else {
        throw Error.config("norm_alpha and norm_tau")
      }
    }

    /// `calc_norm_alpha` in `tract.rs`: `exp(-hop / sr / tau)`, rounded to the fewest decimals that keep it below 1.
    private static func normAlpha(sampleRate: Int, hopSize: Int, tau: Float) -> Float {
      let alpha = exp(-Float(hopSize) / Float(sampleRate) / tau)
      var rounded: Float = 1
      var precision: Float = 1000
      while rounded >= 1 {
        rounded = (alpha * precision).rounded() / precision
        precision *= 10
      }
      return rounded
    }

    private static func parse(_ text: String) -> [String: [String: String]] {
      var sections: [String: [String: String]] = [:]
      var section = ""
      for line in text.split(whereSeparator: \.isNewline) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("["), trimmed.hasSuffix("]") {
          section = String(trimmed.dropFirst().dropLast())
        } else if let equals = trimmed.firstIndex(of: "=") {
          let key = trimmed[..<equals].trimmingCharacters(in: .whitespaces)
          sections[section, default: [:]][key] = trimmed[trimmed.index(after: equals)...]
            .trimmingCharacters(in: .whitespaces)
        }
      }
      return sections
    }
  }

  /// One analysed hop: its spectrum, scaled as in libDF, and its graph inputs.
  private struct Frame {
    let real: [Float]
    let imaginary: [Float]
    let erb: [Float]
    /// The normalised low `dfBins` bins.
    let spectrumReal: [Float]
    let spectrumImaginary: [Float]
  }

  /// The model outputs per frame: ERB band gains and complex deep filter coefficients in the layout
  /// `[frames, dfBins, dfOrder, 2]`.
  private struct Estimates {
    let gains: [Float]
    let coefficients: [Float]
  }

  private let config: Config
  private let encoder: ORTSession
  private let erbDecoder: ORTSession
  private let dfDecoder: ORTSession
  private let fft: RealFFT
  /// The Vorbis window `sin(pi / 2 * sin^2(pi * (n + 0.5) / (fftSize / 2)))`, for analysis and synthesis.
  private let window: [Float]
  /// The number of FFT bins in each ERB band, lowest band first.
  private let erbWidths: [Int]

  /// The one ONNX Runtime environment of the plugin, as ONNX Runtime recommends. The Obj-C class is not `Sendable`.
  private nonisolated(unsafe) static let environment = try? ORTEnv(loggingLevel: .warning)

  /// The files of the model folder.
  static let files = ["enc.onnx", "erb_dec.onnx", "df_dec.onnx", "config.ini"]

  init(directory: URL) throws {
    config = try Config(contentsOf: directory.appendingPathComponent("config.ini"))
    guard let environment = Self.environment, let fft = RealFFT(size: config.fftSize) else {
      throw Error.runtime
    }
    let options = try ORTSessionOptions()
    try options.setIntraOpNumThreads(1)
    // Enables the shrinkage that each run requests, so the editor does not keep the memory of a run.
    try options.addConfigEntry(withKey: "memory.enable_memory_arena_shrinkage", value: "cpu:0")
    func session(_ name: String, inputs: Set<String>) throws -> ORTSession {
      let path = directory.appendingPathComponent(name).path
      let session = try ORTSession(env: environment, modelPath: path, sessionOptions: options)
      guard try Set(session.inputNames()) == inputs else {
        throw Error.unexpectedModel(name)
      }
      return session
    }
    encoder = try session("enc.onnx", inputs: ["feat_erb", "feat_spec"])
    erbDecoder = try session("erb_dec.onnx", inputs: ["emb", "e3", "e2", "e1", "e0"])
    dfDecoder = try session("df_dec.onnx", inputs: ["emb", "c0"])
    self.fft = fft
    let half = Double(config.fftSize / 2)
    window = (0 ..< config.fftSize).map { index in
      let inner = sin(0.5 * Double.pi * (Double(index) + 0.5) / half)
      return Float(sin(0.5 * Double.pi * inner * inner))
    }
    erbWidths = try Self.erbWidths(config)
    // The enhancement of a frame reads the spectra of the frames before it, which the warm-up of a chunk holds.
    guard max(config.dfOrder, config.lookahead) <= Self.warmUpFrames else {
      throw Error.config("df_order, conv_lookahead and df_lookahead")
    }
  }

  // MARK: - Stream

  /// Enhances one mono 48 kHz channel piece by piece, so that the memory does not grow with the length of the clip.
  /// Gives the output of a run over the whole channel: the analysis, the features and the overlap-add carry their state
  /// from piece to piece, and the graphs run on the same chunks.
  final class Stream {
    private let model: DeepFilterNet3Model
    private let chunkFrames: Int
    private let warmUpFrames: Int
    /// The output lags the input by the STFT overlap.
    private let stftDelay: Int
    private var hopInput: [Float] = []
    private var analysisBuffer: [Float]
    private var meanState: [Float]
    private var unitState: [Float]
    /// The last `warmUpFrames` frames before `pending`: the warm-up of the next chunk and the deep filter's history.
    private var history: [Frame] = []
    private var pending: [Frame] = []
    /// The index in the clip of the first frame of `history + pending`.
    private var firstFrame = 0
    /// The overlap-add of the frames that come next, from sample `synthesised` on.
    private var overlap: [Float]
    private var synthesised = 0
    private var inputLength = 0
    private var returned = 0

    init(model: DeepFilterNet3Model, chunkFrames: Int = DeepFilterNet3Model.chunkFrames,
         warmUpFrames: Int = DeepFilterNet3Model.warmUpFrames) {
      let config = model.config
      // The enhancement of a frame reads the spectra of up to `max(dfOrder, lookahead)` frames before it.
      precondition(chunkFrames > 0 && warmUpFrames >= max(config.dfOrder, config.lookahead))
      self.model = model
      self.chunkFrames = chunkFrames
      self.warmUpFrames = warmUpFrames
      stftDelay = config.fftSize - config.hopSize
      // The first hop of the first frame is the zeroed analysis memory.
      analysisBuffer = [Float](repeating: 0, count: config.fftSize)
      // libDF starts the normalisation states on fixed ramps across the bands.
      meanState = (0 ..< config.erbBands).map { -60 - 30 * Float($0) / Float(config.erbBands - 1) }
      unitState = (0 ..< config.dfBins).map { 0.001 - 0.0009 * Float($0) / Float(config.dfBins - 1) }
      overlap = [Float](repeating: 0, count: config.fftSize)
    }

    /// Takes the next samples of the channel and returns the output that is final, aligned with the input.
    func process(_ samples: [Float]) throws -> [Float] {
      inputLength += samples.count
      var output: [Float] = []
      try feed(samples, into: &output)
      return output
    }

    /// Returns the rest of the output, so that the whole output is as long as the whole input.
    func finish() throws -> [Float] {
      var output: [Float] = []
      // The model needs `lookahead` frames after the last one, and the overlap-add holds the last `stftDelay` samples.
      let padding = stftDelay + (model.config.lookahead + 1) * model.config.hopSize
      try feed([Float](repeating: 0, count: padding), into: &output)
      if !pending.isEmpty {
        try runChunk(into: &output)
      }
      // The frames after the last enhanced one are silent, so the rest of the overlap-add is final.
      emit(overlap[...], into: &output)
      let missing = inputLength - returned
      if missing > 0 {
        output += [Float](repeating: 0, count: missing)
        returned += missing
      }
      return output
    }

    private func feed(_ samples: [Float], into output: inout [Float]) throws {
      let hop = model.config.hopSize
      var start = 0
      while start < samples.count {
        let end = min(samples.count, start + hop - hopInput.count)
        hopInput += samples[start ..< end]
        start = end
        guard hopInput.count == hop else { continue }
        analyse()
        hopInput.removeAll(keepingCapacity: true)
        if pending.count == chunkFrames {
          try runChunk(into: &output)
        }
      }
    }

    /// `frame_analysis`, `feat_erb` and `feat_cplx` in `lib.rs` for the hop in `hopInput`.
    private func analyse() {
      let config = model.config
      let bins = config.bins
      // `frame_analysis` scales the FFT by `2 * hop / fftSize^2`.
      let scale = Float(2 * config.hopSize) / Float(config.fftSize * config.fftSize)
      analysisBuffer.removeFirst(config.hopSize)
      analysisBuffer += hopInput
      let spectrum = model.fft.forward(vDSP.multiply(analysisBuffer, model.window))
      let real = (0 ..< bins).map { spectrum.real[$0] * scale }
      let imaginary = (0 ..< bins).map { spectrum.imaginary[$0] * scale }
      let alpha = config.alpha
      var erb = [Float](repeating: 0, count: config.erbBands)
      var start = 0
      for (band, width) in model.erbWidths.enumerated() {
        var power: Float = 0
        for bin in start ..< start + width {
          power += real[bin] * real[bin] + imaginary[bin] * imaginary[bin]
        }
        start += width
        let decibels = 10 * log10(power / Float(width) + 1e-10)
        meanState[band] = decibels * (1 - alpha) + meanState[band] * alpha
        erb[band] = (decibels - meanState[band]) / 40
      }
      var spectrumReal = [Float](repeating: 0, count: config.dfBins)
      var spectrumImaginary = [Float](repeating: 0, count: config.dfBins)
      for bin in 0 ..< config.dfBins {
        unitState[bin] = (real[bin] * real[bin] + imaginary[bin] * imaginary[bin]).squareRoot() * (1 - alpha)
          + unitState[bin] * alpha
        let norm = unitState[bin].squareRoot()
        spectrumReal[bin] = real[bin] / norm
        spectrumImaginary[bin] = imaginary[bin] / norm
      }
      pending.append(Frame(real: real, imaginary: imaginary, erb: erb, spectrumReal: spectrumReal,
                           spectrumImaginary: spectrumImaginary))
    }

    /// Runs the graphs over the pending frames after the history as warm-up, and enhances and synthesises the frames
    /// whose estimates are now known.
    private func runChunk(into output: inout [Float]) throws {
      try Task.checkCancellation()
      let frames = history + pending
      let estimates = try model.estimate(frames)
      let lookahead = model.config.convLookahead
      let chunkStart = firstFrame + history.count
      let chunkEnd = firstFrame + frames.count
      // The model output of frame `t` belongs to frame `t - convLookahead`.
      for frame in max(chunkStart, lookahead) ..< chunkEnd {
        let enhanced = model.enhance(frame - lookahead, frames: frames, firstFrame: firstFrame, estimates: estimates,
                                     estimate: frame - firstFrame)
        synthesise(enhanced, into: &output)
      }
      history = Array(frames.suffix(warmUpFrames))
      firstFrame = chunkEnd - history.count
      pending.removeAll(keepingCapacity: true)
    }

    /// `frame_synthesis` in `lib.rs`: the unscaled inverse FFT, the window, and overlap-add. The frames arrive in
    /// order, so the first hop of `overlap` is final after each one.
    private func synthesise(_ spectrum: (real: [Float], imaginary: [Float]), into output: inout [Float]) {
      let config = model.config
      // RealFFT.inverse divides by fftSize like numpy, and libDF's inverse does not.
      let block = vDSP.multiply(model.fft.inverse(real: spectrum.real, imaginary: spectrum.imaginary),
                                vDSP.multiply(Float(config.fftSize), model.window))
      for index in 0 ..< config.fftSize {
        overlap[index] += block[index]
      }
      emit(overlap[..<config.hopSize], into: &output)
      overlap.removeFirst(config.hopSize)
      overlap += [Float](repeating: 0, count: config.hopSize)
    }

    /// Returns the synthesised `samples` that fall into the input's span, after the STFT delay.
    private func emit(_ samples: ArraySlice<Float>, into output: inout [Float]) {
      let first = max(0, stftDelay - synthesised)
      synthesised += samples.count
      guard first < samples.count else { return }
      let count = min(samples.count - first, max(0, inputLength - returned))
      output += samples[samples.startIndex + first ..< samples.startIndex + first + count]
      returned += count
    }
  }

  // MARK: - Graphs

  /// The three graphs over `frames`. The graphs are causal, so a chunk needs no later frames.
  private func estimate(_ frames: [Frame]) throws -> Estimates {
    let count = frames.count
    let dfBins = config.dfBins
    let erb = frames.flatMap(\.erb)
    // `[1, 2, frames, dfBins]`: all real parts, then all imaginary parts.
    let spectrum = frames.flatMap(\.spectrumReal) + frames.flatMap(\.spectrumImaginary)
    // ONNX Runtime's Objective-C calls leave autoreleased objects, so each chunk drains its own pool.
    return try autoreleasepool {
      let encoded = try run(encoder, inputs: [
        "feat_erb": Self.tensor(erb, shape: [1, 1, count, config.erbBands]),
        "feat_spec": Self.tensor(spectrum, shape: [1, 2, count, dfBins]),
      ], outputs: ["e0", "e1", "e2", "e3", "emb", "c0"])
      let gains = try run(erbDecoder, inputs: encoded.filter { $0.key != "c0" }, outputs: ["m"])
      let coefficients = try run(dfDecoder, inputs: encoded.filter { ["emb", "c0"].contains($0.key) },
                                 outputs: ["coefs"])
      return try Estimates(gains: Self.floats(gains, "m", count: count * config.erbBands),
                           coefficients: Self.floats(
                             coefficients,
                             "coefs",
                             count: count * dfBins * config.dfOrder * 2,
                           ))
    }
  }

  /// `DfTract::process` for `target`, with the estimate at index `estimate` of `estimates`. Stage 1 applies the ERB
  /// gains to all bins. Stage 2 replaces the low `dfBins` bins with the deep filter over the noisy frames up to the
  /// estimate's frame. With the binary's thresholds both stages run on every frame, because the model's local SNR stays
  /// inside them. `frames` starts at frame `firstFrame` of the clip.
  private func enhance(_ target: Int, frames: [Frame], firstFrame: Int, estimates: Estimates,
                       estimate: Int) -> (real: [Float], imaginary: [Float]) {
    let source = frames[target - firstFrame]
    var real = [Float](repeating: 0, count: config.bins)
    var imaginary = [Float](repeating: 0, count: config.bins)
    var bin = 0
    for (band, width) in erbWidths.enumerated() {
      let gain = estimates.gains[estimate * config.erbBands + band]
      for _ in 0 ..< width {
        real[bin] = source.real[bin] * gain
        imaginary[bin] = source.imaginary[bin] * gain
        bin += 1
      }
    }
    let order = config.dfOrder
    // libDF keeps this many noisy frames for the deep filter and applies the coefficients to the oldest `order`.
    let history = max(order, config.lookahead)
    let frame = firstFrame + estimate
    for bin in 0 ..< config.dfBins {
      var filteredReal: Float = 0
      var filteredImaginary: Float = 0
      for tap in 0 ..< order {
        // Frames before the start are the zeroed history.
        let noisyFrame = frame - history + 1 + tap
        guard noisyFrame >= 0 else { continue }
        let coefficient = ((estimate * config.dfBins + bin) * order + tap) * 2
        let noisy = frames[noisyFrame - firstFrame]
        let noisyReal = noisy.real[bin]
        let noisyImaginary = noisy.imaginary[bin]
        let coefficientReal = estimates.coefficients[coefficient]
        let coefficientImaginary = estimates.coefficients[coefficient + 1]
        filteredReal += noisyReal * coefficientReal - noisyImaginary * coefficientImaginary
        filteredImaginary += noisyReal * coefficientImaginary + noisyImaginary * coefficientReal
      }
      real[bin] = filteredReal
      imaginary[bin] = filteredImaginary
    }
    return (real, imaginary)
  }

  private func run(_ session: ORTSession, inputs: [String: ORTValue],
                   outputs: Set<String>) throws -> [String: ORTValue] {
    // Hands the memory of the run back to the system, otherwise ONNX Runtime keeps it for the next run.
    let runOptions = try ORTRunOptions()
    try runOptions.addConfigEntry(withKey: "memory.enable_memory_arena_shrinkage", value: "cpu:0")
    let results = try session.run(withInputs: inputs, outputNames: outputs, runOptions: runOptions)
    for output in outputs where results[output] == nil {
      throw Error.missingOutput(output)
    }
    return results
  }

  /// `erb_fb` in `lib.rs`: bands of equal width on the ERB scale, at least `minBinsPerErbBand` bins each, together
  /// covering all bins.
  private static func erbWidths(_ config: Config) throws -> [Int] {
    func erb(_ frequency: Float) -> Float {
      9.265 * log1p(frequency / (24.7 * 9.265))
    }
    func frequency(_ erb: Float) -> Float {
      24.7 * 9.265 * (exp(erb / 9.265) - 1)
    }
    let binWidth = Float(sampleRate) / Float(config.fftSize)
    let step = erb(Float(sampleRate / 2)) / Float(config.erbBands)
    var widths: [Int] = []
    var previous = 0
    // Bins that the previous band took to reach its minimum width.
    var borrowed = 0
    for band in 1 ... config.erbBands {
      let edge = Int((frequency(Float(band) * step) / binWidth).rounded())
      var width = edge - previous - borrowed
      if width < config.minBinsPerErbBand {
        borrowed = config.minBinsPerErbBand - width
        width = config.minBinsPerErbBand
      } else {
        borrowed = 0
      }
      widths.append(width)
      previous = edge
    }
    // The bands cover the Nyquist bin too, and the minimum width can push the sum past the bin count.
    widths[widths.count - 1] += 1
    let excess = widths.reduce(0, +) - config.bins
    if excess > 0 {
      widths[widths.count - 1] -= excess
    }
    guard widths.allSatisfy({ $0 > 0 }), widths.reduce(0, +) == config.bins else {
      throw Error.config("nb_erb and min_nb_erb_freqs")
    }
    return widths
  }

  private static func tensor(_ values: [Float], shape: [Int]) throws -> ORTValue {
    let data = values.withUnsafeBufferPointer {
      NSMutableData(bytes: $0.baseAddress, length: $0.count * MemoryLayout<Float>.stride)
    }
    return try ORTValue(tensorData: data, elementType: .float, shape: shape.map { NSNumber(value: $0) })
  }

  /// Copies an output tensor, because its data belongs to the ORTValue.
  private static func floats(_ results: [String: ORTValue], _ name: String, count: Int) throws -> [Float] {
    guard let data = try results[name]?.tensorData(), data.length == count * MemoryLayout<Float>.stride else {
      throw Error.unexpectedOutput(name)
    }
    return Array(UnsafeBufferPointer(start: data.bytes.assumingMemoryBound(to: Float.self), count: count))
  }
}
