import AVFoundation
import IMGLYEngine
@testable import IMGLYPluginVoiceIsolationCore
import XCTest

/// The flow of the plugin with a provider that copies its input, on an offscreen engine whose update loop runs
/// between the awaits, as in the editor.
@MainActor
final class VoiceIsolationProcessorTests: XCTestCase {
  private var engine: Engine!
  private var page: DesignBlockID = 0
  private var historyUpdates = 0
  private var historyTask: Task<Void, Never>?

  override func setUp() async throws {
    engine = try await Engine(context: .offscreen(size: CGSize(width: 100, height: 100)), audioContext: .none)
    let scene = try engine.scene.createVideo()
    page = try engine.block.create(.page)
    try engine.block.appendChild(to: scene, child: page)
    try engine.block.setDuration(page, duration: 12)
    try engine.editor.addUndoStep()
    await settle()
    historyTask = Task { [weak self] in
      guard let updates = self?.engine.editor.onHistoryUpdatedWithKind else { return }
      for await kind in updates where kind == .updated {
        self?.historyUpdates += 1
      }
    }
    await settle()
  }

  override func tearDown() async throws {
    historyTask?.cancel()
    engine = nil
  }

  // MARK: - Can isolate voice

  // @requirement(voice-isolation/entry-points/eligible-clips)
  func testCanIsolateVoiceOfAudioAndVideoClipsOnly() throws {
    let audio = try audioClip()
    XCTAssertTrue(VoiceIsolationPlugin.canIsolateVoice(of: audio, engine: engine))
    XCTAssertTrue(VoiceIsolationPlugin.canIsolateVoice(of: try videoClip(), engine: engine))

    let image = try engine.block.create(.graphic)
    try engine.block.setShape(image, shape: engine.block.createShape(.rect))
    try engine.block.setFill(image, fill: engine.block.createFill(.image))
    XCTAssertFalse(VoiceIsolationPlugin.canIsolateVoice(of: image, engine: engine))
    XCTAssertFalse(VoiceIsolationPlugin.canIsolateVoice(of: page, engine: engine))

    try engine.editor.setGlobalScope(key: "fill/change", value: .defer)
    try engine.block.setScopeEnabled(audio, key: "fill/change", enabled: false)
    XCTAssertFalse(VoiceIsolationPlugin.canIsolateVoice(of: audio, engine: engine))
  }

  // @requirement(voice-isolation/entry-points/eligible-clips)
  func testVideoClipsThatSeparateAudioRejectsCannotBeCleaned() async throws {
    let silent = try videoClip("silent.mp4")
    try await engine.block.forceLoadAVResource(engine.block.getFill(silent))
    XCTAssertFalse(VoiceIsolationPlugin.canIsolateVoice(of: silent, engine: engine), "A video without audio")

    let fast = try videoClip()
    try engine.block.setPlaybackSpeed(engine.block.getFill(fast), speed: 4)
    XCTAssertFalse(VoiceIsolationPlugin.canIsolateVoice(of: fast, engine: engine), "A video above 3x speed")

    let sticker = try videoClip()
    try engine.block.setKind(sticker, kind: "animatedSticker")
    XCTAssertFalse(VoiceIsolationPlugin.canIsolateVoice(of: sticker, engine: engine), "An animated sticker")
  }

  // @requirement(voice-isolation/entry-points/eligible-clips)
  func testAudioClipsWithoutAFileOrThatStillRecordCannotBeCleaned() throws {
    let empty = try engine.block.create(.audio)
    try engine.block.appendChild(to: page, child: empty)
    XCTAssertFalse(VoiceIsolationPlugin.canIsolateVoice(of: empty, engine: engine), "An audio clip without a file")

    let recording = try engine.block.create(.audio)
    try engine.block.setKind(recording, kind: "voiceover")
    try engine.block.setString(recording, property: "audio/fileURI",
                               value: engine.editor.createBuffer().absoluteString)
    try engine.block.appendChild(to: page, child: recording)
    XCTAssertFalse(VoiceIsolationPlugin.canIsolateVoice(of: recording, engine: engine), "A voiceover that records")

    let recorded = try audioClip()
    try engine.block.setKind(recorded, kind: "voiceover")
    XCTAssertTrue(VoiceIsolationPlugin.canIsolateVoice(of: recorded, engine: engine), "A recorded voiceover")
  }

  // @requirement(voice-isolation/entry-points/eligible-clips)
  func testVideoClipWithoutAFileCannotBeCleaned() throws {
    let video = try engine.block.create(.graphic)
    try engine.block.setShape(video, shape: engine.block.createShape(.rect))
    try engine.block.setFill(video, fill: engine.block.createFill(.video))
    try engine.block.appendChild(to: page, child: video)

    XCTAssertFalse(VoiceIsolationPlugin.canIsolateVoice(of: video, engine: engine))
  }

