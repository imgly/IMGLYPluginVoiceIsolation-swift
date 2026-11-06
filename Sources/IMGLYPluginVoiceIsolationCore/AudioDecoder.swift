import AVFoundation

/// Decodes audio into the input format of ``VoiceIsolationProvider``.
enum AudioDecoder {
  static let sampleRate = 48000

  /// Decodes the first audio track of `source` into a 16-bit PCM WAV file at 48 kHz, a slice at a time, so a long clip
  /// is never resident at once. Mono stays mono. More than two channels become stereo, because AVFoundation needs
  /// a channel layout to keep them.
  @concurrent
  static func decode(_ source: URL, to destination: URL) async throws {
    let asset = AVURLAsset(url: source)
    // The engine plays formats that AVFoundation cannot open, such as Opus in WebM.
    let tracks: [AVAssetTrack]
    do {
      tracks = try await asset.loadTracks(withMediaType: .audio)
    } catch {
      throw VoiceIsolationError.processingFailed(error.localizedDescription)
    }
    guard let track = tracks.first else {
      throw VoiceIsolationError.noAudio
    }
    let format = try await track.load(.formatDescriptions).first
      .flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
    let channelCount = min(2, max(1, Int(format?.mChannelsPerFrame ?? 1)))
    let settings: [String: Any] = [
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVSampleRateKey: sampleRate,
      AVNumberOfChannelsKey: channelCount,
      AVLinearPCMBitDepthKey: 16,
      AVLinearPCMIsFloatKey: false,
      AVLinearPCMIsBigEndianKey: false,
      AVLinearPCMIsNonInterleaved: false,
    ]
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
    reader.add(output)
    guard reader.startReading() else {
      throw VoiceIsolationError.processingFailed(reader.error?.localizedDescription ?? "Could not read the audio.")
    }
    defer { reader.cancelReading() }
    // A scope of its own, because the file is written when it closes.
    do {
      let file = try AVAudioFile(forWriting: destination, settings: settings, commonFormat: .pcmFormatInt16,
                                 interleaved: true)
      while let sampleBuffer = output.copyNextSampleBuffer() {
        try Task.checkCancellation()
        try file.write(from: pcmBuffer(of: sampleBuffer, format: file.processingFormat))
      }
    }
    if reader.status == .failed {
      throw VoiceIsolationError.processingFailed(reader.error?.localizedDescription ?? "Could not read the audio.")
    }
  }

  private static func pcmBuffer(of sampleBuffer: CMSampleBuffer, format: AVAudioFormat) throws -> AVAudioPCMBuffer {
    let frames = CMSampleBufferGetNumSamples(sampleBuffer)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else {
      throw VoiceIsolationError.processingFailed("Could not allocate an audio buffer.")
    }
    buffer.frameLength = buffer.frameCapacity
    let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(frames),
                                                              into: buffer.mutableAudioBufferList)
    guard status == noErr else {
      throw VoiceIsolationError.processingFailed("Could not copy the decoded audio (\(status)).")
    }
    return buffer
  }
}
