import AVFoundation
import IMGLYEngine
import UniformTypeIdentifiers

// MARK: - Voice Isolation Processor

@MainActor
enum VoiceIsolationProcessor {
  /// What the inspector bar button adds to a run. The block call adds nothing, so that its caller decides.
  enum Run {
    /// The inspector bar button: waits for its turn on `queue`, so that the model runs on one clip at a time and the
    /// memory peak does not grow with each clip, shows the loading state, and ends in one undo step.
    case button(queue: SerialQueue)
    /// The block call: no queue, no loading state and no undo step.
    case call

    var queue: SerialQueue? {
      if case let .button(queue) = self {
        queue
      } else {
        nil
      }
    }
  }

  private nonisolated static let resultsDirectoryName = "ly.img.plugin.voiceIsolation"
  private static let audioFileURIProperty = "audio/fileURI"
  private static let videoFileURIProperty = "fill/video/fileURI"

  /// Whether `block` can be cleaned: an audio clip with a file whose `"fill/change"` scope is allowed, or a video clip
  /// with a file whose audio the editor can separate.
  static func canProcess(_ block: DesignBlockID, engine: Engine) -> Bool {
    guard (try? engine.block.getType(block)) == DesignBlockType.audio.rawValue else {
      // The editor's Separate Audio also shows for a video without a file, which has no audio.
      guard (try? engine.block.canSeparateAudio(block)) == true, let fill = try? engine.block.getFill(block) else {
        return false
      }
      return (try? engine.block.getString(fill, property: videoFileURIProperty))?.isEmpty == false
    }
    guard let fileURI = try? engine.block.getString(block, property: audioFileURIProperty), !fileURI.isEmpty,
          (try? engine.block.isAllowedByScope(block, key: "fill/change")) == true else {
      return false
    }
    // A voiceover that records holds raw samples in a buffer, which has no container to decode.
    let isRecording = (try? engine.block.getKind(block)) == "voiceover" && URL(string: fileURI)?.scheme == "buffer"
    return !isRecording
  }

