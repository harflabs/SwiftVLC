import CLibVLC
import Dispatch
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
  /// Multiple concurrent log streams per instance are supported. Each
  /// active stream receives every log event that meets its own
  /// `minimumLevel` filter. The underlying libVLC log callback is
  /// installed on first subscription and removed when the last
  /// consumer's stream terminates.
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
  /// Swift's region analysis. Safety is provided by the enclosing
  /// `Mutex`: every read and write happens under `state.withLock`, so
  /// the non-Sendable pointer fields never straddle isolation domains.
  private struct State: @unchecked Sendable {
    var nextID: Int = 0
    var subscribers: [Int: Subscriber] = [:]
    /// The retained `LogBroadcaster` box passed to libVLC, or `nil` when
    /// the callback isn't installed. Owned by the C side while set.
    var selfBox: UnsafeMutableRawPointer?
    /// The shim bridge context returned by `swiftvlc_log_set`, or `nil`
    /// when the callback isn't installed.
    var bridgeContext: UnsafeMutableRawPointer?
    /// Prevents concurrent first-subscriber installs from racing each other.
    var isInstalling = false
  }

  private let state = Mutex(State())
  private let maintenanceQueue = DispatchQueue(label: "swiftvlc.logging.maintenance")
  nonisolated(unsafe) let instancePointer: OpaquePointer
  private let installBridge: @Sendable (OpaquePointer, UnsafeMutableRawPointer) -> UnsafeMutableRawPointer?
  private let uninstallBridge: @Sendable (OpaquePointer, UnsafeMutableRawPointer?) -> Void

  init(
    instancePointer: OpaquePointer,
    installBridge: @escaping @Sendable (OpaquePointer, UnsafeMutableRawPointer) -> UnsafeMutableRawPointer? = { instance, data in
      swiftvlc_log_set(instance, logCallback, data)
    },
    uninstallBridge: @escaping @Sendable (OpaquePointer, UnsafeMutableRawPointer?) -> Void = { instance, bridge in
      swiftvlc_log_unset(instance, bridge)
    }
  ) {
    self.instancePointer = instancePointer
    self.installBridge = installBridge
    self.uninstallBridge = uninstallBridge
  }

  func add(
    continuation: AsyncStream<LogEntry>.Continuation,
    minimumLevel: LogLevel
  ) -> Int {
    let id = state.withLock { state -> Int in
      let id = state.nextID
      state.nextID += 1
      state.subscribers[id] = Subscriber(
        continuation: continuation,
        minimumLevel: minimumLevel
      )
      return id
    }

    scheduleReconcile()
    return id
  }

  func remove(id: Int) {
    _ = state.withLock { state in
      state.subscribers.removeValue(forKey: id)
    }
    scheduleReconcile()
  }

  /// Terminates all active subscribers and uninstalls the libVLC log
  /// callback. Called from `VLCInstance.deinit`. After this returns,
  /// the libVLC instance pointer is about to be released, so no
  /// further callbacks can fire.
  func invalidate() {
    let subscribers = state.withLock { state -> [Subscriber] in
      let subs = Array(state.subscribers.values)
      state.subscribers.removeAll()
      return subs
    }

    for sub in subscribers {
      sub.continuation.finish()
    }

    maintenanceQueue.sync {
      reconcile()
    }
  }

  /// Called by the C callback (outside our lock) with a snapshot of subscribers.
  fileprivate func broadcast(_ entry: LogEntry) {
    // Snapshot under lock, yield outside. Same pattern as EventBridge,
    // to avoid AB-BA with task-cancellation locks.
    let snapshot = state.withLock { state -> [Subscriber] in
      state.subscribers.values.filter { entry.level >= $0.minimumLevel }
    }
    for sub in snapshot {
      sub.continuation.yield(entry)
    }
  }

  private enum Action {
    case install
    case uninstall(box: UnsafeMutableRawPointer, bridge: UnsafeMutableRawPointer?)
    case none
  }

  private func scheduleReconcile() {
    maintenanceQueue.async { [self] in
      reconcile()
    }
  }

  private func reconcile() {
    let action = state.withLock { state -> Action in
      if state.subscribers.isEmpty {
        guard let box = state.selfBox else { return .none }
        let bridge = state.bridgeContext
        state.selfBox = nil
        state.bridgeContext = nil
        return .uninstall(box: box, bridge: bridge)
      }

      guard state.selfBox == nil, !state.isInstalling else { return .none }
      state.isInstalling = true
      return .install
    }

    switch action {
    case .install:
      install()
    case .uninstall(let box, let bridge):
      uninstallBridge(instancePointer, bridge)
      Unmanaged<LogBroadcaster>.fromOpaque(box).release()
    case .none:
      return
    }
  }

  private func install() {
    let selfBox = Unmanaged.passRetained(self).toOpaque()
    let bridgeContext = installBridge(instancePointer, selfBox)

    let keepInstall = state.withLock { state -> Bool in
      state.isInstalling = false
      guard let bridgeContext, !state.subscribers.isEmpty, state.selfBox == nil else {
        return false
      }

      state.selfBox = selfBox
      state.bridgeContext = bridgeContext
      return true
    }

    guard !keepInstall else { return }

    if bridgeContext != nil {
      uninstallBridge(instancePointer, bridgeContext)
    }
    Unmanaged<LogBroadcaster>.fromOpaque(selfBox).release()
  }
}

/// C callback. Receives pre-formatted messages from the C shim and
/// runs on libVLC's internal logging thread.
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

  let messageString = String(cString: message)
  let moduleString = module.map { String(cString: $0) }

  // Severity correction for upstream messages whose declared level is
  // incongruent with the surrounding probe cascade. See `LogNoiseFilter`
  // for the rules and rationale.
  let effectiveLevel = LogNoiseFilter.reclassify(
    level: logLevel,
    module: moduleString,
    message: messageString
  )

  let entry = LogEntry(
    level: effectiveLevel,
    message: messageString,
    module: moduleString
  )

  broadcaster.broadcast(entry)
}
