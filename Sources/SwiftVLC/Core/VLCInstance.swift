import CLibVLC
import Darwin

/// The entry point for all libVLC operations.
///
/// A single shared instance is sufficient for most applications:
/// ```swift
/// let version = VLCInstance.shared.version
/// ```
///
/// Create a custom instance with specific arguments if needed:
/// ```swift
/// let instance = try VLCInstance(arguments: ["--verbose=2"])
/// ```
public final class VLCInstance: Sendable {
  /// The default shared instance, created with ``defaultArguments``.
  ///
  /// Triggers a fatal error if libVLC cannot be initialized (e.g. missing plugins).
  public static let shared = VLCInstance()

  /// Default libVLC arguments used by ``shared``.
  public static let defaultArguments: [String] = [
    "--no-video-title-show",
    "--no-stats",
    "--no-snapshot-preview"
  ]

  nonisolated(unsafe) let pointer: OpaquePointer // libvlc_instance_t*

  /// The libVLC version string (e.g. "4.0.0").
  public var version: String {
    String(cString: libvlc_get_version())
  }

  /// The libVLC ABI version number.
  public var abiVersion: Int {
    Int(libvlc_abi_version())
  }

  /// The compiler used to build libVLC.
  public var compiler: String {
    String(cString: libvlc_get_compiler())
  }

  /// Creates a new libVLC instance with the given arguments.
  ///
  /// - Parameter arguments: Command-line style arguments for libVLC configuration.
  ///   Common arguments include `"--no-video-title-show"`, `"--no-stats"`,
  ///   `"--no-snapshot-preview"`.
  /// - Throws: `VLCError.instanceCreationFailed` if libVLC cannot be initialized.
  public init(arguments: [String] = VLCInstance.defaultArguments) throws(VLCError) {
    // Convert Swift strings to C strings for libvlc_new
    let cStrings = arguments.map { strdup($0) }
    defer { cStrings.forEach { Darwin.free($0) } }

    var argv: [UnsafePointer<CChar>?] = cStrings.map { UnsafePointer($0) }

    guard let instance = libvlc_new(Int32(argv.count), &argv) else {
      throw .instanceCreationFailed
    }

    pointer = instance
    libvlc_set_user_agent(instance, "SwiftVLC", "SwiftVLC/1.0")
  }

  /// Creates the default shared instance (fatalError on failure).
  private convenience init() {
    try! self.init(arguments: VLCInstance.defaultArguments)
  }

  deinit {
    libvlc_release(pointer)
  }
}
