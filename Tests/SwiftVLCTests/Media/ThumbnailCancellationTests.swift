@testable import SwiftVLC
import Foundation
import Testing

/// Covers `Media.thumbnail(...)` cancellation paths. The happy path
/// and "nonzero response" paths are in `ThumbnailRequestTests`; this
/// suite pins the cooperative-cancellation contract: a Task that's
/// cancelled before invocation returns `.operationFailed("…: cancelled")`
/// immediately without touching libVLC.
extension Integration {
  @Suite(.tags(.media, .async)) struct ThumbnailCancellationTests {
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

    /// Audio-only media has no video frame to extract, but the request
    /// should still run through libVLC's thumbnailer and return a typed
    /// failure instead of hanging or requiring real video output.
    @Test(.timeLimit(.minutes(1)))
    func `Audio-only thumbnail request reports failure without video output`() async throws {
      let media = try Media(url: TestMedia.silenceURL)

      do {
        _ = try await media.thumbnail(
          at: .zero,
          width: 64,
          timeout: .milliseconds(500),
          instance: TestInstance.shared
        )
        Issue.record("Expected audio-only media to fail thumbnail generation")
      } catch .operationFailed(let reason) {
        #expect(reason.contains("Generate thumbnail"))
      } catch {
        Issue.record("Expected operationFailed, got \(error)")
      }
    }

    /// A video thumbnail request should always complete promptly even
    /// on the no-video CI instance. Depending on libVLC's thumbnailer
    /// availability it may produce a PNG or report an operation failure;
    /// both outcomes are valid, but hanging is not.
    @Test(.timeLimit(.minutes(1)))
    func `Video thumbnail request completes without real video output`() async throws {
      let media = try Media(url: TestMedia.testMP4URL)

      do {
        let data = try await media.thumbnail(
          at: .zero,
          width: 32,
          timeout: .milliseconds(500),
          instance: TestInstance.shared
        )
        #expect(!data.isEmpty)
      } catch .operationFailed(let reason) {
        #expect(reason.contains("Generate thumbnail"))
      } catch {
        Issue.record("Expected success or operationFailed, got \(error)")
      }
    }

    @Test(.tags(.async, .media), .timeLimit(.minutes(1)))
    func `Already cancelled thumbnail request returns promptly and releases its slot`() async throws {
      let media = try Media(url: TestMedia.testMP4URL)

      let task = Task {
        withUnsafeCurrentTask { task in
          task?.cancel()
        }

        return try await media.thumbnail(
          at: .zero,
          width: 64,
          timeout: .seconds(5),
          instance: TestInstance.shared
        )
      }

      switch await task.result {
      case .success:
        Issue.record("Expected cancellation error")
      case .failure(let error):
        #expect(String(describing: error).contains("cancelled"))
      }

      do {
        _ = try await media.thumbnail(
          at: .zero,
          width: 64,
          timeout: .milliseconds(500),
          instance: TestInstance.shared
        )
      } catch {
        #expect(String(describing: error).contains("Generate thumbnail"))
      }
    }
  }
}
