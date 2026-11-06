import Foundation
import IMGLYPluginVoiceIsolationCore

/// Configures IMG.LY's on-device voice isolation backend, which runs DeepFilterNet3 with ONNX Runtime.
public struct IMGLYVoiceIsolationConfiguration: VoiceIsolationConfiguration {
  /// The folder that holds the model files `enc.onnx`, `erb_dec.onnx`, `df_dec.onnx` and `config.ini`. Defaults to
  /// IMG.LY's CDN.
  ///
  /// Pass a `file://` URL of a folder in your app to ship the model with the app and skip the download, for example
  /// `Bundle.main.url(forResource: "DeepFilterNet3", withExtension: nil)`. Pass an `https://` URL of a folder with the
  /// same files to host the model yourself.
  public let modelBaseURL: URL

  /// Controls when the model is downloaded and loaded. Defaults to ``LoadMode/eager``.
  public let loadMode: LoadMode

  /// The provider built from the fields above.
  public let provider: any VoiceIsolationProvider

  /// IMG.LY's CDN folder of the model files.
  public static let defaultModelBaseURL = URL(
    string: "https://staticimgly.com/imgly/plugin-mobile-voice-isolation/1.0.0",
  )!

  /// Creates a configuration.
  /// - Parameters:
  ///   - modelBaseURL: The folder to load the model files from.
  ///   - loadMode: When to download and load the model.
  public init(
    modelBaseURL: URL = Self.defaultModelBaseURL,
    loadMode: LoadMode = .eager,
  ) {
    self.modelBaseURL = modelBaseURL
    self.loadMode = loadMode
    provider = IMGLYVoiceIsolationProvider(modelBaseURL: modelBaseURL, loadMode: loadMode)
  }

  /// Controls when the model is downloaded and loaded.
  public enum LoadMode: Sendable {
    /// Load the model on the first clean.
    case lazy
    /// Load the model when the editor opens.
    case eager
  }
}