  /// The audio tracks of a video are known only after it loads, so a video without audio is offered until then.
  func testVideoWithoutAudioThatHasNotLoadedEndsWithNoAudio() async throws {
    let silent = try videoClip("silent.mp4")
    XCTAssertTrue(VoiceIsolationPlugin.canIsolateVoice(of: silent, engine: engine))

    await assertThrows(.noAudio) {
      _ = try await self.process(silent)
    }
    XCTAssertTrue(try engine.block.find(byType: .audio).isEmpty)
  }

  // MARK: - Audio clips

  // @requirement(voice-isolation/isolate-voice/audio-clip-cleaned-in-place)
  // @requirement(voice-isolation/undo/code-call-no-undo-step)
  // @requirement(voice-isolation/isolator-integration/custom-isolator)
  func testBlockCallCleansAnAudioClipInPlaceWithoutAnUndoStep() async throws {
    let audio = try audioClip()
    await settle()
    let updatesBefore = historyUpdates

    let cleaned = try await process(audio)

    XCTAssertEqual(cleaned, audio)
    let result = try XCTUnwrap(URL(string: engine.block.getString(audio, property: "audio/fileURI")))
    XCTAssertEqual(result.deletingLastPathComponent().lastPathComponent, "ly.img.plugin.voiceIsolation")
    let file = try AVAudioFile(forReading: result)
    XCTAssertEqual(file.fileFormat.sampleRate, 48000)
    XCTAssertEqual(file.fileFormat.channelCount, 1)
    XCTAssertEqual(file.fileFormat.settings[AVLinearPCMBitDepthKey] as? Int, 16)
    XCTAssertEqual(file.length, try AVAudioFile(forReading: fixture("speech-and-music.m4a")).length)
    XCTAssertEqual(try engine.block.getState(audio), .ready)
    await settle()
    XCTAssertEqual(historyUpdates, updatesBefore, "The block call added an undo step.")
  }

  // @requirement(voice-isolation/undo/button-one-undo-step)
  func testOneUndoAfterTheButtonFlowRestoresTheAudioClip() async throws {
    let audio = try audioClip()
    try engine.editor.addUndoStep()
    await settle()
    let original = try engine.block.getString(audio, property: "audio/fileURI")
    let updatesBefore = historyUpdates

    _ = try await process(audio, run: .button(queue: SerialQueue()))
    await settle()

    XCTAssertEqual(historyUpdates, updatesBefore + 1)
    XCTAssertNotEqual(try engine.block.getString(audio, property: "audio/fileURI"), original)
    try engine.editor.undo()
    await settle()
    XCTAssertEqual(try engine.block.getString(audio, property: "audio/fileURI"), original)
  }

  func testDecoderReportsAFormatThatAVFoundationCannotOpenAsProcessingFailed() async throws {
    do {
      try await AudioDecoder.decode(fixture("speech-and-music.webm"), to: temporaryFile("wav"))
      XCTFail("AVFoundation decoded WebM.")
    } catch VoiceIsolationError.processingFailed {}
  }

  // @requirement(voice-isolation/isolate-voice/audio-clip-cleaned-in-place)
  func testDecoderResamplesToFortyEightKilohertzKeepsStereoAndKeepsTheTiming() async throws {
    let source = temporaryFile("caf")
    // A click at 0.5 s of 2 s at 44.1 kHz.
    try writeClick(to: source, sampleRate: 44100, channels: 2, seconds: 2, at: 22050)
    let decoded = temporaryFile("wav")

    try await AudioDecoder.decode(source, to: decoded)

    let file = try AVAudioFile(forReading: decoded)
    XCTAssertEqual(file.fileFormat.sampleRate, 48000)
    XCTAssertEqual(file.fileFormat.channelCount, 2)
    XCTAssertEqual(file.fileFormat.settings[AVLinearPCMBitDepthKey] as? Int, 16)
    let samples = try channels(of: decoded)
    for channel in samples {
      let peak = try XCTUnwrap(channel.indices.max { abs(channel[$0]) < abs(channel[$1]) })
      XCTAssertEqual(peak, 24000, accuracy: 2, "The click moved.")
    }
    // The sample rate converter does not flush its filter at the end, about 1 ms.
    XCTAssertEqual(Double(file.length), 2 * 48000, accuracy: 96)
  }

  // MARK: - Video clips

