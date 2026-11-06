import Foundation
@_spi(Internal) import IMGLYCore
@_spi(Internal) import IMGLYCoreUI

extension LocalizationTable {
  static let imglyPluginVoiceIsolation = LocalizationTable(
    table: "IMGLYPluginVoiceIsolation",
    bundle: .module,
  )
}

extension LocalizedStringResource {
  /// The editor's name for an audio clip without a name, which its Separate Audio gives the new clip too.
  static let editorClipAudioTitle: LocalizedStringResource = .imgly.localized("ly_img_editor_timeline_clip_audio_title")
  static let voiceIsolationInspectorBarButton: LocalizedStringResource = .imgly
    .localized("ly_img_plugin_voice_isolation_inspector_bar_button", table: .imglyPluginVoiceIsolation)
  static let voiceIsolationErrorFailed: LocalizedStringResource = .imgly
    .localized("ly_img_plugin_voice_isolation_error_failed", table: .imglyPluginVoiceIsolation)
  static let voiceIsolationErrorModelDownload: LocalizedStringResource = .imgly
    .localized("ly_img_plugin_voice_isolation_error_model_download", table: .imglyPluginVoiceIsolation)
  static let voiceIsolationErrorNoAudio: LocalizedStringResource = .imgly
    .localized("ly_img_plugin_voice_isolation_error_no_audio", table: .imglyPluginVoiceIsolation)
}
