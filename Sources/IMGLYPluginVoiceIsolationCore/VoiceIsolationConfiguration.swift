/// Voice isolation configuration passed to ``VoiceIsolationPlugin``.
///
/// Adopt this protocol to use a custom backend: pair a ``VoiceIsolationProvider`` with whatever configuration your
/// backend needs.
public protocol VoiceIsolationConfiguration: Sendable {
  /// The provider that removes music and noise.
  var provider: any VoiceIsolationProvider { get }
}
