import Foundation

/// Errors of the voice isolation workflow.
public enum VoiceIsolationError: LocalizedError, Sendable {
  /// The block is neither an audio clip nor a video clip whose audio the editor can separate, or its `"fill/change"`
  /// scope is not allowed.
  case unsupportedBlock
  /// The clip has no audio track when the call loads it, or its audio has no samples.
  case noAudio
  /// The clip changed or was deleted while its audio was cleaned, so the result was dropped.
  case blockChanged
  /// The model could not be downloaded or loaded, or the bundled model was not found.
  case modelDownloadFailed(String)
  /// Reading, cleaning or writing the audio failed.
  case processingFailed(String)

  public var errorDescription: String? {
    switch self {
    case .noAudio: String(localized: .voiceIsolationErrorNoAudio)
    case .modelDownloadFailed: String(localized: .voiceIsolationErrorModelDownload)
    case .unsupportedBlock, .blockChanged, .processingFailed: String(localized: .voiceIsolationErrorFailed)
    }
  }

  public var failureReason: String? {
    switch self {
    case .unsupportedBlock: "The block has no audio that the plugin can clean."
    case .blockChanged: "The clip changed or was deleted while its audio was cleaned."
    case let .modelDownloadFailed(reason), let .processingFailed(reason): reason
    case .noAudio: nil
    }
  }
}
