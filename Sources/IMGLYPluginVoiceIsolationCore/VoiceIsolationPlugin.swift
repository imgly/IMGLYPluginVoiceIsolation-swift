import IMGLYEditor
import IMGLYEngine
import OSLog
import SwiftUI

// MARK: - Logger

extension Logger {
  static let plugin = Logger(subsystem: "ly.img.plugin.voiceIsolation", category: "VoiceIsolationPlugin")
}

// MARK: - Voice Isolation Plugin

/// Removes music and background noise from the audio of video and audio clips, on the device.
///
/// The "Isolate Voice" inspector bar button cleans the selected clip. A video clip first gets the audio track that it
/// plays separated, as with the editor's Separate Audio: one new audio clip plays the cleaned audio, and the video clip
/// is muted. An audio clip is cleaned in place. The clip shows the loading state while the model runs, the model runs
/// on one clip at a time, and one undo step brings the original audio back.
///
/// Each cleaned clip plays a local WAV file (16-bit, 48 kHz, mono or stereo as the source) from the app's Application
/// Support directory. The plugin uploads nothing; use `relocateResource(currentURL:relocatedURL:)` to keep
/// the files elsewhere.
@MainActor
public final class VoiceIsolationPlugin: EditorConfiguration {
  private let provider: any VoiceIsolationProvider
  let runner: Runner
  private let inspectorBarModifier: @MainActor @Sendable (
    _ items: InspectorBar.Modifier,
    _ button: any InspectorBar.Item,
  ) -> Void

  /// Creates the plugin.
  ///
  /// - Parameters:
  ///   - configuration: The voice isolation backend to use.
  ///   - onError: Called when the inspector bar button fails to clean a clip. If `nil`, errors are logged.
  ///   - inspectorBarModifier: Inserts the plugin's inspector bar button into the inspector bar. Defaults to prepending
  ///     it. A closure that does not insert the button leaves it out.
  public init(
    configuration: any VoiceIsolationConfiguration,
    onError: (@MainActor @Sendable (any Swift.Error) -> Void)? = nil,
    inspectorBarModifier: @escaping @MainActor @Sendable (
      _ items: InspectorBar.Modifier,
      _ button: any InspectorBar.Item,
    ) -> Void = { items, button in
      items.addFirst { button }
    },
  ) {
    let provider = configuration.provider
    self.provider = provider
    runner = Runner(provider: provider, errorHandler: onError)
    self.inspectorBarModifier = inspectorBarModifier
    super.init()
  }

  // MARK: - Block call

  /// Whether ``isolateVoice(of:engine:)`` can clean `block`: an audio clip with a file, but not a voiceover that still
  /// records, or a video clip with a file whose audio the editor can separate, and in both cases the `"fill/change"`
  /// scope is allowed.
  public static func canIsolateVoice(of block: DesignBlockID, engine: Engine) -> Bool {
    VoiceIsolationProcessor.canProcess(block, engine: engine)
  }

  /// Cleans the audio of `block` and returns when the result is in the scene. A video clip gets the audio track that it
  /// plays separated first, as with the editor's Separate Audio.
  ///
  /// Unlike the inspector bar button, the call does not wait for other runs, shows no loading state and adds no undo
  /// step, so that the caller decides. Calls that run at the same time decode their audio and call the provider at the
  /// same time. IMG.LY's provider runs its model on one file after the other.
  ///
  /// - Parameters:
  ///   - block: An audio clip, or a video clip with audio.
  ///   - engine: The editor's engine.
  /// - Returns: The cleaned audio clip: `block` itself for an audio clip, or the new audio clip of a video clip.
  /// - Throws: ``VoiceIsolationError``, an error of the provider, an error of the engine, AVFoundation, the network
  ///   connection or the file system, or `CancellationError` when the editor closes.
  public func isolateVoice(of block: DesignBlockID, engine: Engine) async throws -> DesignBlockID {
    try await VoiceIsolationProcessor.process(block, engine: { [weak engine] in engine }, run: .call,
                                              provider: provider)
  }

  // MARK: - Lifecycle

