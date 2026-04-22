import Foundation

/// One record from the library's log stream, as serialized by the showcase
/// app under `-UITestLogPath`. Mirrors the `LogRecord` written by
/// `UITestSupport.startLogMirrorIfRequested()`.
struct UITestLogEntry: Codable, Hashable {
  let ts: Date
  let level: String
  let module: String?
  let message: String
}
