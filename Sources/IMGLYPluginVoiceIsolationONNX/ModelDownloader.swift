import CryptoKit
import Foundation
import IMGLYPluginVoiceIsolationCore

/// Resolves a model base URL to a local folder with the files of ``DeepFilterNet3Model``.
///
/// A `file://` base URL is used as it is. An `http(s)://` base URL is downloaded once into the caches directory, into a
/// folder of its own, so that a new base URL never reuses the files of an old one.
enum ModelDownloader {
  static func resolve(_ modelBaseURL: URL) async throws -> URL {
    if modelBaseURL.isFileURL {
      let missing = DeepFilterNet3Model.files.filter {
        !FileManager.default.fileExists(atPath: modelBaseURL.appendingPathComponent($0).path)
      }
      guard missing.isEmpty else {
        throw VoiceIsolationError.modelDownloadFailed(
          "The bundled model at \(modelBaseURL.path) has no \(missing.joined(separator: ", ")).",
        )
      }
      return modelBaseURL
    }
    let cached = try cacheDirectory(for: modelBaseURL)
    if FileManager.default.fileExists(atPath: cached.path) {
      return cached
    }
    // All files go into a folder of their own first, and the folder moves into place at once, so that a failed or
    // concurrent download never leaves a folder with some of the files.
    let scratch = cached.deletingLastPathComponent().appendingPathComponent("\(UUID().uuidString).partial")
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: scratch) }
    for file in DeepFilterNet3Model.files {
      try await download(modelBaseURL.appendingPathComponent(file), to: scratch.appendingPathComponent(file))
    }
    do {
      try FileManager.default.moveItem(at: scratch, to: cached)
    } catch where FileManager.default.fileExists(atPath: cached.path) {
      // Another download finished first.
    }
    return cached
  }

  private static func download(_ url: URL, to destination: URL) async throws {
    let downloaded: URL
    let response: URLResponse
    do {
      (downloaded, response) = try await URLSession.shared.download(from: url)
    } catch {
      throw VoiceIsolationError.modelDownloadFailed(error.localizedDescription)
    }
    defer { try? FileManager.default.removeItem(at: downloaded) }
    // `download(from:)` does not throw on an error status, so an error page would otherwise be kept as a model file.
    if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
      throw VoiceIsolationError.modelDownloadFailed("HTTP \(http.statusCode) for \(url.absoluteString)")
    }
    try FileManager.default.moveItem(at: downloaded, to: destination)
  }

  private static func cacheDirectory(for modelBaseURL: URL) throws -> URL {
    let name = SHA256.hash(data: Data(modelBaseURL.absoluteString.utf8))
      .prefix(8).map { String(format: "%02x", $0) }.joined()
    let root = try FileManager.default
      .url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
      .appendingPathComponent("ly.img.plugin.voiceIsolation/models", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root.appendingPathComponent(name, isDirectory: true)
  }
}