  // @requirement(voice-isolation/isolate-voice/video-clip-separated-and-cleaned)
  // @requirement(voice-isolation/undo/button-one-undo-step)
  func testVideoClipIsSeparatedAndCleanedInOneUndoStep() async throws {
    let video = try videoClip()
    try await engine.block.forceLoadAVResource(engine.block.getFill(video))
    try engine.editor.addUndoStep()
    await settle()
    let updatesBefore = historyUpdates

    let cleaned = try await process(video, run: .button(queue: SerialQueue()))
    await settle()

    XCTAssertEqual(historyUpdates, updatesBefore + 1, "The run did not end in exactly one undo step.")
    let audio = cleaned
    XCTAssertEqual(try engine.block.getParent(audio), page)
    XCTAssertTrue(try engine.block.getString(audio, property: "audio/fileURI").hasSuffix(".wav"))
    XCTAssertTrue(try engine.block.isMuted(engine.block.getFill(video)))
    XCTAssertEqual(try engine.block.find(byType: .audio), [audio])

    try engine.editor.undo()
    await settle()
    XCTAssertTrue(try engine.block.find(byType: .audio).isEmpty)
    XCTAssertFalse(try engine.block.isMuted(engine.block.getFill(video)))
  }

  /// The cleaned clip plays in sync with the video: with a provider that changes nothing, the engine plays the same
  /// audio as from the clip of its own Separate Audio.
  func testCleanedVideoAudioPlaysInSyncWithTheSeparatedAudio() async throws {
    let video = try videoClip()
    let fill = try engine.block.getFill(video)
    try await engine.block.forceLoadAVResource(fill)
    let separated = try XCTUnwrap(engine.block.createAudiosFromVideo(fill).first)
    try engine.block.appendChild(to: page, child: separated)
    try await engine.block.forceLoadAVResource(separated)
    let expected = try await exportedAudio(of: separated)

    let cleaned = try await process(video)
    try await engine.block.forceLoadAVResource(cleaned)
    let played = try await exportedAudio(of: cleaned)

    XCTAssertEqual(played.count, expected.count)
    // Both decode the same AAC frames, so they differ by the 16-bit rounding of the WAV only. The engine's extracted
    // track is 21 ms longer, its AAC padding, so the two clips end differently: the comparison stops at 2.8 s.
    let end = 48000 * 28 / 10
    var error = 0.0
    var signal = 0.0
    for (sample, target) in zip(played[..<end], expected[..<end]) {
      error += Double(sample - target) * Double(sample - target)
      signal += Double(target) * Double(target)
    }
    XCTAssertGreaterThan(10 * log10(signal / error), 60)
  }

  /// The engine keeps a trim as a share of the media length, and its length of an AAC track includes the encoder's
  /// padding, which the cleaned WAV file does not have. So the trim of a cleaned clip moves by up to that padding.
  func testCleanedVideoAudioKeepsTheTrim() async throws {
    let video = try videoClip()
    let fill = try engine.block.getFill(video)
    try await engine.block.forceLoadAVResource(fill)
    try engine.block.setTrimOffset(fill, offset: 0.5)
    try engine.block.setTrimLength(fill, length: 2)
    try engine.block.setDuration(video, duration: 2)

    let audio = try await process(video)

    try await engine.block.forceLoadAVResource(audio)
    XCTExpectFailure("The trim moves by the AAC padding: 0.495 s and 1.981 s on this 3 s clip.")
    XCTAssertEqual(try engine.block.getTrimOffset(audio), 0.5, accuracy: 0.001)
    XCTAssertEqual(try engine.block.getTrimLength(audio), 2, accuracy: 0.001)
  }

  /// AVFoundation applies the edit list of an audio file, so a file whose audio starts after 0 keeps that start.
  func testCleanedAudioClipKeepsTheLateStartOfItsFile() async throws {
    let audio = try audioClip("speech-and-music-late-start.m4a")
    try await engine.block.forceLoadAVResource(audio)
    try engine.block.setDuration(audio, duration: 3)
    let original = try await exportedAudio(of: audio)

    let cleaned = try await process(audio)
    try await engine.block.forceLoadAVResource(cleaned)
    let played = try await exportedAudio(of: cleaned)

    let originalStart = try XCTUnwrap(original.firstIndex { abs($0) > 0.001 })
    let cleanedStart = try XCTUnwrap(played.firstIndex { abs($0) > 0.001 })
    XCTAssertEqual(Double(originalStart) / 48000, 1, accuracy: 0.03, "The fixture's audio starts at 1 s.")
    XCTAssertEqual(Double(cleanedStart), Double(originalStart), accuracy: 480, "More than 10 ms apart.")
  }

