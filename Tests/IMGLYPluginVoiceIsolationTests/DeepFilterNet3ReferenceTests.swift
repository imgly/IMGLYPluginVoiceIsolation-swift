import AVFoundation
@testable import IMGLYPluginVoiceIsolationONNX
import XCTest

/// Compares IMG.LY's DeepFilterNet3 port with the upstream DeepFilterNet 0.5.6 Python package.
///
/// The model comes from `IMGLY_VOICE_ISOLATION_MODEL_URL` (a `file://` or `https://` folder with the model files), or
/// from the default CDN folder. With `xcodebuild`, pass it as `TEST_RUNNER_IMGLY_VOICE_ISOLATION_MODEL_URL`.
final class DeepFilterNet3ReferenceTests: XCTestCase {
  private var outputs: [URL] = []

  override func tearDown() {
    for output in outputs {
      try? FileManager.default.removeItem(at: output)
    }
    super.tearDown()
  }

  // @requirement(voice-isolation/isolate-voice/speech-kept-music-removed)
  // @requirement(voice-isolation/isolator-integration/model-location)
  /// 12 s of speech with music, so the port runs two graph chunks. `make_reference.py` wrote the reference.
  func testOutputMatchesThePythonReference() async throws {
    let provider = IMGLYVoiceIsolationProvider(modelBaseURL: try Self.modelBaseURL(), loadMode: .lazy)
    let input = try fixture("speech-and-music.flac")
    let output = temporaryFile("wav")

    try await provider.isolateVoice(from: input, to: output)

    let reference = try samples(of: fixture("speech-and-music-reference.flac"))
    let cleaned = try samples(of: output)
    XCTAssertEqual(cleaned.count, 1)
    XCTAssertEqual(cleaned[0].count, reference[0].count)
    let format = try AVAudioFile(forReading: output).fileFormat
    XCTAssertEqual(format.sampleRate, 48000)
    XCTAssertEqual(format.settings[AVLinearPCMBitDepthKey] as? Int, 16)
    // Both start from silent state, so the first 0.5 s is left out. After the 10 s chunk boundary the port runs the
    // graphs from a 5 s warm-up instead of from the start, so it differs more there.
    let start = 24000
    let boundary = 10 * 48000
    let firstChunk = siSDR(Array(cleaned[0][start ..< boundary]), reference: Array(reference[0][start ..< boundary]))
    let secondChunk = siSDR(Array(cleaned[0][boundary...]), reference: Array(reference[0][boundary...]))
    XCTAssertGreaterThan(firstChunk, 35, "SI-SDR against the Python reference in the first chunk: \(firstChunk) dB")
    XCTAssertGreaterThan(secondChunk, 30, "SI-SDR against the Python reference after the boundary: \(secondChunk) dB")
  }

  /// The stream carries its state from piece to piece, so the size of the pieces does not change the output. Short
  /// chunks make the 12 s fixture run the graphs six times.
  func testStreamGivesTheSameOutputForPiecesOfAnySize() async throws {
    let model = try await DeepFilterNet3Model(directory: ModelDownloader.resolve(Self.modelBaseURL()))
    let input = try samples(of: fixture("speech-and-music.flac"))[0]
    func output(pieces: Int) throws -> [Float] {
      let stream = DeepFilterNet3Model.Stream(model: model, chunkFrames: 200, warmUpFrames: 100)
      var output = [Float]()
      for start in stride(from: 0, to: input.count, by: pieces) {
        output += try stream.process(Array(input[start ..< min(input.count, start + pieces)]))
      }
      return try output + stream.finish()
    }

    let whole = try output(pieces: input.count)

    XCTAssertEqual(whole.count, input.count)
    XCTAssertEqual(try output(pieces: 48000), whole)
    XCTAssertEqual(try output(pieces: 997), whole)
  }

  // @requirement(voice-isolation/isolate-voice/speech-after-silence)
  /// 100 s of digital silence before the fixture, as in a muted part of a clip. The speech starts at a chunk boundary
  /// after 5 s of silent warm-up, so the threshold is lower than in the test above.
  func testSpeechAfterLongDigitalSilenceMatchesThePythonReference() async throws {
    let provider = IMGLYVoiceIsolationProvider(modelBaseURL: try Self.modelBaseURL(), loadMode: .lazy)
    let speech = try samples(of: fixture("speech-and-music.flac"))[0]
    let silence = 100 * 48000
    let input = temporaryFile("wav")
    try write([Float](repeating: 0, count: silence) + speech, to: input)
    let output = temporaryFile("wav")

    try await provider.isolateVoice(from: input, to: output)

    let cleaned = try samples(of: output)[0]
    XCTAssertEqual(cleaned.count, silence + speech.count)
    // The analysis window and the model's lookahead reach back into the last frames of the silence.
    XCTAssertEqual(cleaned[..<(silence - 48000)].map(abs).max(), 0)
    // The Python package's output for the same silence and speech, from `make_reference.py --leading-silence 100`.
    let reference = try samples(of: fixture("speech-and-music-after-silence-reference.flac"))[0]
    let measured = siSDR(Array(cleaned[(silence + 24000)...]), reference: Array(reference[24000...]))
    XCTAssertGreaterThan(measured, 25, "SI-SDR of the speech after the silence: \(measured) dB")
  }

