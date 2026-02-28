import CLibVLC

/// A single log message from libVLC.
public struct LogEntry: Sendable {
    public let level: LogLevel
    public let message: String
    public let module: String?
}

/// libVLC log severity levels.
public enum LogLevel: Int32, Sendable, Comparable, CustomStringConvertible {
    case debug = 0
    case notice = 2
    case warning = 3
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

/// Creates an `AsyncStream` of libVLC log messages.
///
/// ```swift
/// for await entry in logStream(minimumLevel: .warning) {
///     print("[\(entry.level)] \(entry.message)")
/// }
/// ```
///
/// - Parameters:
///   - instance: The VLC instance to capture logs from.
///   - minimumLevel: Only yield entries at or above this level.
/// - Returns: An `AsyncStream` of `LogEntry` values.
public func logStream(
    instance: VLCInstance = .shared,
    minimumLevel: LogLevel = .warning
) -> AsyncStream<LogEntry> {
    let (stream, continuation) = AsyncStream<LogEntry>.makeStream(
        bufferingPolicy: .bufferingNewest(128)
    )

    let box = Unmanaged.passRetained(
        LogContext(continuation: continuation, minimumLevel: minimumLevel)
    ).toOpaque()

    // Use our C shim which formats the va_list message before calling back
    let bridgeContext = swiftvlc_log_set(instance.pointer, logCallback, box)

    // Capture pointer values as Int for Sendable compliance
    // (OpaquePointer and UnsafeMutableRawPointer are not Sendable)
    let boxBits = Int(bitPattern: box)
    let bridgeBits = bridgeContext.map { Int(bitPattern: $0) }
    let instanceBits = Int(bitPattern: instance.pointer)

    continuation.onTermination = { @Sendable _ in
        let rawBox = UnsafeMutableRawPointer(bitPattern: boxBits)!
        let rawBridge = bridgeBits.map { UnsafeMutableRawPointer(bitPattern: $0) }
        let rawInstance = OpaquePointer(bitPattern: instanceBits)!
        swiftvlc_log_unset(rawInstance, rawBridge ?? nil)
        Unmanaged<LogContext>.fromOpaque(rawBox).release()
    }

    return stream
}

// MARK: - Internal

private final class LogContext: Sendable {
    let continuation: AsyncStream<LogEntry>.Continuation
    let minimumLevel: LogLevel

    init(continuation: AsyncStream<LogEntry>.Continuation, minimumLevel: LogLevel) {
        self.continuation = continuation
        self.minimumLevel = minimumLevel
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

    let box = Unmanaged<LogContext>.fromOpaque(data).takeUnretainedValue()

    guard let logLevel = LogLevel(rawValue: level),
          logLevel >= box.minimumLevel else { return }

    let entry = LogEntry(
        level: logLevel,
        message: String(cString: message),
        module: module.map { String(cString: $0) }
    )

    box.continuation.yield(entry)
}
