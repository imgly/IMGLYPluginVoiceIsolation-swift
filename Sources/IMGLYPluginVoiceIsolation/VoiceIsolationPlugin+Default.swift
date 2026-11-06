import IMGLYEditor

public extension VoiceIsolationPlugin {
  /// Creates the plugin with IMG.LY's on-device backend, ``IMGLYVoiceIsolationConfiguration``, with its defaults.
  ///
  /// - Parameters:
  ///   - onError: Called when the inspector bar button fails to clean a clip. If `nil`, errors are logged.
  ///   - inspectorBarModifier: Inserts the plugin's inspector bar button into the inspector bar. Defaults to prepending
  ///     it. A closure that does not insert the button leaves it out.
  convenience init(
    onError: (@MainActor @Sendable (Error) -> Void)? = nil,
    inspectorBarModifier: @escaping @MainActor @Sendable (
      _ items: InspectorBar.Modifier,
      _ button: any InspectorBar.Item,
    ) -> Void = { items, button in
      items.addFirst { button }
    },
  ) {
    self.init(
      configuration: IMGLYVoiceIsolationConfiguration(),
      onError: onError,
      inspectorBarModifier: inspectorBarModifier,
    )
  }
}
