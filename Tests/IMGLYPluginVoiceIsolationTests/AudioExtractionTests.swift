import IMGLYEngine
import XCTest

/// The engine behaviour that the plugin's audio input relies on: `createAudioFromVideo` fills the buffer of the new
/// audio block before it returns, so the plugin reads the played track in the same turn and no engine update sees the
/// block.
@MainActor
final class AudioExtractionTests: XCTestCase {
  private var engine: Engine!
  private var page: DesignBlockID = 0

  override func setUp() async throws {
    engine = try await Engine(context: .offscreen(size: CGSize(width: 100, height: 100)), audioContext: .none)
    let scene = try engine.scene.createVideo()
    page = try engine.block.create(.page)
    try engine.block.appendChild(to: scene, child: page)
  }

  override func tearDown() async throws {
    engine = nil
  }

  func testExtractedBufferIsCompleteWhenTheCallReturnsForALocalVideo() async throws {
    let url = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/speech-and-music.mp4", withExtension: nil))
    try await assertExtractedBufferIsComplete(url)
  }

  // MARK: - Helpers

  private func assertExtractedBufferIsComplete(_ url: URL, file: StaticString = #filePath,
                                               line: UInt = #line) async throws {
    let video = try engine.block.create(.graphic)
    try engine.block.setShape(video, shape: engine.block.createShape(.rect))
    let fill = try engine.block.createFill(.video)
    try engine.block.setString(fill, property: "fill/video/fileURI", value: url.absoluteString)
    try engine.block.setFill(video, fill: fill)
    try engine.block.appendChild(to: page, child: video)
    try await engine.block.forceLoadAVResource(fill)

    let audio = try engine.block.createAudioFromVideo(
      fill,
      trackIndex: 0,
      options: .init(keepTrimSettings: false, muteOriginalVideo: false),
    )
    let buffer = try XCTUnwrap(URL(string: engine.block.getString(audio, property: "audio/fileURI")))
    let lengthAtReturn = try engine.editor.getBufferLength(url: buffer).intValue
    try await engine.block.forceLoadAVResource(audio)
    let lengthAfterLoad = try engine.editor.getBufferLength(url: buffer).intValue

    XCTAssertEqual(buffer.scheme, "buffer", file: file, line: line)
    XCTAssertGreaterThan(lengthAtReturn, 0, "The buffer is empty when the call returns.", file: file, line: line)
    XCTAssertEqual(lengthAtReturn, lengthAfterLoad, "The buffer grew after the call returned.", file: file, line: line)
  }
}
