import Foundation
import IMGLYEngine

// The editor's Separate Audio, on public engine calls only, so that the plugin needs no editor internals.
extension BlockAPI {
  /// Whether the editor shows its Separate Audio button for `block`: a graphic block with a video fill that is not an
  /// animated sticker, its `"fill/change"` scope is allowed, and its video has audio, muted or not, and plays at 3x or
  /// slower. A video that has not loaded yet counts as a video with audio, because its audio tracks are known only
  /// after it loads.
  func canSeparateAudio(_ block: DesignBlockID) throws -> Bool {
    guard try getType(block) == DesignBlockType.graphic.rawValue, try supportsFill(block),
          try getKind(block) != "animatedSticker",
          try isAllowedByScope(block, key: "fill/change") else {
      return false
    }
    let fill = try getFill(block)
    guard try getType(fill) == FillType.video.rawValue else { return false }
    // Above 3x the video plays no audio, so it has no audio to separate.
    guard try !isForceMuted(fill) else { return false }
    guard try unstable_isAVResourceLoaded(fill) else { return true }
    // The engine stops the app when it counts the tracks of a video that it could not open, such as WebM on iOS.
    if case .error = try getState(fill) {
      return false
    }
    return try getAudioTrackCountFromVideo(fill) > 0
  }

  /// Moves the audio that `clip` plays, its first audio track, into a new audio clip and mutes the clip, as the
  /// editor's Separate Audio does for that track, but adds no undo step. The audio clip starts with the clip, plays
  /// like it and is named after it, or "Audio" when it has no name. The audio of a background clip goes into the audio
  /// row directly above the background track, the audio of an overlay into the audio row directly below the overlays.
  /// - Returns: The new audio block, or `nil` when the video has no audio.
  func separateAudio(of clip: DesignBlockID) async throws -> DesignBlockID? {
    let fill = try getFill(clip)
    try await forceLoadAVResource(fill)
    guard try getAudioTrackCountFromVideo(fill) > 0 else { return nil }
    guard let page = try page(of: clip) else { throw VoiceIsolationError.unsupportedBlock }

    // The timeline shows the audio rows between the overlays and the background track, and the audio block with the
    // lower page index in the higher row.
    let topAudioRowIndex: Int? = if let parent = try getParent(clip), try isBackgroundTrack(parent) {
      nil
    } else {
      try getChildren(page).firstIndex { try isAudioRow($0) }
    }
    let audio = try createAudioFromVideo(fill, trackIndex: 0,
                                         options: .init(keepTrimSettings: true, muteOriginalVideo: true))
    if let topAudioRowIndex {
      try insertChild(into: page, child: audio, at: topAudioRowIndex)
    } else {
      try appendChild(to: page, child: audio)
    }
    // Keeps the audio out of the z-index reordering, like an audio clip added from the library.
    try setAlwaysOnTop(audio, enabled: true)
    try setTimeOffset(audio, offset: getTimeOffset(clip))
    // The engine names the block after the audio track, and the web timeline shows that name first.
    try setName(audio, name: "")
    let clipName = try hasMetadata(clip, key: "name") ? getMetadata(clip, key: "name") : ""
    // A video from the photo roll has no name, so its audio clip gets a default one.
    try setMetadata(
      audio,
      key: "name",
      value: clipName.isEmpty ? String(localized: .editorClipAudioTitle) : clipName,
    )
    return audio
  }
}

private extension BlockAPI {
  func page(of block: DesignBlockID) throws -> DesignBlockID? {
    var ancestor = try getParent(block)
    while let current = ancestor, try getType(current) != DesignBlockType.page.rawValue {
      ancestor = try getParent(current)
    }
    return ancestor
  }

  /// The editor's background track: the track that sets the page duration.
  func isBackgroundTrack(_ block: DesignBlockID) throws -> Bool {
    try getType(block) == DesignBlockType.track.rawValue && isPageDurationSource(block)
  }

  /// An audio block, or a track whose first child is audio: the timeline shows both in the audio rows.
  func isAudioRow(_ block: DesignBlockID) throws -> Bool {
    let type = try getType(block)
    if type == DesignBlockType.audio.rawValue {
      return true
    }
    guard type == DesignBlockType.track.rawValue, let firstChild = try getChildren(block).first else { return false }
    return try getType(firstChild) == DesignBlockType.audio.rawValue
  }
}
