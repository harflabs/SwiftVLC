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
  ///
  /// Intentionally excludes `--no-stats`: disabling stats globally would
  /// make ``Media/statistics()`` return an all-zero struct for every
  /// caller, which is almost never what an app wants. Pass a custom
  /// argument list to ``init(arguments:)`` if you need that mode
  /// (embedded contexts with tight memory budgets, CLI tools).
  public static let defaultArguments: [String] = [
    "--no-video-title-show",
    "--no-snapshot-preview"
  ]

  nonisolated(unsafe) let pointer: OpaquePointer // libvlc_instance_t*

  /// Multiplexes the single libVLC log callback to any number of Swift
  /// `logStream` consumers. Lazily installs/uninstalls the underlying
  /// libVLC callback as consumers come and go.
  let logBroadcaster: LogBroadcaster

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
  ///   Common arguments include `"--no-video-title-show"`,
  ///   `"--no-snapshot-preview"`, `"--no-stats"`.
  /// - Throws: `VLCError.instanceCreationFailed` if libVLC cannot be initialized.
  public init(arguments: [String] = VLCInstance.defaultArguments) throws(VLCError) {
    // Convert Swift strings to C strings for libvlc_new.
    // strdup allocates; freed in defer after libvlc_new copies them.
    let cArgs = arguments.map { strdup($0) }
    defer { cArgs.forEach { Darwin.free($0) } }

    let instance = cArgs.withUnsafeBufferPointer { buf -> OpaquePointer? in
      // Cast through raw pointer to satisfy libvlc_new's parameter type
      var argv = buf.map { UnsafePointer($0) }
      return libvlc_new(Int32(argv.count), &argv)
    }

    guard let instance else {
      throw .instanceCreationFailed
    }

    pointer = instance
    logBroadcaster = LogBroadcaster(instancePointer: instance)
    libvlc_set_user_agent(instance, "SwiftVLC", "SwiftVLC/1.0")
  }

  /// Creates the default shared instance (fatalError on failure).
  private convenience init() {
    try! self.init(arguments: VLCInstance.defaultArguments)
  }

  deinit {
    // Terminate any active log streams before releasing the instance;
    // otherwise their continuations would hang forever and the C callback
    // could fire after the instance is freed.
    logBroadcaster.invalidate()
    libvlc_release(pointer)
  }
}