  /// Cleans the audio of `block` and returns the cleaned audio block. `engine` returns `nil` once the editor freed its
  /// engine, so a run writes nothing into a closed editor. The download of a remote source and the load of a remote
  /// video still hold the engine until they end.
  static func process(_ block: DesignBlockID, engine: @escaping @MainActor () -> Engine?, run: Run,
                      provider: any VoiceIsolationProvider) async throws -> DesignBlockID {
    let source = try start(block, engine: engine, run: run)
    defer {
      if case .button = run, let engine = engine(), engine.block.isValid(block) {
        try? engine.block.setState(block, state: .ready)
      }
    }
    let workDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ly.img.plugin.voiceIsolation-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: workDirectory) }

    let input = try await decodedAudio(of: source, engine: engine, into: workDirectory)
    let output = try await cleaned(input, of: source, engine: engine, provider: provider, queue: run.queue)
    do {
      // The separation reads the tracks of the video, so it loads before the last check, not between that check and
      // the commit.
      if let fill = source.videoFill, let engine = engine(), source.isShown(by: engine) {
        try await engine.block.forceLoadAVResource(fill)
      }
      // A caller that holds the engine keeps `engine()` alive after the editor closed.
      try Task.checkCancellation()
      try checkShown(source, engine: engine)
      guard let engine = engine() else { throw CancellationError() }
      return try await commit(output, to: source, engine: engine, run: run)
    } catch {
      delete(output)
      throw error
    }
  }

  // MARK: - Private

  /// Checks `block` and marks a button's block pending. A function of its own, so that the run holds the engine only
  /// here.
  private static func start(_ block: DesignBlockID, engine: @MainActor () -> Engine?, run: Run) throws -> AudioSource {
    guard let engine = engine() else { throw CancellationError() }
    guard canProcess(block, engine: engine) else { throw VoiceIsolationError.unsupportedBlock }
    let source = try AudioSource(of: block, engine: engine)
    if case .button = run {
      try engine.block.setState(block, state: .pending(progress: 0.5))
    }
    return source
  }

  /// The audio that a run cleans, and what the block shows when the run starts, so that a later change is found.
  @MainActor
  private struct AudioSource {
    let block: DesignBlockID
    /// The video fill of a video clip, `nil` for an audio clip.
    let videoFill: DesignBlockID?
    /// The `audio/fileURI` of an audio clip, or the `fill/video/fileURI` of a video clip.
    let fileURI: String
    /// Whether the video plays muted. Separate Audio mutes it and keeps the fill and its file.
    let isVideoMuted: Bool

    init(of block: DesignBlockID, engine: Engine) throws {
      self.block = block
      if try engine.block.getType(block) == DesignBlockType.audio.rawValue {
        videoFill = nil
        fileURI = try engine.block.getString(block, property: audioFileURIProperty)
        isVideoMuted = false
      } else {
        let fill = try engine.block.getFill(block)
        videoFill = fill
        fileURI = try engine.block.getString(fill, property: videoFileURIProperty)
        isVideoMuted = try engine.block.isMuted(fill)
      }
    }

    /// Whether `block` still shows this audio and may still change: the user has not replaced or separated the audio,
    /// muted or unmuted the video, played the clip faster than 3x, or locked its `"fill/change"` scope. Separate Audio
    /// mutes the video, so a mute counts as a change too.
    func isShown(by engine: Engine) -> Bool {
      guard engine.block.isValid(block), let current = try? AudioSource(of: block, engine: engine),
            (try? engine.block.isAllowedByScope(block, key: "fill/change")) == true else {
        return false
      }
      if let videoFill, (try? engine.block.isForceMuted(videoFill)) != false {
        return false
      }
      return current.videoFill == videoFill && current.fileURI == fileURI && current.isVideoMuted == isVideoMuted
    }
  }

  /// Throws `CancellationError` once the editor freed its engine, and ``VoiceIsolationError/blockChanged`` once the
  /// block no longer shows `source`.
  private static func checkShown(_ source: AudioSource, engine: @MainActor () -> Engine?) throws {
    guard let engine = engine() else { throw CancellationError() }
    guard source.isShown(by: engine) else { throw VoiceIsolationError.blockChanged }
  }

  /// Decodes the audio of `source` into a 16-bit WAV file at 48 kHz in `directory`: the file of an audio clip, or the
  /// audio track that a video clip plays. The whole source, not the trimmed part, so the trim can still change
  /// afterwards.
  private static func decodedAudio(of source: AudioSource, engine: @MainActor () -> Engine?,
                                   into directory: URL) async throws -> URL {
    try await engine()?.block.forceLoadAVResource(source.videoFill ?? source.block)
    let file = if let videoFill = source.videoFill {
      try playedTrack(of: videoFill, engine: engine, into: directory)
    } else {
      try await copy(source, engine: engine, into: directory)
    }
    let input = directory.appendingPathComponent("input.wav")
    try await AudioDecoder.decode(file, to: input)
    return input
  }

  /// Copies the audio track that the video plays, track 0, into `directory`. The engine reads every video that it
  /// plays, and it extracts the track into a buffer before `createAudioFromVideo` returns. The temporary block and its
  /// buffer go in the same turn, so no engine update and no undo step sees them.
  private static func playedTrack(of videoFill: DesignBlockID, engine: @MainActor () -> Engine?,
                                  into directory: URL) throws -> URL {
    guard let engine = engine() else { throw CancellationError() }
    // The engine stops the app when it reads the tracks of a video that it could not open, such as WebM on iOS.
    if case let .error(_, engineError) = try engine.block.getState(videoFill) {
      throw VoiceIsolationError
        .processingFailed(engineError?.localizedDescription ?? "The engine cannot open the video.")
    }
    let audio: DesignBlockID
    do {
      audio = try engine.block.createAudioFromVideo(
        videoFill,
        trackIndex: 0,
        options: .init(keepTrimSettings: false, muteOriginalVideo: false),
      )
    } catch let error as EngineError where error.catalogCode == .blockNoAudioTracksInVideo {
      throw VoiceIsolationError.noAudio
    }
    let buffer = (try? engine.block.getString(audio, property: audioFileURIProperty)).flatMap(URL.init(string:))
    defer {
      try? engine.block.destroy(audio)
      if let buffer {
        try? engine.editor.destroyBuffer(url: buffer)
      }
    }
    guard let buffer, buffer.scheme == "buffer" else {
      throw VoiceIsolationError.processingFailed("The engine extracted the audio of the video into no buffer.")
    }
    // The engine writes the track into an MP4 container.
    let copy = directory.appendingPathComponent("track").appendingPathExtension("mp4")
    guard try engine.editor.copyBuffer(at: buffer, to: copy) > 0 else {
      throw VoiceIsolationError.noAudio
    }
    return copy
  }

  /// The file of `source`, copied into `directory` when the engine holds it in a buffer or loads it from the network.
  private static func copy(_ source: AudioSource, engine: @MainActor () -> Engine?,
                           into directory: URL) async throws -> URL {
    guard let blockURI = URL(string: source.fileURI), !source.fileURI.isEmpty else {
      throw VoiceIsolationError.noAudio
    }
    var url = blockURI
    // The engine plays what a custom URI resolver makes of the URI, so the plugin reads that too.
    if url.scheme != "buffer", let resolved = try await engine()?.editor.getAbsoluteURI(relativePath: source.fileURI) {
      url = URL(string: resolved) ?? url
    }
    if url.isFileURL {
      return url
    }
    // A buffer has no file extension, and AVFoundation picks the reader by the extension.
    let fileExtension = if url.pathExtension.isEmpty, let mimeType = try await engine()?.editor.getMIMEType(url: url) {
      UTType(mimeType: mimeType)?.preferredFilenameExtension ?? "mp4"
    } else {
      url.pathExtension
    }
    let copy = directory.appendingPathComponent("source").appendingPathExtension(fileExtension)
    guard let written = try await engine()?.editor.copyData(from: url, blockURI: blockURI, to: copy) else {
      throw CancellationError()
    }
    guard written > 0 else { throw VoiceIsolationError.noAudio }
    return copy
  }

  /// Runs `provider` on `input`, after the earlier runs on `queue`. A change of the clip, a closed editor, or a
  /// cancelled caller cancels the wait for the queue and the model run, so that a clip the user replaced neither keeps
  /// its loading state nor holds up the next clip. A provider decides itself when it stops: IMG.LY's provider stops
  /// between two 10 s chunks of audio, but not while it downloads its model. The result of a provider that ignores the
  /// cancellation is dropped.
  private static func cleaned(_ input: URL, of source: AudioSource, engine: @escaping @MainActor () -> Engine?,
                              provider: any VoiceIsolationProvider, queue: SerialQueue?) async throws -> URL {
    let run = Task {
      try await queue?.waitForTurn()
      defer { queue?.endTurn() }
      // The clip can change after the last check of the watcher.
      try Task.checkCancellation()
      try checkShown(source, engine: engine)
      return try await isolateVoice(in: input, provider: provider)
    }
    let watcher = observe(source, engine: engine) {
      run.cancel()
    }
    defer { watcher.cancel() }
    let result = await withTaskCancellationHandler {
      await run.result
    } onCancel: {
      run.cancel()
    }
    do {
      return try result.get()
    } catch {
      try Task.checkCancellation()
      try checkShown(source, engine: engine)
      throw error
    }
  }

  private static func isolateVoice(in input: URL, provider: any VoiceIsolationProvider) async throws -> URL {
    let output = try resultsDirectory().appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
    do {
      try await provider.isolateVoice(from: input, to: output)
    } catch {
      delete(output)
      throw error
    }
    return output
  }

  /// Calls `onChange` when the clip stops showing `source`, or the editor frees its engine. It checks on a timer
  /// instead of subscribing to engine events, because a subscription keeps the native engine alive.
  private static func observe(_ source: AudioSource, engine: @escaping @MainActor () -> Engine?,
                              onChange: @escaping @MainActor () -> Void) -> Task<Void, Never> {
    Task {
      while !Task.isCancelled {
        guard let engine = engine(), source.isShown(by: engine) else {
          onChange()
          return
        }
        try? await Task.sleep(for: .milliseconds(250))
      }
    }
  }

  /// Sets the cleaned file. A video clip gets its audio separated first. The engine takes an undo snapshot at its next
  /// update, and keeps a snapshot without changes too, so the separation, the new file URIs, the end of the loading
  /// state and the undo step all happen in one turn, without a suspension.
  private static func commit(_ output: URL, to source: AudioSource, engine: Engine,
                             run: Run) async throws -> DesignBlockID {
    let audioBlock: DesignBlockID
    if source.videoFill == nil {
      try engine.block.setString(source.block, property: audioFileURIProperty, value: output.absoluteString)
      audioBlock = source.block
    } else {
      guard let separated = try await engine.block.separateAudio(of: source.block) else {
        throw VoiceIsolationError.noAudio
      }
      let extracted = try engine.block.getString(separated, property: audioFileURIProperty)
      try engine.block.setString(separated, property: audioFileURIProperty, value: output.absoluteString)
      // No undo step holds the extracted track yet, so its buffer is freed at once.
      if let buffer = URL(string: extracted), buffer.scheme == "buffer" {
        try? engine.editor.destroyBuffer(url: buffer)
      }
      audioBlock = separated
    }
    if case .button = run {
      try engine.block.setState(source.block, state: .ready)
      try engine.editor.addUndoStep()
    }
    return audioBlock
  }

  /// The results stay in Application Support, where iOS does not purge them while the scene plays them.
  private nonisolated static func resultsDirectory() throws -> URL {
    let directory = try FileManager.default
      .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
      .appendingPathComponent(resultsDirectoryName, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  private nonisolated static func delete(_ file: URL) {
    try? FileManager.default.removeItem(at: file)
  }
}
