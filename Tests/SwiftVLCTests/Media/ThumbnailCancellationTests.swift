@testable import SwiftVLC
import Foundation
import Testing

/// Covers `Media.thumbnail(...)` cancellation paths. The happy path
/// and "nonzero response" paths are in `ThumbnailRequestTests`; this
/// suite pins the cooperative-cancellation contract: a Task that's
/// cancelled before invocation returns `.operationFailed("…: cancelled")`
/// immediately without touching libVLC.
@Suite(.tags(.integration, .media, .async))
struct ThumbnailCancellationTests {
  /// `Task.isCancelled` is checked before any libVLC work happens.
  /// A task that's already cancelled must throw straight through
  /// the `coordinator.acquire()` guard at the top of `thumbnail`.
  @Test
  func `Pre-cancelled task propagates cancellation from acquire`() async throws {
    let media = try Media(url: TestMedia.twosecURL)

    let task = Task {
      try await media.thumbnail(
        at: .milliseconds(100),
        timeout: .milliseconds(500)
      )
    }
    task.cancel()

    let result = await task.result
    switch result {
    case .success:
      Issue.record("Expected cancellation error")
    case .failure(let error as VLCError):
      guard case .operationFailed(let reason) = error else {
        Issue.record("Expected .operationFailed, got \(error)")
        return
      }
      #expect(reason.contains("cancelled"))
    case .failure(let error):
      Issue.record("Unexpected error type: \(error)")
    }
  }

  /// A task that's cancelled mid-wait (after acquire returns but
  /// before the libVLC request completes) must abort the request
  /// via `onCancel`. Since the thumbnail generation in our fixture
  /// is essentially instant, we race cancellation against completion
  /// — either the cancel wins (operationFailed: cancelled) or the
  /// completion wins (success or some other VLCError).
  ///
  /// The goal of this test is to pin that a racing cancel never
  /// crashes or deadlocks — the result shape is secondary.
  @Test
  func `Cancellation mid-wait does not crash`() async throws {
    let media = try Media(url: TestMedia.twosecURL)

    let task = Task {
      try await media.thumbnail(
        at: .milliseconds(100),
        timeout: .milliseconds(500)
      )
    }
    try? await Task.sleep(for: .microseconds(10))
    task.cancel()

    _ = await task.result
    // Success: no crash, no deadlock.
  }

  /// Back-to-back cancelled thumbnail calls must release the
  /// `ThumbnailCoordinator`'s busy flag correctly — otherwise the
  /// second call would hang waiting for the first's gate.
  @Test
  func `Two cancelled thumbnails in a row both return promptly`() async throws {
    let media = try Media(url: TestMedia.twosecURL)

    for _ in 0..<2 {
      let task = Task {
        try await media.thumbnail(
          at: .milliseconds(100),
          timeout: .milliseconds(500)
        )
      }
      task.cancel()
      _ = await task.result
    }
  }
}