  /// The engine plays the audio of this video from 1 s, but its extracted track starts at 0, so the separated audio
  /// of the editor and the cleaned clip both start 1 s early.
  func testCleanedVideoAudioKeepsTheLateStartOfItsTrack() async throws {
    let video = try videoClip("speech-and-music-late-audio.mp4")
    try await engine.block.forceLoadAVResource(engine.block.getFill(video))
    let original = try await exportedAudio(of: video)

    let cleaned = try await process(video)
    try await engine.block.forceLoadAVResource(cleaned)
    let played = try await exportedAudio(of: cleaned)

    let originalStart = try XCTUnwrap(original.firstIndex { abs($0) > 0.001 })
    let cleanedStart = try XCTUnwrap(played.firstIndex { abs($0) > 0.001 })
    XCTAssertEqual(Double(originalStart) / 48000, 1, accuracy: 0.03, "The fixture's audio starts at 1 s.")
    XCTExpectFailure("The engine's extracted track starts at 0, so the cleaned audio starts 1 s early.")
    XCTAssertEqual(Double(cleanedStart), Double(originalStart), accuracy: 480, "More than 10 ms apart.")
  }

  // @requirement(voice-isolation/undo/code-call-no-undo-step)
  func testBlockCallOnAVideoClipAddsNoUndoStep() async throws {
    let video = try videoClip()
    try await engine.block.forceLoadAVResource(engine.block.getFill(video))
    try engine.editor.addUndoStep()
    await settle()
    let updatesBefore = historyUpdates

    let cleaned = try await process(video)
    await settle()

    XCTAssertEqual(try engine.block.find(byType: .audio), [cleaned])
    XCTAssertEqual(historyUpdates, updatesBefore, "The block call added an undo step.")
  }

  // @requirement(voice-isolation/isolate-voice/video-clip-timing-kept)
  /// A cleaned clip plays at the speed of the clip: an audio clip keeps its own, and the new audio clip of a video
  /// clip takes the speed of the video.
  func testCleanedClipsKeepThePlaybackSpeed() async throws {
    let audio = try audioClip()
    try engine.block.setPlaybackSpeed(audio, speed: 2)
    let video = try videoClip()
    try engine.block.setPlaybackSpeed(engine.block.getFill(video), speed: 2)

    let cleanedAudio = try await process(audio, run: .button(queue: SerialQueue()))
    let cleanedVideoAudio = try await process(video, run: .button(queue: SerialQueue()))

    XCTAssertEqual(try engine.block.getPlaybackSpeed(cleanedAudio), 2)
    XCTAssertEqual(try engine.block.getPlaybackSpeed(cleanedVideoAudio), 2)
  }

  /// The plugin reads the track that a video plays through a temporary audio block, which goes in the same turn.
  func testReadingTheAudioOfAVideoLeavesNoBlockAndAddsNoUndoStep() async throws {
    let video = try videoClip()
    try await engine.block.forceLoadAVResource(engine.block.getFill(video))
    try engine.editor.addUndoStep()
    await settle()
    let updatesBefore = historyUpdates
    let provider = GatedProvider()

    let run = Task { try await self.process(video, provider: provider) }
    await provider.waitUntilStarted()
    await settle()

    XCTAssertTrue(try engine.block.find(byType: .audio).isEmpty, "The temporary audio block is still there.")
    XCTAssertEqual(historyUpdates, updatesBefore, "Reading the audio added an undo step.")
    provider.open()
    _ = try await run.value
  }

  // @requirement(voice-isolation/isolate-voice/video-clip-separated-and-cleaned)
  /// The engine plays the first audio track of a video, so only that track is cleaned. The fixture's second track is
  /// silent, so a cleaned clip with sound comes from the first.
  func testVideoWithTwoAudioTracksGetsOneCleanedClipOfThePlayedTrack() async throws {
    let video = try videoClip("speech-and-music-two-tracks.mp4")

    let cleaned = try await process(video)

    XCTAssertEqual(try engine.block.find(byType: .audio), [cleaned])
    let result = try XCTUnwrap(URL(string: engine.block.getString(cleaned, property: "audio/fileURI")))
    XCTAssertGreaterThan(try peak(of: result), 0.01, "The cleaned clip is silent, so it comes from the second track.")
  }

  /// The engine on iOS cannot open a WebM file as a video, here Opus audio without a video stream, and it stops the
  /// app when it reads the tracks of such a video.
  func testVideoThatTheEngineCannotOpenIsNotOffered() async throws {
    let video = try videoClip("speech-and-music.webm")
    try await engine.block.forceLoadAVResource(engine.block.getFill(video))

    XCTAssertFalse(VoiceIsolationPlugin.canIsolateVoice(of: video, engine: engine))
    await assertThrows(VoiceIsolationError.unsupportedBlock) {
      _ = try await self.process(video)
    }
    XCTAssertTrue(try engine.block.find(byType: .audio).isEmpty)
  }

