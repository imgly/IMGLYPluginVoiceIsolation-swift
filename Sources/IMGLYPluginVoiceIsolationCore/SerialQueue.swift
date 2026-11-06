import Foundation

/// Gives out one turn at a time, in the order of the calls to `waitForTurn()`.
@MainActor
final class SerialQueue {
  private struct Waiter {
    let id: UUID
    let continuation: CheckedContinuation<Void, any Swift.Error>
  }

  private var isBusy = false
  private var waiters: [Waiter] = []

  init() {}

  /// Returns when every earlier turn ended. Each turn that this returns must end with `endTurn()`. A call whose task is
  /// cancelled while it waits throws `CancellationError` at once and takes no turn.
  func waitForTurn() async throws {
    guard isBusy else {
      isBusy = true
      return
    }
    let id = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        waiters.append(Waiter(id: id, continuation: continuation))
      }
    } onCancel: {
      Task { @MainActor in
        self.removeWaiter(id)
      }
    }
  }

  func endTurn() {
    if waiters.isEmpty {
      isBusy = false
    } else {
      waiters.removeFirst().continuation.resume()
    }
  }

  private func removeWaiter(_ id: UUID) {
    guard let index = waiters.firstIndex(where: { $0.id == id }) else {
      return
    }
    waiters.remove(at: index).continuation.resume(throwing: CancellationError())
  }
}
