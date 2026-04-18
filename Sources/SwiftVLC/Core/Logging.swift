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

  private struct State {
    var nextID: Int = 0
    var subscribers: [Int: Subscriber] = [:]
    /// The opaque broadcaster pointer passed to libVLC, or 0 if not installed.
    var selfBoxBits: Int = 0
    /// The shim bridge context returned by `swiftvlc_log_set`, or 0 if not installed.
    var bridgeContextBits: Int = 0
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
      return (id, state.selfBoxBits == 0)
    }

    if shouldInstall {
      install()
    }
    return id
  }

  func remove(id: Int) {
    let uninstall = state.withLock { state -> (Int, Int)? in
      state.subscribers.removeValue(forKey: id)
      guard state.subscribers.isEmpty, state.selfBoxBits != 0 else { return nil }
      let capture = (state.bridgeContextBits, state.selfBoxBits)
      state.bridgeContextBits = 0
      state.selfBoxBits = 0
      return capture
    }

    guard let (bridgeBits, boxBits) = uninstall else { return }
    let bridge = UnsafeMutableRawPointer(bitPattern: bridgeBits)
    swiftvlc_log_unset(instancePointer, bridge)
    if let rawBox = UnsafeMutableRawPointer(bitPattern: boxBits) {
      Unmanaged<LogBroadcaster>.fromOpaque(rawBox).release()
    }
  }

  /// Terminates all active subscribers and uninstalls the libVLC log
  /// callback. Called from `VLCInstance.deinit` — after this returns,
  /// the libVLC instance pointer is about to be released, so no further
  /// callbacks can fire.
  func invalidate() {
    let (subscribers, uninstall) = state.withLock { state
      -> ([Subscriber], (Int, Int)?) in
      let subs = Array(state.subscribers.values)
      state.subscribers.removeAll()
      let capture: (Int, Int)? = state.selfBoxBits != 0
        ? (state.bridgeContextBits, state.selfBoxBits)
        : nil
      state.bridgeContextBits = 0
      state.selfBoxBits = 0
      return (subs, capture)
    }

    for sub in subscribers {
      sub.continuation.finish()
    }

    if let (bridgeBits, boxBits) = uninstall {
      let bridge = UnsafeMutableRawPointer(bitPattern: bridgeBits)
      swiftvlc_log_unset(instancePointer, bridge)
      if let rawBox = UnsafeMutableRawPointer(bitPattern: boxBits) {
        Unmanaged<LogBroadcaster>.fromOpaque(rawBox).release()
      }
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
      // Shim malloc failed — release the retained self and bail. Subscribers
      // will simply see no events until the next (hopefully successful) install.
      Unmanaged<LogBroadcaster>.fromOpaque(selfBox).release()
      return
    }

    state.withLock {
      $0.selfBoxBits = Int(bitPattern: selfBox)
      $0.bridgeContextBits = Int(bitPattern: bridgeContext)
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