  // @requirement(voice-isolation/isolate-voice/video-clip-separated-and-cleaned)
  /// As with the editor's Separate Audio: the timeline shows the page's audio blocks between the overlays and the
  /// background track, the one with the lower page index in the higher row.
  func testSeparatedAudioGoesIntoTheRowsNextToItsClip() async throws {
    let backgroundTrack = try engine.block.create(.track)
    try engine.block.appendChild(to: page, child: backgroundTrack)
    try engine.block.setPageDurationSource(page, id: backgroundTrack)
    let background = try videoClip()
    try engine.block.appendChild(to: backgroundTrack, child: background)
    let overlay = try videoClip()
    try engine.block.setMetadata(overlay, key: "name", value: "Interview")
    try engine.block.setTimeOffset(overlay, offset: 1.5)
    let music = try audioClip()

    let overlaySeparated = try await engine.block.separateAudio(of: overlay)
    let backgroundSeparated = try await engine.block.separateAudio(of: background)
    let overlayAudio = try XCTUnwrap(overlaySeparated)
    let backgroundAudio = try XCTUnwrap(backgroundSeparated)

    XCTAssertEqual(try engine.block.getChildren(page), [backgroundTrack, overlay, overlayAudio, music, backgroundAudio])
    XCTAssertEqual(try engine.block.getMetadata(overlayAudio, key: "name"), "Interview")
    XCTAssertEqual(try engine.block.getMetadata(backgroundAudio, key: "name"), "Audio")
    XCTAssertEqual(try engine.block.getTimeOffset(overlayAudio), 1.5)
    XCTAssertTrue(try engine.block.isAlwaysOnTop(overlayAudio))
    XCTAssertTrue(try engine.block.isMuted(engine.block.getFill(overlay)))
  }

  // @requirement(voice-isolation/changes-and-errors/processing-error)
  func testAudioThatCannotBeDecodedEndsWithAnErrorAndLeavesTheClip() async throws {
    let audio = try audioClip("speech-and-music.webm")
    let original = try engine.block.getString(audio, property: "audio/fileURI")

    let run = await Task { try await self.process(audio) }.result

    XCTAssertThrowsError(try run.get())
    XCTAssertEqual(try engine.block.getString(audio, property: "audio/fileURI"), original)
    XCTAssertEqual(try engine.block.getState(audio), .ready)
  }

  // MARK: - Runs

  // @requirement(voice-isolation/changes-and-errors/clip-changed-during-run)
  func testChangedClipDropsTheResult() async throws {
    let audio = try audioClip()
    let provider = GatedProvider()
    let changed = try fixture("speech-and-music.mp4").absoluteString

    let run = Task { try await self.process(audio, provider: provider) }
    await provider.waitUntilStarted()
    try engine.block.setString(audio, property: "audio/fileURI", value: changed)
    provider.open()

    await assertThrows(VoiceIsolationError.blockChanged) {
      _ = try await run.value
    }
    XCTAssertEqual(try engine.block.getString(audio, property: "audio/fileURI"), changed)
  }

  // @requirement(voice-isolation/changes-and-errors/clip-changed-during-run)
  func testChangedClipStopsTheModelRun() async throws {
    let audio = try audioClip()
    let provider = SlowProvider()
    let changed = try fixture("speech-and-music.mp4").absoluteString
    let start = Date()

    let run = Task { try await self.process(audio, provider: provider) }
    await provider.waitUntilStarted()
    try engine.block.setString(audio, property: "audio/fileURI", value: changed)

    await assertThrows(VoiceIsolationError.blockChanged) {
      _ = try await run.value
    }
    XCTAssertLessThan(Date().timeIntervalSince(start), 10, "The model run did not stop.")
  }

  // @requirement(voice-isolation/changes-and-errors/audio-separated-during-run)
  /// The editor's Separate Audio mutes the video and keeps its fill and file, and the run must still end.
  func testSeparatingTheAudioDuringARunEndsTheRun() async throws {
    let video = try videoClip()
    let fill = try engine.block.getFill(video)
    try await engine.block.forceLoadAVResource(fill)
    let provider = GatedProvider()

    let run = Task { try await self.process(video, provider: provider) }
    await provider.waitUntilStarted()
    let separated = try engine.block.createAudiosFromVideo(
      fill,
      options: .init(keepTrimSettings: true, muteOriginalVideo: true),
    )
    for audio in separated {
      try engine.block.appendChild(to: page, child: audio)
    }
    provider.open()

    await assertThrows(VoiceIsolationError.blockChanged) {
      _ = try await run.value
    }
    XCTAssertEqual(try engine.block.find(byType: .audio), separated)
  }

  // @requirement(voice-isolation/isolate-voice/remote-and-buffer-sources)
  func testAudioClipThatPlaysABufferIsCleaned() async throws {
    let video = try videoClip()
    try await engine.block.forceLoadAVResource(engine.block.getFill(video))
    let separated = try await engine.block.separateAudio(of: video)
    let audio = try XCTUnwrap(separated)
    XCTAssertTrue(try engine.block.getString(audio, property: "audio/fileURI").hasPrefix("buffer://"))

    let cleaned = try await process(audio)

    XCTAssertEqual(cleaned, audio)
    let result = try XCTUnwrap(URL(string: engine.block.getString(audio, property: "audio/fileURI")))
    XCTAssertEqual(try AVAudioFile(forReading: result).length, 3 * 48000)
  }

