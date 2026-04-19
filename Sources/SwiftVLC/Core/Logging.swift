import CLibVLC
import Synchronization

/// A single log message from libVLC.
public struct LogEntry: Sendable {
  /// Severity level of this log message.
  public let level: LogLevel
  /// The formatted log message text.
  public let message: String
  /// The libVLC module that emitted this message (e.g. "avcodec", "http").
  public let module: String?
}

/// libVLC log severity levels, ordered from least to most severe.
public enum LogLevel: Int32, Sendable, Comparable, CustomStringConvertible {
  /// Verbose diagnostic information for debugging.
  case debug = 0
  /// Informational messages about normal operations.
  case notice = 2
  /// Potential problems that don't prevent playback.
  case warning = 3
  /// Failures that may affect playback.
  case error = 4

  public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
    lhs.rawValue < rhs.rawValue
  }

  public var description: String {
    switch self {
    case .debug: "debug"
    case .notice: "notice"
    case .warning: "warning"
    case .error: "error"
    }
  }
}

extension VLCInstance {
  /// Creates an `AsyncStream` of libVLC log messages.
  ///
  /// Multiple concurrent log streams per instance are supported — all active streams
  /// receive every log event that meets their individual `minimumLevel` filter.
  /// The underlying libVLC log callback is installed on first subscription and
  /// removed when the last consumer's stream terminates.
  ///
  /// ```swift
  /// for await entry in VLCInstance.shared.logStream(minimumLevel: .warning) {
  ///     print("[\(entry.level)] \(entry.message)")
  /// }
  /// ```
  ///
  /// - Parameter minimumLevel: Only yield entries at or above this level.
  /// - Returns: An `AsyncStream` of `LogEntry` values.
  public func logStream(
    minimumLevel: LogLevel = .warning
  ) -> AsyncStream<LogEntry> {
    let (stream, continuation) = AsyncStream<LogEntry>.makeStream(
      bufferingPolicy: .bufferingNewest(128)
    )

    let id = logBroadcaster.add(continuation: continuation, minimumLevel: minimumLevel)

    let broadcaster = logBroadcaster
    continuation.onTermination = { @Sendable _ in
      broadcaster.remove(id: id)
    }

    return stream
  }
}

// MARK: - Internal Broadcaster

/// Multiplexes a single libVLC log callback to multiple Swift consumers.
///
/// The libVLC log callback is installed lazily on the first consumer and
/// uninstalled when the last consumer terminates. Each consumer has its
/// own `minimumLevel` filter, so subscribers don't leak messages to each other.
///
/// Thread-safety: all mutable state is guarded by a `Mutex`. The C callback
/// runs on libVLC's internal logging thread; yield happens outside the lock
/// to avoid blocking the logger on slow consumers.
final class LogBroadcaster: Sendable {
  private struct Subscriber {
    let continuation: AsyncStream<LogEntry>.Continuation
    let minimumLevel: LogLevel
  }

  /// `@unchecked` because `UnsafeMutableRawPointer` isn't Sendable under
  /// Swift's region analysis. Safety is provided by the enclosing `Mutex`
  /// — every read/write happens under `state.withLock`, so the non-Sendable
  /// pointer fields never straddle isolation domains.
  private struct State: @unchecked Sendable {
    var nextID: Int = 0
    var subscribers: [Int: Subscriber] = [:]
    /// The retained `LogBroadcaster` box passed to libVLC, or `nil` when
    /// the callback isn't installed. Owned by the C side while set.
    var selfBox: UnsafeMutableRawPointer?
    /// The shim bridge context returned by `swiftvlc_log_set`, or `nil`
    /// when the callback isn't installed.
    var bridgeContext: UnsafeMutableRawPointer?
  }

  private let state = Mutex(State())
  nonisolated(unsafe) let instancePointer: OpaquePointer

  init(instancePointer: OpaquePointer) {
    self.instancePointer = instancePointer
  }