  // @requirement(voice-isolation/changes-and-errors/model-unavailable)
  func testMissingBundledModelFailsWithModelDownloadFailed() async throws {
    let emptyFolder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: emptyFolder, withIntermediateDirectories: true)
    outputs.append(emptyFolder)
    let provider = IMGLYVoiceIsolationProvider(modelBaseURL: emptyFolder, loadMode: .lazy)

    do {
      try await provider.isolateVoice(from: fixture("speech-and-music.flac"), to: temporaryFile("wav"))
      XCTFail("The provider ran without a model.")
    } catch VoiceIsolationError.modelDownloadFailed {}
  }

  func testConfigWithBandsWiderThanTheSpectrumFailsWithModelDownloadFailed() async throws {
    try await assertModelDownloadFails(replacing: "min_nb_erb_freqs = 2", with: "min_nb_erb_freqs = 20",
                                       "32 bands of at least 20 bins each fit into 481 bins.")
  }

  func testConfigWithValuesOutOfRangeFailsWithModelDownloadFailed() async throws {
    try await assertModelDownloadFails(replacing: "nb_erb = 32", with: "nb_erb = 0", "No ERB band.")
    try await assertModelDownloadFails(replacing: "nb_df = 96", with: "nb_df = 482", "More deep-filter bins than 481.")
    try await assertModelDownloadFails(replacing: "df_order = 5", with: "df_order = 0", "No deep-filter order.")
    try await assertModelDownloadFails(replacing: "nb_erb = 32", with: "nb_erb = 1", "One ERB band has no ramp.")
    try await assertModelDownloadFails(replacing: "nb_df = 96", with: "nb_df = 1", "One deep-filter bin has no ramp.")
    try await assertModelDownloadFails(replacing: "norm_tau = 1", with: "norm_tau = -1", "A negative constant.")
    try await assertModelDownloadFails(replacing: "norm_tau = 1", with: "norm_alpha = 1", "A factor that never moves.")
  }

  /// Cleans a clip with a copy of the model whose `config.ini` has `original` replaced, and expects the model error.
  private func assertModelDownloadFails(replacing original: String, with replacement: String, _ message: String,
                                        file: StaticString = #filePath, line: UInt = #line) async throws {
    let model = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    outputs.append(model)
    try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
    let source = try Self.modelBaseURL()
    for file in DeepFilterNet3Model.files {
      try Data(contentsOf: source.appendingPathComponent(file)).write(to: model.appendingPathComponent(file))
    }
    let config = model.appendingPathComponent("config.ini")
    let text = try String(contentsOf: config, encoding: .utf8)
    XCTAssertTrue(text.contains(original), "The config has no \(original).", file: file, line: line)
    try text.replacingOccurrences(of: original, with: replacement).write(to: config, atomically: true, encoding: .utf8)
    let provider = IMGLYVoiceIsolationProvider(modelBaseURL: model, loadMode: .lazy)

    do {
      try await provider.isolateVoice(from: fixture("speech-and-music.flac"), to: temporaryFile("wav"))
      XCTFail(message, file: file, line: line)
    } catch VoiceIsolationError.modelDownloadFailed {}
  }

  // @requirement(voice-isolation/changes-and-errors/cancelled-run)
  func testCancelledRunStopsBetweenChunks() async throws {
    let provider = IMGLYVoiceIsolationProvider(modelBaseURL: try Self.modelBaseURL(), loadMode: .eager)
    try await provider.prewarm()
    let input = temporaryFile("wav")
    try writeSilence(seconds: 300, extraFrames: 0, to: input)
    let output = temporaryFile("wav")

    let run = Task { try await provider.isolateVoice(from: input, to: output) }
    try await Task.sleep(for: .milliseconds(500))
    run.cancel()

    let result = await run.result
    XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError, "\($0)") }
  }

  // @requirement(voice-isolation/changes-and-errors/model-unavailable)
  // @requirement(voice-isolation/isolator-integration/model-location)
  func testModelThatFailsToLoadIsDownloadedAgain() async throws {
    ModelServer.source = nil
    URLProtocol.registerClass(ModelServer.self)
    addTeardownBlock { URLProtocol.unregisterClass(ModelServer.self) }
    let provider = IMGLYVoiceIsolationProvider(modelBaseURL: ModelServer.baseURL, loadMode: .eager)

    do {
      try await provider.prewarm()
      XCTFail("A login page loaded as the model.")
    } catch VoiceIsolationError.modelDownloadFailed {}

    ModelServer.source = try Self.modelBaseURL()
    try await provider.prewarm()
  }

  // MARK: - Helpers

  private static func modelBaseURL() throws -> URL {
    guard let value = ProcessInfo.processInfo.environment["IMGLY_VOICE_ISOLATION_MODEL_URL"] else {
      return IMGLYVoiceIsolationConfiguration.defaultModelBaseURL
    }
    return try XCTUnwrap(value.hasPrefix("/") ? URL(fileURLWithPath: value) : URL(string: value))
  }

  private func fixture(_ name: String) throws -> URL {
    try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil))
  }

  private func temporaryFile(_ fileExtension: String) -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      .appendingPathExtension(fileExtension)
    outputs.append(url)
    return url
  }

  private func samples(of url: URL) throws -> [[Float]] {
    let file = try AVAudioFile(forReading: url)
    let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                frameCapacity: AVAudioFrameCount(file.length)))
    try file.read(into: buffer)
    let channels = try XCTUnwrap(buffer.floatChannelData)
    return (0 ..< Int(file.processingFormat.channelCount)).map {
      Array(UnsafeBufferPointer(start: channels[$0], count: Int(buffer.frameLength)))
    }
  }

  private func write(_ samples: [Float], to url: URL) throws {
    let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
    let file = try AVAudioFile(forWriting: url, settings: [
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVSampleRateKey: 48000,
      AVNumberOfChannelsKey: 1,
      AVLinearPCMBitDepthKey: 16,
      AVLinearPCMIsFloatKey: false,
    ])
    let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)))
    buffer.frameLength = buffer.frameCapacity
    samples.withUnsafeBufferPointer { source in
      buffer.floatChannelData?[0].update(from: source.baseAddress!, count: samples.count)
    }
    try file.write(from: buffer)
  }

  private func writeSilence(seconds: Int, extraFrames: Int, to url: URL) throws {
    let file = try AVAudioFile(forWriting: url, settings: [
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVSampleRateKey: 48000,
      AVNumberOfChannelsKey: 1,
      AVLinearPCMBitDepthKey: 16,
      AVLinearPCMIsFloatKey: false,
    ])
    let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 48000))
    buffer.frameLength = buffer.frameCapacity
    for _ in 0 ..< seconds {
      try file.write(from: buffer)
    }
    buffer.frameLength = AVAudioFrameCount(extraFrames)
    try file.write(from: buffer)
  }

  /// Scale-invariant SDR in dB, with the mean of both signals removed.
  private func siSDR(_ estimate: [Float], reference: [Float]) -> Double {
    let estimateMean = estimate.reduce(0) { $0 + Double($1) } / Double(estimate.count)
    let referenceMean = reference.reduce(0) { $0 + Double($1) } / Double(reference.count)
    var dot = 0.0
    var referenceEnergy = 0.0
    for (sample, target) in zip(estimate, reference) {
      dot += (Double(sample) - estimateMean) * (Double(target) - referenceMean)
      referenceEnergy += (Double(target) - referenceMean) * (Double(target) - referenceMean)
    }
    let scale = dot / referenceEnergy
    var targetEnergy = 0.0
    var noiseEnergy = 0.0
    for (sample, target) in zip(estimate, reference) {
      let projected = scale * (Double(target) - referenceMean)
      targetEnergy += projected * projected
      noiseEnergy += (Double(sample) - estimateMean - projected) * (Double(sample) - estimateMean - projected)
    }
    return 10 * log10(targetEnergy / noiseEnergy)
  }
}

/// Serves the model files of `source` under `baseURL`. Without `source`, it answers each file with a login page and
/// HTTP 200, as the network of a hotspot does.
private final class ModelServer: URLProtocol {
  static let baseURL = URL(string: "https://model.test/\(UUID().uuidString)")!
  nonisolated(unsafe) static var source: URL?

  override static func canInit(with request: URLRequest) -> Bool {
    request.url?.host == baseURL.host
  }

  override static func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    guard let url = request.url, let client else { return }
    let data = Self.source.flatMap { try? Data(contentsOf: $0.appendingPathComponent(url.lastPathComponent)) }
      ?? Data("<html>Log in to use this network.</html>".utf8)
    if let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) {
      client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    }
    client.urlProtocol(self, didLoad: data)
    client.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}
