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
    logBroadcaster.subscribe(minimumLevel: minimumLevel)
  }
}

// MARK: - Internal Broadcaster

/// Multiplexes a single libVLC log callback to multiple Swift consumers.
///
/// Thin wrapper around `Broadcaster<LogEntry>` plus the lazy install /
/// uninstall of libVLC's log callback. The callback is installed when
/// the first subscriber attaches and uninstalled when the last one
/// terminates, so we don't pay libVLC's logging cost while no one is
/// listening.
final class LogBroadcaster: Sendable {
  /// Shared reference held by both `LogBroadcaster` and the
  /// `Broadcaster<LogEntry>`'s lifecycle callbacks. A separate class
  /// (rather than a `Mutex` directly on `LogBroadcaster`) is what lets
  /// the closures retain it independently of `self`, sidestepping
  /// Mutex's `~Copyable` constraint and the no-self-yet problem during
  /// `init`.
  private final class Installation: Sendable {
    /// `@unchecked` because the bridge context is an
    /// `UnsafeMutableRawPointer` returned by libVLC's shim. Every read
    /// and write happens under `state.withLock`, so the non-Sendable
    /// pointer never straddles isolation domains.
    struct State: @unchecked Sendable {
      var bridgeContext: UnsafeMutableRawPointer?
      var selfBox: UnsafeMutableRawPointer?
    }

    let state = Mutex(State())
    nonisolated(unsafe) let instancePointer: OpaquePointer
    let installBridge: @Sendable (OpaquePointer, UnsafeMutableRawPointer) -> UnsafeMutableRawPointer?
    let uninstallBridge: @Sendable (OpaquePointer, UnsafeMutableRawPointer?) -> Void

    init(
      instancePointer: OpaquePointer,
      installBridge: @escaping @Sendable (OpaquePointer, UnsafeMutableRawPointer) -> UnsafeMutableRawPointer?,
      uninstallBridge: @escaping @Sendable (OpaquePointer, UnsafeMutableRawPointer?) -> Void
    ) {
      self.instancePointer = instancePointer
      self.installBridge = installBridge
      self.uninstallBridge = uninstallBridge
    }
  }

  private let installation: Installation
  private let broadcaster: Broadcaster<LogEntry>
  var instancePointer: OpaquePointer {
    installation.instancePointer
  }

  init(
    instancePointer: OpaquePointer,
    installBridge: @escaping @Sendable (OpaquePointer, UnsafeMutableRawPointer) -> UnsafeMutableRawPointer? = { instance, data in
      swiftvlc_log_set(instance, logCallback, data)
    },
    uninstallBridge: @escaping @Sendable (OpaquePointer, UnsafeMutableRawPointer?) -> Void = { instance, bridge in
      swiftvlc_log_unset(instance, bridge)
    }
  ) {
    let installation = Installation(
      instancePointer: instancePointer,
      installBridge: installBridge,
      uninstallBridge: uninstallBridge
    )
    self.installation = installation

    // The install closure needs to retain the broadcaster as the
    // userData pointer it passes to libVLC. We can't capture
    // `self.broadcaster` here because it isn't initialized yet, and
    // capturing a `var` local by value only sees its initial nil. The
    // workaround is a tiny `Box` reference that the closure captures
    // by reference; we populate it after the broadcaster is built.
    let broadcasterBox = BroadcasterBox()
    broadcaster = Broadcaster<LogEntry>(
      defaultBufferSize: 128,
      onFirstSubscriber: { [installation, broadcasterBox] in
        guard let broadcaster = broadcasterBox.value else { return }
        let selfBox = Unmanaged.passRetained(broadcaster).toOpaque()
        nonisolated(unsafe) let pointer = installation.instancePointer
        if let bridgeContext = installation.installBridge(pointer, selfBox) {
          installation.state.withLock { state in
            state.selfBox = selfBox
            state.bridgeContext = bridgeContext
          }
        } else {
          // install() failed; drop the retain we took.
          Unmanaged<Broadcaster<LogEntry>>.fromOpaque(selfBox).release()
        }
      },
      onLastUnsubscribed: { [installation] in
        let toRelease = installation.state.withLock { state -> (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) in
          let pair = (state.selfBox, state.bridgeContext)
          state.selfBox = nil
          state.bridgeContext = nil
          return pair
        }
        nonisolated(unsafe) let pointer = installation.instancePointer
        if let bridgeContext = toRelease.1 {
          installation.uninstallBridge(pointer, bridgeContext)
        }
        if let selfBox = toRelease.0 {
          Unmanaged<Broadcaster<LogEntry>>.fromOpaque(selfBox).release()
        }
      }
    )
    broadcasterBox.value = broadcaster
  }

  func subscribe(minimumLevel: LogLevel) -> AsyncStream<LogEntry> {
    broadcaster.subscribe { entry in
      entry.level >= minimumLevel
    }
  }

  /// Terminates all active subscribers and uninstalls the libVLC log
  /// callback. Called from `VLCInstance.deinit`.
  func invalidate() {
    broadcaster.terminateAndWaitForLifecycleCallbacks()
  }

  /// Called by the C callback (outside our lock) with the LogEntry.
  fileprivate func broadcast(_ entry: LogEntry) {
    broadcaster.broadcast(entry)
  }

  /// Returns `true` if some subscriber would receive an entry at this
  /// level. Used by the C callback to short-circuit String allocation
  /// when no one is listening.
  func hasSubscriber(atOrBelow level: LogLevel) -> Bool {
    // Construct a minimal probe entry. Empty string and nil module
    // avoid the upstream String allocation we're trying to skip.
    let probe = LogEntry(level: level, message: "", module: nil)
    return broadcaster.hasSubscriber(matching: probe)
  }
}

/// Captures-by-reference helper for resolving the `Broadcaster` retain
/// cycle in `LogBroadcaster.init`: the lifecycle closures must retain
/// the broadcaster as the libVLC userData pointer, but the broadcaster
/// doesn't exist when the closures are constructed. The box is captured
/// by the closures; `LogBroadcaster.init` populates it after the
/// broadcaster is built.
private final class BroadcasterBox: @unchecked Sendable {
  var value: Broadcaster<LogEntry>?
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

  let broadcaster = Unmanaged<Broadcaster<LogEntry>>.fromOpaque(data).takeUnretainedValue()

  guard let logLevel = LogLevel(rawValue: level) else { return }
  // Probe with an empty entry to skip String allocation when no
  // subscriber is interested in this level.
  let probe = LogEntry(level: logLevel, message: "", module: nil)
  guard broadcaster.hasSubscriber(matching: probe) else { return }

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