  func add(
    continuation: AsyncStream<LogEntry>.Continuation,
    minimumLevel: LogLevel
  ) -> Int {
    let (id, shouldInstall) = state.withLock { state -> (Int, Bool) in
      let id = state.nextID
      state.nextID += 1
      state.subscribers[id] = Subscriber(
        continuation: continuation,
        minimumLevel: minimumLevel
      )
      // Try to install whenever the callback isn't currently registered —
      // not just for the first subscriber. If a previous install() failed
      // (e.g. shim malloc returned NULL under memory pressure), every
      // subsequent subscriber retries so we self-heal rather than stay
      // silent forever.
      return (id, state.selfBox == nil)
    }

    if shouldInstall {
      install()
    }
    return id
  }

  func remove(id: Int) {
    let uninstall = state.withLock { state -> (bridge: UnsafeMutableRawPointer?, box: UnsafeMutableRawPointer)? in
      state.subscribers.removeValue(forKey: id)
      guard state.subscribers.isEmpty, let box = state.selfBox else { return nil }
      let bridge = state.bridgeContext
      state.bridgeContext = nil
      state.selfBox = nil
      return (bridge, box)
    }

    guard let uninstall else { return }
    swiftvlc_log_unset(instancePointer, uninstall.bridge)
    Unmanaged<LogBroadcaster>.fromOpaque(uninstall.box).release()
  }

  /// Terminates all active subscribers and uninstalls the libVLC log
  /// callback. Called from `VLCInstance.deinit` — after this returns,
  /// the libVLC instance pointer is about to be released, so no further
  /// callbacks can fire.
  func invalidate() {
    let (subscribers, uninstall) = state.withLock { state
      -> ([Subscriber], (bridge: UnsafeMutableRawPointer?, box: UnsafeMutableRawPointer)?) in
      let subs = Array(state.subscribers.values)
      state.subscribers.removeAll()
      let capture: (bridge: UnsafeMutableRawPointer?, box: UnsafeMutableRawPointer)? =
        state.selfBox.map { (state.bridgeContext, $0) }
      state.bridgeContext = nil
      state.selfBox = nil
      return (subs, capture)
    }

    for sub in subscribers {
      sub.continuation.finish()
    }

    if let uninstall {
      swiftvlc_log_unset(instancePointer, uninstall.bridge)
      Unmanaged<LogBroadcaster>.fromOpaque(uninstall.box).release()
    }
  }

  /// Called by the C callback (outside our lock) with a snapshot of subscribers.
  fileprivate func broadcast(_ entry: LogEntry) {
    // Snapshot under lock, yield outside — same pattern as EventBridge to
    // avoid AB-BA with task-cancellation locks.
    let snapshot = state.withLock { state -> [Subscriber] in
      state.subscribers.values.filter { entry.level >= $0.minimumLevel }
    }
    for sub in snapshot {
      sub.continuation.yield(entry)
    }
  }

  private func install() {
    let selfBox = Unmanaged.passRetained(self).toOpaque()
    guard let bridgeContext = swiftvlc_log_set(instancePointer, logCallback, selfBox) else {
      // Shim malloc failed. Release the retained self and bail;
      // subscribers receive no events until a later install() succeeds.
      Unmanaged<LogBroadcaster>.fromOpaque(selfBox).release()
      return
    }

    state.withLock {
      $0.selfBox = selfBox
      $0.bridgeContext = bridgeContext
    }
  }
}

/// C callback — receives pre-formatted messages from the C shim.
/// Runs on libVLC's internal logging thread.
/// `AsyncStream.Continuation.yield` is safe to call from any thread.
private func logCallback(
  data: UnsafeMutableRawPointer?,
  level: Int32,
  module: UnsafePointer<CChar>?,
  message: UnsafePointer<CChar>?
) {
  guard let data, let message else { return }

  let broadcaster = Unmanaged<LogBroadcaster>.fromOpaque(data).takeUnretainedValue()

  guard let logLevel = LogLevel(rawValue: level) else { return }

  let entry = LogEntry(
    level: logLevel,
    message: String(cString: message),
    module: module.map { String(cString: $0) }
  )

  broadcaster.broadcast(entry)
}