  // @requirement(voice-isolation/changes-and-errors/cancelled-run)
  func testCancelledCallWritesNoResult() async throws {
    let audio = try audioClip()
    let original = try engine.block.getString(audio, property: "audio/fileURI")
    let provider = GatedProvider()

    let run = Task { try await self.process(audio, provider: provider) }
    await provider.waitUntilStarted()
    run.cancel()
    provider.open()

    let result = await run.result
    XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError, "\($0)") }
    XCTAssertEqual(try engine.block.getString(audio, property: "audio/fileURI"), original)
  }

  func testRemoteSourceIsDownloadedFromTheURLOfTheURIResolver() async throws {
    let local = try fixture("speech-and-music.m4a")
    try engine.editor.setURIResolver { uri in
      uri.hasPrefix("https://voice-isolation.test/") ? local : URL(string: uri)!
    }
    let audio = try engine.block.create(.audio)
    try engine.block.setString(audio, property: "audio/fileURI", value: "https://voice-isolation.test/speech.m4a")
    try engine.block.appendChild(to: page, child: audio)

    let cleaned = try await process(audio)

    XCTAssertEqual(cleaned, audio)
  }

  /// The engine serves the bytes of a loaded resource under the URI that the block holds, not under what the URI
  /// resolver makes of it.
  func testAudioClipWhoseURIResolvesToADataURIIsCleaned() async throws {
    let data = try Data(contentsOf: fixture("speech-and-music.m4a"))
    let resolved = try XCTUnwrap(URL(string: "data:audio/mp4;base64,\(data.base64EncodedString())"))
    try engine.editor.setURIResolver { uri in
      uri == "voice-isolation-test://speech.m4a" ? resolved : URL(string: uri)!
    }
    let audio = try engine.block.create(.audio)
    try engine.block.setString(audio, property: "audio/fileURI", value: "voice-isolation-test://speech.m4a")
    try engine.block.appendChild(to: page, child: audio)

    let cleaned = try await process(audio)

    XCTAssertEqual(cleaned, audio)
  }

  // @requirement(voice-isolation/processing-state/one-clip-at-a-time)
  func testProviderRunsOnOneClipAtATime() async throws {
    let first = try audioClip()
    let second = try audioClip()
    let provider = CountingProvider()
    let queue = SerialQueue()

    let firstRun = Task { try await self.process(first, run: .button(queue: queue), provider: provider) }
    let secondRun = Task { try await self.process(second, run: .button(queue: queue), provider: provider) }
    let results = try await [firstRun.value, secondRun.value]

    XCTAssertEqual(results, [first, second])
    XCTAssertEqual(provider.calls, 2)
    XCTAssertEqual(provider.mostAtOnce, 1)
  }

  // @requirement(voice-isolation/changes-and-errors/cancelled-run)
  func testCancelledCallStopsWaitingForTheModel() async throws {
    let first = try audioClip()
    let second = try audioClip()
    let provider = GatedProvider()
    let queue = SerialQueue()

    let firstRun = Task { try await self.process(first, run: .button(queue: queue), provider: provider) }
    await provider.waitUntilStarted()
    let secondRun = Task { try await self.process(second, run: .button(queue: queue)) }
    await settle()
    secondRun.cancel()
    await settle()

    XCTAssertEqual(try engine.block.getState(second), .ready, "The cancelled call still waits for the model.")
    provider.open()
    _ = try await firstRun.value
    let result = await secondRun.result
    XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError, "\($0)") }
  }

  // @requirement(voice-isolation/processing-state/one-clip-at-a-time)
  func testTwoPluginInstancesCleanOneClipAtATime() async throws {
    let first = try audioClip()
    let second = try audioClip()
    let provider = CountingProvider()
    let firstPlugin = VoiceIsolationPlugin(configuration: ProviderConfiguration(provider: provider))
    let secondPlugin = VoiceIsolationPlugin(configuration: ProviderConfiguration(provider: provider))

    let firstRun = Task { try await firstPlugin.runner.isolateVoice(of: first, engine: { [weak engine] in engine }) }
    let secondRun = Task { try await secondPlugin.runner.isolateVoice(of: second, engine: { [weak engine] in engine }) }
    try await firstRun.value
    try await secondRun.value

    XCTAssertEqual(provider.calls, 2)
    XCTAssertEqual(provider.mostAtOnce, 1)
  }

  /// `.imgly.configuration` creates the plugin again on each environment update, so a second tap on a clip can reach
  /// another plugin instance while the first tap still runs.
  func testSecondTapOnARunningClipIsIgnoredByAnotherPluginInstance() async throws {
    let audio = try audioClip()
    let provider = FailingProvider()
    let reported = expectation(description: "The first run reports its error.")
    let secondCall = expectation(description: "The second tap cleans the clip again.")
    secondCall.isInverted = true
    provider.onSecondCall = { secondCall.fulfill() }
    let firstPlugin = VoiceIsolationPlugin(configuration: ProviderConfiguration(provider: provider),
                                           onError: { _ in reported.fulfill() })
    let secondPlugin = VoiceIsolationPlugin(configuration: ProviderConfiguration(provider: provider))
    let engine = try XCTUnwrap(engine)

    firstPlugin.runner.isolateVoiceForButton(of: audio, engine: engine)
    await provider.waitUntilStarted()
    secondPlugin.runner.isolateVoiceForButton(of: audio, engine: engine)
    provider.open()

    await fulfillment(of: [reported], timeout: 10)
    await fulfillment(of: [secondCall], timeout: 2)
  }

  // @requirement(voice-isolation/processing-state/code-call-left-to-app)
  /// The block call leaves the queue and the loading state to its caller.
  func testBlockCallNeitherWaitsForTheButtonNorChangesTheClipState() async throws {
    let first = try audioClip()
    let second = try audioClip()
    let gate = GatedProvider()
    let buttonPlugin = VoiceIsolationPlugin(configuration: ProviderConfiguration(provider: gate))
    let plugin = VoiceIsolationPlugin(configuration: ProviderConfiguration(provider: CopyingProvider()))
    let buttonRun = Task { try await buttonPlugin.runner.isolateVoice(of: first, engine: { [weak engine] in engine }) }
    await gate.waitUntilStarted()
    try engine.block.setState(second, state: .pending(progress: 0.2))

    let engine = try XCTUnwrap(engine)
    let call = Task { try await plugin.isolateVoice(of: second, engine: engine) }
    let finished = expectation(description: "The block call waited for the button's run.")
    Task {
      _ = await call.result
      finished.fulfill()
    }
    await fulfillment(of: [finished], timeout: 10)
    gate.open()

    let cleaned = try await call.value
    XCTAssertEqual(cleaned, second)
    XCTAssertEqual(try engine.block.getState(second), .pending(progress: 0.2))
    try await buttonRun.value
  }

  // MARK: - Helpers

  private func process(_ block: DesignBlockID, run: VoiceIsolationProcessor.Run = .call,
                       provider: any VoiceIsolationProvider = CopyingProvider()) async throws -> DesignBlockID {
    try await VoiceIsolationProcessor.process(block, engine: { [weak engine] in engine }, run: run, provider: provider)
  }

  private func audioClip(_ name: String = "speech-and-music.m4a") throws -> DesignBlockID {
    let audio = try engine.block.create(.audio)
    try engine.block.setString(audio, property: "audio/fileURI", value: fixture(name).absoluteString)
    try engine.block.appendChild(to: page, child: audio)
    return audio
  }

  private func videoClip(_ name: String = "speech-and-music.mp4") throws -> DesignBlockID {
    let video = try engine.block.create(.graphic)
    try engine.block.setShape(video, shape: engine.block.createShape(.rect))
    let fill = try engine.block.createFill(.video)
    try engine.block.setString(fill, property: "fill/video/fileURI", value: fixture(name).absoluteString)
    try engine.block.setFill(video, fill: fill)
    try engine.block.appendChild(to: page, child: video)
    return video
  }

  private func peak(of url: URL) throws -> Float {
    let file = try AVAudioFile(forReading: url)
    let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                frameCapacity: AVAudioFrameCount(file.length)))
    try file.read(into: buffer)
    let channels = try XCTUnwrap(buffer.floatChannelData)
    return (0 ..< Int(buffer.format.channelCount)).map { channel in
      UnsafeBufferPointer(start: channels[channel], count: Int(buffer.frameLength)).map(abs).max() ?? 0
    }.max() ?? 0
  }

  private func fixture(_ name: String) throws -> URL {
    try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil))
  }

  private func temporaryFile(_ fileExtension: String) -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      .appendingPathExtension(fileExtension)
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return url
  }

  /// Lets the engine's update loop run, which takes the undo snapshots.
  private func settle() async {
    try? await Task.sleep(for: .milliseconds(300))
  }

  private func writeClick(to url: URL, sampleRate: Double, channels: AVAudioChannelCount, seconds: Int,
                          at frame: Int) throws {
    let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels))
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    let frames = AVAudioFrameCount(sampleRate) * AVAudioFrameCount(seconds)
    let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
    buffer.frameLength = frames
    let samples = try XCTUnwrap(buffer.floatChannelData)
    for channel in 0 ..< Int(channels) {
      samples[channel].update(repeating: 0, count: Int(frames))
      samples[channel][frame] = 0.9
    }
    try file.write(from: buffer)
  }

  private func channels(of url: URL) throws -> [[Float]] {
    let file = try AVAudioFile(forReading: url)
    let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                frameCapacity: AVAudioFrameCount(file.length)))
    try file.read(into: buffer)
    let samples = try XCTUnwrap(buffer.floatChannelData)
    return (0 ..< Int(file.processingFormat.channelCount)).map {
      Array(UnsafeBufferPointer(start: samples[$0], count: Int(buffer.frameLength)))
    }
  }

  /// The first channel of what the engine plays for `block`.
  private func exportedAudio(of block: DesignBlockID) async throws -> [Float] {
    for try await event in try await engine.block.exportAudio(block, mimeType: .wav) {
      if case let .finished(audio: data) = event {
        let url = temporaryFile("wav")
        try data.write(to: url)
        return try channels(of: url)[0]
      }
    }
    throw VoiceIsolationError.noAudio
  }

  private func assertThrows(_ expected: VoiceIsolationError, _ body: @escaping () async throws -> Void,
                            file: StaticString = #filePath, line: UInt = #line) async {
    do {
      try await body()
      XCTFail("No error, expected \(expected).", file: file, line: line)
    } catch let error as VoiceIsolationError {
      XCTAssertEqual(String(describing: error), String(describing: expected), file: file, line: line)
    } catch {
      XCTFail("\(error), expected \(expected).", file: file, line: line)
    }
  }
}

