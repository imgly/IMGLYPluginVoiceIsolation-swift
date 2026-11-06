import Foundation
import IMGLYEngine

extension EditorAPI {
  /// Copies the bytes of a media source into `destination`, a slice at a time, so that a long recording is never
  /// resident at once. A `buffer://` source is read from the engine, an `http(s)` source is downloaded, and any other
  /// source must be a resource that the engine has loaded, for example after `forceLoadAVResource`.
  /// - Parameters:
  ///   - url: The source as the URI resolver resolves it. Its scheme decides how the bytes are read.
  ///   - blockURI: The URI that the block holds. The engine serves the bytes of a loaded resource under this URI only.
  /// - Returns: The number of bytes written. `0` when the source is empty, and then `destination` does not exist.
  func copyData(from url: URL, blockURI: URL, to destination: URL) async throws -> Int {
    let written = switch url.scheme?.lowercased() {
    case "buffer": try copyBuffer(at: url, to: destination)
    // `getResourceData` rejects `http(s)` sources.
    case "http", "https": try await download(url, to: destination)
    default: try copyResource(at: blockURI, to: destination)
    }
    if written <= 0 {
      try? FileManager.default.removeItem(at: destination)
    }
    return written
  }

  /// Copies the bytes of a `buffer://` source into `destination`, a slice at a time.
  /// - Returns: The number of bytes written.
  func copyBuffer(at url: URL, to destination: URL) throws -> Int {
    let length = Int(try getBufferLength(url: url).uintValue)
    guard length > 0 else { return 0 }
    let file = try FileHandle.openForWriting(destination)
    defer { try? file.close() }
    var written = 0
    while written < length {
      let chunk = try getBufferData(
        url: url,
        offset: UInt(written),
        length: UInt(min(Self.chunkBytes, length - written)),
      )
      // A short read would otherwise spin: the offset never advances past it.
      guard !chunk.isEmpty else {
        throw VoiceIsolationError.processingFailed(
          "Reading \(url.absoluteString) stopped after \(written) of \(length) bytes.",
        )
      }
      try file.write(contentsOf: chunk)
      written += chunk.count
    }
    return written
  }
}

private extension EditorAPI {
  /// The most bytes of a source that one read holds.
  static let chunkBytes = 1 << 20

  func copyResource(at url: URL, to destination: URL) throws -> Int {
    let file = try FileHandle.openForWriting(destination)
    defer { try? file.close() }
    var written = 0
    var failure: (any Swift.Error)?
    // The engine may reuse a chunk once the callback returns, so each chunk is written inside it. A failed write stops
    // the walk by returning `false`, so that the error does not unwind through the engine.
    try getResourceData(url: url, chunkSize: UInt(Self.chunkBytes)) { chunk in
      do {
        try file.write(contentsOf: chunk)
      } catch {
        failure = error
        return false
      }
      written += chunk.count
      return true
    }
    if let failure {
      throw failure
    }
    return written
  }

  func download(_ url: URL, to destination: URL) async throws -> Int {
    let (downloaded, response) = try await URLSession.shared.download(from: url)
    if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
      try? FileManager.default.removeItem(at: downloaded)
      throw VoiceIsolationError.processingFailed("Downloading \(url.absoluteString) returned HTTP \(http.statusCode).")
    }
    try FileManager.default.moveItem(at: downloaded, to: destination)
    return try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
  }
}

private extension FileHandle {
  static func openForWriting(_ destination: URL) throws -> FileHandle {
    guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
      throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: destination.path])
    }
    return try FileHandle(forWritingTo: destination)
  }
}
