@testable import SwiftVLC
import Testing

extension Logic {
  @Suite(.tags(.async))
  struct ThumbnailCoordinatorTests {
    @Test
    func `queued acquire resumes when active request releases`() async throws {
      let coordinator = ThumbnailCoordinator()
      try await coordinator.acquire()

      let waiter = Task {
        try await coordinator.acquire()
        await coordinator.release()
        return true
      }

      await allowQueuedAcquireToSuspend()
      await coordinator.release()

      #expect(try await waiter.value)

      try await coordinator.acquire()
      await coordinator.release()
    }

    @Test
    func `queued acquire throws cancellation error when cancelled while waiting`() async throws {
      let coordinator = ThumbnailCoordinator()
      try await coordinator.acquire()

      let waiter = Task {
        do {
          try await coordinator.acquire()
          await coordinator.release()
          Issue.record("Expected queued acquire to throw after cancellation")
          return false
        } catch let error as VLCError {
          guard case .operationFailed(let reason) = error else {
            Issue.record("Expected operationFailed cancellation, got \(error)")
            return false
          }
          return reason.contains("cancelled")
        } catch {
          Issue.record("Expected operationFailed cancellation, got \(error)")
          return false
        }
      }

      await allowQueuedAcquireToSuspend()
      waiter.cancel()

      #expect(await waiter.value)
      await coordinator.release()
    }

    @Test
    func `release skips cancelled waiters and opens the next waiter`() async throws {
      let coordinator = ThumbnailCoordinator()
      try await coordinator.acquire()

      let cancelledWaiter = Task {
        try await coordinator.acquire()
        await coordinator.release()
      }
      await allowQueuedAcquireToSuspend()
      cancelledWaiter.cancel()
      _ = await cancelledWaiter.result

      let nextWaiter = Task {
        try await coordinator.acquire()
        await coordinator.release()
        return true
      }
      await allowQueuedAcquireToSuspend()

      await coordinator.release()

      #expect(try await nextWaiter.value)
    }

    private func allowQueuedAcquireToSuspend() async {
      for _ in 0..<10 {
        await Task.yield()
      }
      try? await Task.sleep(for: .milliseconds(10))
    }
  }
}
