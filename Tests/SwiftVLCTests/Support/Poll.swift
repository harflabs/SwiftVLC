import Foundation

/// Polls a condition, sleeping off the main actor between checks so VLC events can process.
/// Returns `true` if the condition was met, `false` if it timed out.
@MainActor
func poll(
  every interval: Duration = .milliseconds(50),
  timeout: Duration = .seconds(3),
  until condition: @MainActor () -> Bool
)
  async throws -> Bool {
  let deadline = ContinuousClock.now + timeout
  while !condition() {
    if ContinuousClock.now >= deadline { return false }
    try await Task.sleep(for: interval)
  }
  return true
}
