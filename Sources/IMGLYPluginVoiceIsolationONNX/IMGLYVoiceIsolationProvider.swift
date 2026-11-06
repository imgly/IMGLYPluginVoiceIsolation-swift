import AVFoundation
import IMGLYPluginVoiceIsolationCore

// MARK: - Provider

/// IMG.LY's on-device voice isolation backend: DeepFilterNet3, on each channel at 48 kHz.
///
/// It writes a 16-bit PCM WAV file at 48 kHz with the channel count of the input, and runs its model on one file after
/// the other. To run your own model first, write its result in the input format of ``VoiceIsolationProvider`` and pass
/// that file to ``isolateVoice(from:to:)``.
public struct IMGLYVoiceIsolationProvider: VoiceIsolationProvider {
  private let model: ModelHolder
  private let loadMode: IMGLYVoiceIsolationConfiguration.LoadMode

  /// Creates the provider.
  /// - Parameters:
  ///   - modelBaseURL: The folder to load the model files from.
  ///   - loadMode: When to download and load the model.
  public init(
    modelBaseURL: URL = IMGLYVoiceIsolationConfiguration.defaultModelBaseURL,
    loadMode: IMGLYVoiceIsolationConfiguration.LoadMode = .eager,
  ) {
    model = ModelHolder(modelBaseURL: modelBaseURL)
    self.loadMode = loadMode
  }

  public func prewarm() async throws {
    guard loadMode == .eager else { return }
    try await model.load()
  }

  public func isolateVoice(from input: URL, to output: URL) async throws {
    try await model.isolateVoice(from: input, to: output)
  }
}

// MARK: - Model Holder

/// Loads the model once, and runs it on one file at a time. A failed load is not kept, so the next call retries it.
private actor ModelHolder {
  private let modelBaseURL: URL
  private var directoryTask: Task<URL, Error>?
  private var model: DeepFilterNet3Model?

  init(modelBaseURL: URL) {
    self.modelBaseURL = modelBaseURL
  }

  func load() async throws {
    _ = try await loadedModel()
  }

  func isolateVoice(from input: URL, to output: URL) async throws {
    // Checks the input first, so that a file the model cannot take fails without a model download.
    let file = try AVAudioFile(forReading: input)
    guard Int(file.processingFormat.sampleRate) == DeepFilterNet3Model.sampleRate else {
      throw VoiceIsolationError
        .processingFailed("The input has \(Int(file.processingFormat.sampleRate)) Hz, not 48 kHz.")
    }
    guard file.length > 0 else {
      throw VoiceIsolationError.noAudio
    }
    let model = try await loadedModel()
    try Task.checkCancellation()
    do {
      try Self.enhance(file, with: model, to: output)
    } catch let error as CancellationError {
      throw error
    } catch {
      throw VoiceIsolationError.processingFailed(error.localizedDescription)
    }
  }

  private func loadedModel() async throws -> DeepFilterNet3Model {
    if let model {
      return model
    }
    let task = directoryTask ?? Task { [modelBaseURL] in
      try await ModelDownloader.resolve(modelBaseURL)
    }
    directoryTask = task
    let directory: URL
    do {
      directory = try await task.value
    } catch {
      // A newer task can replace this one while it runs, so only this task is cleared.
      if directoryTask == task {
        directoryTask = nil
      }
      throw error
    }
    // Another call can load the model during the wait.
    if let model {
      return model
    }
    do {
      let loaded = try DeepFilterNet3Model(directory: directory)
      model = loaded
      return loaded
    } catch {
      // A download can bring wrong files with HTTP 200, such as the login page of a hotspot, so the next call
      // downloads them again.
      if directoryTask == task {
        directoryTask = nil
      }
      if !modelBaseURL.isFileURL {
        try? FileManager.default.removeItem(at: directory)
      }
      throw VoiceIsolationError.modelDownloadFailed(error.localizedDescription)
    }
  }

  /// Enhances `input` one second at a time into a 16-bit WAV file at `url`, one stream per channel, so that the memory
  /// does not grow with the length of the file.
  private static func enhance(_ input: AVAudioFile, with model: DeepFilterNet3Model, to url: URL) throws {
    let format = input.processingFormat
    let streams = (0 ..< Int(format.channelCount)).map { _ in DeepFilterNet3Model.Stream(model: model) }
    let output = try AVAudioFile(forWriting: url, settings: [
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVSampleRateKey: format.sampleRate,
      AVNumberOfChannelsKey: streams.count,
      AVLinearPCMBitDepthKey: 16,
      AVLinearPCMIsFloatKey: false,
      AVLinearPCMIsBigEndianKey: false,
    ], commonFormat: .pcmFormatFloat32, interleaved: false)
    let blockFrames = AVAudioFrameCount(DeepFilterNet3Model.sampleRate)
    guard let block = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: blockFrames),
          let channels = block.floatChannelData else {
      throw VoiceIsolationError.processingFailed("Could not allocate an audio buffer.")
    }
    while input.framePosition < input.length {
      try input.read(into: block, frameCount: blockFrames)
      let samples = (0 ..< streams.count).map { Array(UnsafeBufferPointer(
        start: channels[$0],
        count: Int(block.frameLength),
      )) }
      try write(zip(streams, samples).map { try $0.process($1) }, to: output)
    }
    try write(streams.map { try $0.finish() }, to: output)
  }

  /// Appends one piece of every channel. The streams return pieces of the same length, because they run in step.
  private static func write(_ channels: [[Float]], to file: AVAudioFile) throws {
    guard let count = channels.first?.count, count > 0 else { return }
    guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(count)),
          let bufferChannels = buffer.floatChannelData else {
      throw VoiceIsolationError.processingFailed("Could not allocate an audio buffer.")
    }
    buffer.frameLength = buffer.frameCapacity
    for (channel, samples) in channels.enumerated() {
      samples.withUnsafeBufferPointer { samples in
        guard let start = samples.baseAddress else { return }
        bufferChannels[channel].update(from: start, count: count)
      }
    }
    try file.write(from: buffer)
  }
}