// MARK: - Providers

private struct ProviderConfiguration: VoiceIsolationConfiguration {
  let provider: any VoiceIsolationProvider
}

private struct CopyingProvider: VoiceIsolationProvider {
  func isolateVoice(from input: URL, to output: URL) async throws {
    try FileManager.default.copyItem(at: input, to: output)
  }
}

/// Copies its input once the test opens it.
@MainActor
private final class GatedProvider: VoiceIsolationProvider {
  private var started: CheckedContinuation<Void, Never>?
  private var gate: CheckedContinuation<Void, Never>?
  private var hasStarted = false

  nonisolated func isolateVoice(from input: URL, to output: URL) async throws {
    await wait()
    try FileManager.default.copyItem(at: input, to: output)
  }

  private func wait() async {
    hasStarted = true
    started?.resume()
    await withCheckedContinuation { gate = $0 }
  }

  func waitUntilStarted() async {
    guard !hasStarted else { return }
    await withCheckedContinuation { started = $0 }
  }

  func open() {
    gate?.resume()
  }
}

/// Fails each clean, the first one once the test opens it.
@MainActor
private final class FailingProvider: VoiceIsolationProvider {
  var onSecondCall: (@MainActor () -> Void)?
  private var calls = 0
  private var started: CheckedContinuation<Void, Never>?
  private var gate: CheckedContinuation<Void, Never>?

