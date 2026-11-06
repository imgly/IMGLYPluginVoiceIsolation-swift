import Foundation

/// A backend that removes music and noise from the speech in an audio file.
///
/// Adopt this protocol to plug in your own model, a server or a commercial service, and pair the provider with a
/// ``VoiceIsolationConfiguration`` conformer to use it with ``VoiceIsolationPlugin``. To run your own model before
/// IMG.LY's, write its result to a file in the format of `input` and pass that file to `IMGLYVoiceIsolationProvider`.
public protocol VoiceIsolationProvider: Sendable {
  /// Removes music and noise from the speech in `input` and writes the result to `output`.
  /// - Parameters:
  ///   - input: A local WAV file: 16-bit PCM at 48 kHz, mono or stereo as the clip's audio. More channels arrive as
  ///     stereo.
  ///   - output: The local file to write. The clip plays it in place of its audio, so write audio that iOS decodes,
  ///     such as WAV, with the length of `input`. Otherwise the clip's trim and its sync with the video shift.
  func isolateVoice(from input: URL, to output: URL) async throws

  /// Optional warm-up hook that ``VoiceIsolationPlugin`` calls from its `onCreate` handler, in a background task. Use
  /// it to absorb cold-start costs, such as a model download, before the first ``isolateVoice(from:to:)`` call. The
  /// default implementation does nothing.
  func prewarm() async throws
}

public extension VoiceIsolationProvider {
  func prewarm() async throws {}
}
