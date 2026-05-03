import CLibVLC
import Darwin
import Foundation
import Synchronization

/// The entry point for all libVLC operations.
///
/// A single shared instance is sufficient for most applications:
/// ```swift
/// let version = VLCInstance.shared.version
/// ```
///
/// Create a custom instance with specific arguments if needed:
/// ```swift
/// let instance = try VLCInstance(arguments: VLCInstance.defaultArguments + ["--verbose=2"])
/// ```
public final class VLCInstance: Sendable {
  /// The default shared instance, created with ``defaultArguments``.
  ///
  /// Triggers a fatal error if libVLC cannot be initialized (e.g. missing plugins).
  public static let shared = VLCInstance()

  /// Starts initializing ``shared`` on a background task.
  ///
  /// The first libVLC instance performs one-time plugin and decoder setup that
  /// can be expensive on iOS. Calling this from application launch lets that
  /// work happen before the first player view is pushed, instead of blocking the
  /// main actor when `Player()` first touches ``shared``.
  ///
  /// Keep the returned task if you want to await readiness before presenting
  /// playback UI; otherwise it is safe to fire and forget.
  @discardableResult
  public static func prewarmShared(priority: TaskPriority = .utility) -> Task<VLCInstance, Never> {
    Task.detached(priority: priority) {
      VLCInstance.shared
    }
  }

  /// Initializes and returns ``shared`` from a background task.
  ///
  /// Use this when an app has an explicit loading phase and wants to guarantee
  /// the shared libVLC instance is ready before constructing a default
  /// ``Player``.
  public static func prepareShared(priority: TaskPriority = .utility) async -> VLCInstance {
    await prewarmShared(priority: priority).value
  }

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
  let arguments: [String]

  var usesPiPSafeDarwinDisplay: Bool {
    #if os(macOS)
    guard !Self.containsOption(named: "no-video", in: arguments) else { return false }
    let forcesLegacyDisplay = Self.containsOption(
      named: "force-darwin-legacy-display",
      in: arguments
    )
    guard let vout = Self.lastOptionValue(named: "vout", in: arguments) else {
      return !forcesLegacyDisplay
    }
    return ["macosx", "vout_macosx"].contains(vout)
    #else
    true
    #endif
  }

  private static func containsOption(named name: String, in arguments: [String]) -> Bool {
    let longName = "--\(name)"
    let assignmentPrefix = "\(longName)="
    return arguments.contains {
      $0 == longName || $0.hasPrefix(assignmentPrefix)
    }
  }

  private static func lastOptionValue(named name: String, in arguments: [String]) -> String? {
    var value: String?
    let longName = "--\(name)"
    let assignmentPrefix = "\(longName)="

    for index in arguments.indices {
      let argument = arguments[index]
      if argument.hasPrefix(assignmentPrefix) {
        value = String(argument.dropFirst(assignmentPrefix.count))
      } else if argument == longName, arguments.indices.contains(index + 1) {
        value = arguments[index + 1]
      }
    }

    return value
  }

  /// Multiplexes the single libVLC log callback to any number of Swift
  /// `logStream` consumers. Lazily installs/uninstalls the underlying
  /// libVLC callback as consumers come and go.
  let logBroadcaster: LogBroadcaster

  /// Per-instance dialog-handler claim. Scoping the registration to
  /// the instance avoids cross-test leakage and ensures a freed
  /// VLCInstance never leaves stale entries behind.
  private let dialogRegistration = Mutex(DialogRegistrationState())

  /// `@unchecked` because the box pointer is `UnsafeMutableRawPointer`.
  /// All access goes through the enclosing `Mutex.withLock`.
  fileprivate struct DialogRegistrationState: @unchecked Sendable {
    var token: UUID?
    var box: UnsafeMutableRawPointer?
  }

  /// Attempts to claim this instance's single dialog-callback slot.
  ///
  /// On success, returns the token the caller stores and later passes
  /// to ``releaseDialogRegistration(token:)``. The caller is then
  /// responsible for installing the libVLC dialog callbacks and
  /// keeping the box pointer alive until release.
  ///
  /// Returns `nil` when another `DialogHandler` already holds the
  /// slot — the caller must release the box themselves and finish
  /// their stream.
  func claimDialogRegistration(box: UnsafeMutableRawPointer) -> UUID? {
    dialogRegistration.withLock { state -> UUID? in
      guard state.token == nil else { return nil }
      let token = UUID()
      state.token = token
      state.box = box
      return token
    }
  }

  /// Releases the dialog-callback slot. Returns the box pointer the
  /// caller passed to `claimDialogRegistration` so it can be balanced
  /// with `Unmanaged.release()`. Returns `nil` if the token doesn't
  /// match the current registration (defensive: e.g. teardown order
  /// where another handler already reclaimed the slot).
  func releaseDialogRegistration(token: UUID) -> UnsafeMutableRawPointer? {
    dialogRegistration.withLock { state -> UnsafeMutableRawPointer? in
      guard state.token == token else { return nil }
      let box = state.box
      state.token = nil
      state.box = nil
      return box
    }
  }

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
    self.arguments = arguments

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

    // Defensive: if a DialogHandler outlives normal cleanup or leaks,
    // strip the libVLC dialog callbacks before release so the C side
    // doesn't fire into a freed box. The box's Unmanaged retain leaks
    // in that case (we can't safely release without knowing the type),
    // but the alternative is a use-after-free.
    let leakedBox = dialogRegistration.withLock { state -> UnsafeMutableRawPointer? in
      let box = state.box
      state.token = nil
      state.box = nil
      return box
    }
    if leakedBox != nil {
      libvlc_dialog_set_callbacks(pointer, nil, nil)
      libvlc_dialog_set_error_callback(pointer, nil, nil)
    }

    libvlc_release(pointer)
  }
}