  nonisolated func isolateVoice(from _: URL, to _: URL) async throws {
    await call()
    throw VoiceIsolationError.processingFailed("The test provider fails.")
  }

  private func call() async {
    calls += 1
    guard calls == 1 else {
      onSecondCall?()
      return
    }
    started?.resume()
    started = nil
    await withCheckedContinuation { gate = $0 }
  }

  func waitUntilStarted() async {
    guard calls == 0 else { return }
    await withCheckedContinuation { started = $0 }
  }

  func open() {
    gate?.resume()
  }
}

/// Copies its input after 30 s, or throws when its task is cancelled before.
@MainActor
private final class SlowProvider: VoiceIsolationProvider {
  private var started: CheckedContinuation<Void, Never>?
  private var hasStarted = false

  nonisolated func isolateVoice(from input: URL, to output: URL) async throws {
    await start()
    try await Task.sleep(for: .seconds(30))
    try FileManager.default.copyItem(at: input, to: output)
  }

  private func start() {
    hasStarted = true
    started?.resume()
  }

  func waitUntilStarted() async {
    guard !hasStarted else { return }
    await withCheckedContinuation { started = $0 }
  }
}

/// Copies its input after a short time, and counts the calls that run at once.
@MainActor
private final class CountingProvider: VoiceIsolationProvider {
  private(set) var calls = 0
  private(set) var mostAtOnce = 0
  private var running = 0

  nonisolated func isolateVoice(from input: URL, to output: URL) async throws {
    await begin()
    try await Task.sleep(for: .milliseconds(200))
    try FileManager.default.copyItem(at: input, to: output)
    await end()
  }

  private func begin() {
    calls += 1
    running += 1
    mostAtOnce = max(mostAtOnce, running)
  }

  private func end() {
    running -= 1
  }
}