  /// The `onCreate` handler. Triggers the provider's warm-up hook.
  override public var onCreate: OnCreate.Handler? {
    let provider = provider
    return { _, existing in
      try await existing()
      // Detached, so that a model download does not hold up the editor's `onCreate`.
      // swiftlint:disable:next task_detached
      Task.detached(priority: .background) {
        do {
          try await provider.prewarm()
        } catch {
          // The first clean retries and reports a persistent failure through `onError`.
          Logger.plugin.error("Prewarm failed: \(error.localizedDescription, privacy: .public)")
        }
      }
    }
  }

  // MARK: - Inspector Bar

  private var inspectorBarButton: any InspectorBar.Item {
    // The action captures the runner, not the plugin: the plugin keeps its button in its builder, so a button that
    // captures the plugin keeps the plugin and its model alive.
    let runner = runner
    return InspectorBar.Button(
      id: "ly.img.component.inspectorBar.button.voiceIsolation",
      action: { context in
        runner.isolateVoiceForButton(of: context.selection.block, engine: context.engine)
      },
      label: { _ in
        Label {
          Text(.voiceIsolationInspectorBarButton)
        } icon: {
          Image(systemName: "person.wave.2.fill")
        }
      },
      isVisible: { context in
        VoiceIsolationPlugin.canIsolateVoice(of: context.selection.block, engine: context.engine)
      },
    )
  }

  /// The inspector bar configuration. Inserts the voice isolation button.
  override public var inspectorBar: InspectorBar.Configuration? {
    let button = inspectorBarButton
    let inspectorBarModifier = inspectorBarModifier
    return InspectorBar.Configuration { builder in
      builder.modify { _, items in
        inspectorBarModifier(items, button)
      }
    }
  }
}

// MARK: - Runner

extension VoiceIsolationPlugin {
  /// Runs the button's cleaning of each block on one queue, so the model runs on one clip at a time.
  @MainActor
  final class Runner {
    /// One queue for every plugin instance, because `.imgly.configuration` creates the plugin again on each
    /// environment update while an earlier instance can still clean a clip.
    private static let modelQueue = SerialQueue()
    /// The clips whose button run has not ended. One set for every plugin instance, for the same reason as
    /// `modelQueue`.
    private static var buttonRuns: Set<ButtonRun> = []
    private let provider: any VoiceIsolationProvider
    private let errorHandler: (@MainActor @Sendable (any Swift.Error) -> Void)?

    init(provider: any VoiceIsolationProvider, errorHandler: (@MainActor @Sendable (any Swift.Error) -> Void)?) {
      self.provider = provider
      self.errorHandler = errorHandler
    }

    /// Cleans `block` as the button does. `engine` returns `nil` once the editor freed it, so a run writes nothing into
    /// a closed editor.
    func isolateVoice(of block: DesignBlockID, engine: @escaping @MainActor () -> Engine?) async throws {
      _ = try await VoiceIsolationProcessor.process(block, engine: engine, run: .button(queue: Self.modelQueue),
                                                    provider: provider)
    }

    /// Cleans `block` and adds one undo step. Ignores a tap on a block whose last tap still runs, also in another
    /// plugin instance.
    func isolateVoiceForButton(of block: DesignBlockID, engine: Engine) {
      let run = ButtonRun(engine: ObjectIdentifier(engine), block: block)
      guard Self.buttonRuns.insert(run).inserted else { return }
      Task { [weak engine] in
        defer { Self.buttonRuns.remove(run) }
        do {
          try await isolateVoice(of: block, engine: { engine })
        } catch is CancellationError {
          // The editor closed.
        } catch VoiceIsolationError.blockChanged {
          // The user changed or deleted the clip, so the result is no longer wanted.
        } catch {
          report(error)
        }
      }
    }

    private func report(_ error: any Swift.Error) {
      if let errorHandler {
        errorHandler(error)
      } else {
        Logger.plugin.error("\(error.localizedDescription, privacy: .public)")
      }
    }
  }
}

/// A clip of one editor: a block ID is unique only in its engine.
private struct ButtonRun: Hashable {
  let engine: ObjectIdentifier
  let block: DesignBlockID
}
