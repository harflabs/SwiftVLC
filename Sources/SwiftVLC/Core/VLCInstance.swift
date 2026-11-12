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
  /// Use this when an app has an explicit loading phase and wants to ensure
  /// the shared libVLC instance is ready before constructing a default
  /// ``Player``.
  public static func prepareShared(priority: TaskPriority = .utility) async -> VLCInstance {
    await prewarmShared(priority: priority).value
  }

  /// Base libVLC arguments used by ``shared``.
  ///
  /// ``init(arguments:applicationName:httpUserAgent:appleAudioSessionPolicy:)``
  /// appends the canonical audio-session ownership argument when the linked
  /// native extension supports it. It deliberately stays out of this array so
  /// the default `.libraryManaged` instance remains runnable with pre-version-8
  /// archives that do not recognize the option name.
  ///
  /// Intentionally excludes `--no-stats`: disabling stats globally would
  /// make ``Media/statistics()`` return an all-zero struct for every
  /// caller, which is almost never what an app wants. Pass a custom
  /// argument list to
  /// ``init(arguments:applicationName:httpUserAgent:appleAudioSessionPolicy:)``
  /// if you need that mode
  /// (embedded contexts with tight memory budgets, CLI tools).
  ///
  /// `--sout-renderer-show-perf-warning=0` stops libVLC from asking a
  /// "Performance warning" question before it transcodes for a renderer
  /// (a Chromecast or DLNA device that cannot play the video codec, or any
  /// cast with a subtitle track selected). libVLC treats an unanswered or
  /// declined question as a refusal it cannot recover from: the renderer is
  /// never loaded while the player keeps reporting `.playing`. With the
  /// question off, the conversion simply starts. An instance created from a
  /// custom argument list that omits this option gets the question back and
  /// must answer it through ``DialogHandler``; pass
  /// `--sout-renderer-show-perf-warning=1` after these defaults to opt in
  /// deliberately.
  public static let defaultArguments: [String] = [
    "--no-video-title-show",
    "--no-snapshot-preview",
    "--sout-renderer-show-perf-warning=0"
  ]

  nonisolated(unsafe) let pointer: OpaquePointer // libvlc_instance_t*
  let arguments: [String]

  /// The immutable owner of Apple audio-session configuration and activation
  /// for this instance and every ``Player`` created from it.
  public let appleAudioSessionPolicy: AppleAudioSessionPolicy

  static var supportsApplicationManagedAppleAudioSession: Bool {
    swiftvlc_libvlc_pip_extensions_version()
      >= AppleAudioSessionPolicy.requiredNativeExtensionVersion
  }

  var usesPiPSafeDarwinDisplay: Bool {
    #if os(macOS)
    guard !Self.containsOption(named: "no-video", in: arguments) else { return false }
    return usesSampleBufferDisplay
      || ["macosx", "vout_macosx"].contains(Self.lastOptionValue(named: "vout", in: arguments))
    #elseif os(iOS)
    // iOS native PiP only attaches when libVLC selects its Apple
    // sample-buffer video output (`samplebufferdisplay`, the default).
    // `--no-video`, a forced legacy display, or any other forced `--vout`
    // stops the PiP-ready callback from ever firing.
    guard !Self.containsOption(named: "no-video", in: arguments) else { return false }
    let forcesLegacyDisplay = Self.containsOption(
      named: "force-darwin-legacy-display",
      in: arguments
    )
    guard let vout = Self.lastOptionValue(named: "vout", in: arguments) else {
      return !forcesLegacyDisplay
    }
    return vout == "samplebufferdisplay"
    #else
    true
    #endif
  }

  #if os(macOS)
  /// Whether video renders through libVLC's default `samplebufferdisplay`,
  /// whose layer survives its drawable moving between windows. The legacy
  /// OpenGL displays lose their context's surface instead.
  var usesSampleBufferDisplay: Bool {
    guard !Self.containsOption(named: "force-darwin-legacy-display", in: arguments) else {
      return false
    }
    let vout = Self.lastOptionValue(named: "vout", in: arguments)
    return vout == nil || vout == "samplebufferdisplay"
  }
  #endif

  var supportsDynamicDeinterlaceChanges: Bool {
    #if os(macOS)
    guard !Self.containsOption(named: "no-video", in: arguments) else { return true }
    let codecs = Self.optionValues(named: "codec", in: arguments)
    return codecs.contains("avcodec") && !codecs.contains("videotoolbox")
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

  private static func optionValues(named name: String, in arguments: [String]) -> Set<String> {
    guard let value = lastOptionValue(named: name, in: arguments) else { return [] }
    return Set(
      value
        .split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    )
  }

  static func arguments(
    _ arguments: [String],
    applying appleAudioSessionPolicy: AppleAudioSessionPolicy,
    nativeExtensionVersion: UInt32
  )
    throws(VLCError) -> [String] {
    guard !containsAppleAudioSessionManagementOption(in: arguments) else {
      throw .invalidInput(
        "arguments must not contain --\(AppleAudioSessionPolicy.libVLCOptionName); "
          + "use appleAudioSessionPolicy instead"
      )
    }

    let requiredVersion = AppleAudioSessionPolicy.requiredNativeExtensionVersion
    guard nativeExtensionVersion >= requiredVersion else {
      guard appleAudioSessionPolicy == .libraryManaged else {
        throw .operationFailed(
          "Create VLCInstance with application-managed Apple audio session: "
            + "linked libVLC extension version \(nativeExtensionVersion) is older than "
            + "required version \(requiredVersion)"
        )
      }

      // Extension versions before 8 always use library-managed behavior and
      // do not know the option name. Omitting the default-valued option keeps
      // released archives source-compatible without weakening the opt-out.
      return arguments
    }

    return arguments + [
      "--\(AppleAudioSessionPolicy.libVLCOptionName)="
        + appleAudioSessionPolicy.libVLCOptionValue
    ]
  }

  private static func containsAppleAudioSessionManagementOption(
    in arguments: [String]
  ) -> Bool {
    let optionName = AppleAudioSessionPolicy.libVLCOptionName
    let reservedPrefixes = [
      "--\(optionName)",
      "--no-\(optionName)",
      "--no\(optionName)"
    ]

    return arguments.contains { argument in
      reservedPrefixes.contains { prefix in
        argument == prefix || argument.hasPrefix("\(prefix)=")
      }
    }
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

  /// Attempts to claim this instance's single dialog-callback slot and
  /// install the corresponding native callbacks.
  ///
  /// On success, returns the token the caller stores and later passes
  /// to ``releaseDialogRegistration(token:clearCallbacks:)``. The caller
  /// is responsible for keeping the box pointer alive until release.
  ///
  /// Returns `nil` when another `DialogHandler` already holds the
  /// slot — the caller must release the box themselves and finish
  /// their stream.
  func claimDialogRegistration(
    box: UnsafeMutableRawPointer,
    installCallbacks: (OpaquePointer, UnsafeMutableRawPointer) -> Void
  ) -> UUID? {
    dialogRegistration.withLock { state -> UUID? in
      guard state.token == nil else { return nil }
      let token = UUID()
      installCallbacks(pointer, box)
      state.token = token
      state.box = box
      return token
    }
  }

  /// Clears the native callbacks and releases the dialog-callback slot.
  /// Returns the box pointer the caller passed to
  /// `claimDialogRegistration` so it can be balanced with
  /// `Unmanaged.release()`. Returns `nil` if the token doesn't match the
  /// current registration.
  func releaseDialogRegistration(
    token: UUID,
    clearCallbacks: (OpaquePointer) -> Void
  ) -> UnsafeMutableRawPointer? {
    dialogRegistration.withLock { state -> UnsafeMutableRawPointer? in
      guard state.token == token else { return nil }
      let box = state.box
      clearCallbacks(pointer)
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

  /// Creates a library-managed libVLC instance using the pre-1.1 call shape.
  ///
  /// Use
  /// ``init(arguments:applicationName:httpUserAgent:appleAudioSessionPolicy:)``
  /// when the host application owns Apple audio-session policy. Keeping this
  /// overload exact preserves existing calls and initializer references while
  /// routing new ownership through one designated initializer.
  public convenience init(
    arguments: [String] = VLCInstance.defaultArguments,
    applicationName: String? = nil,
    httpUserAgent: String? = nil
  )
    throws(VLCError) {
    try self.init(
      arguments: arguments,
      applicationName: applicationName,
      httpUserAgent: httpUserAgent,
      appleAudioSessionPolicy: .libraryManaged
    )
  }

  /// Creates a new libVLC instance with the given arguments.
  ///
  /// - Parameters:
  ///   - arguments: Command-line style arguments for libVLC configuration.
  ///     Common arguments include `"--no-video-title-show"`,
  ///     `"--no-snapshot-preview"`, `"--no-stats"`.
  ///   - applicationName: Human-readable application name reported to
  ///     libVLC, e.g. `"FooBar player 1.2.3"`. Defaults to `"SwiftVLC"`
  ///     when `nil`.
  ///   - httpUserAgent: The `User-Agent` header libVLC sends on HTTP
  ///     connections, e.g. `"FooBar/1.2.3"`. Defaults to `"SwiftVLC"`
  ///     when `nil`. Set it here rather than via
  ///     ``setUserAgent(name:http:)`` so it is in place before any
  ///     networking starts.
  ///   - appleAudioSessionPolicy: Who owns Apple audio-session configuration
  ///     and activation for this instance.
  /// - Throws: `VLCError.invalidInput` if too many arguments are supplied or
  ///   `arguments` tries to set the reserved audio-session option directly;
  ///   `VLCError.operationFailed` if `.applicationManaged` is requested from
  ///   a bundled libVLC older than extension version 8; or
  ///   `VLCError.instanceCreationFailed` if libVLC cannot be initialized.
  public init(
    arguments: [String] = VLCInstance.defaultArguments,
    applicationName: String? = nil,
    httpUserAgent: String? = nil,
    appleAudioSessionPolicy: AppleAudioSessionPolicy
  )
    throws(VLCError) {
    let nativeExtensionVersion = swiftvlc_libvlc_pip_extensions_version()
    let resolvedArguments = try Self.arguments(
      arguments,
      applying: appleAudioSessionPolicy,
      nativeExtensionVersion: nativeExtensionVersion
    )
    self.arguments = resolvedArguments
    self.appleAudioSessionPolicy = appleAudioSessionPolicy
    let argumentCount = try checkedInt32(
      resolvedArguments.count,
      parameter: "arguments.count"
    )

    // Convert Swift strings to C strings for libvlc_new.
    // strdup allocates; freed in defer after libvlc_new copies them.
    let cArgs = resolvedArguments.map { strdup($0) }
    defer { cArgs.forEach { Darwin.free($0) } }

    let instance = cArgs.withUnsafeBufferPointer { buf -> OpaquePointer? in
      // Cast through raw pointer to satisfy libvlc_new's parameter type
      var argv = buf.map { UnsafePointer($0) }
      return libvlc_new(argumentCount, &argv)
    }

    guard let instance else {
      throw .instanceCreationFailed
    }

    pointer = instance
    logBroadcaster = LogBroadcaster(instancePointer: instance)
    libvlc_set_user_agent(
      instance,
      applicationName ?? "SwiftVLC",
      httpUserAgent ?? "SwiftVLC"
    )
  }

  /// Creates the default shared instance (fatalError on failure).
  private convenience init() {
    try! self.init(arguments: VLCInstance.defaultArguments)
  }

  /// Sets the application identity libVLC reports to peers and servers.
  ///
  /// The setting is instance-global and only affects HTTP connections
  /// opened after the call. Prefer passing `applicationName` /
  /// `httpUserAgent` to
  /// ``init(arguments:applicationName:httpUserAgent:appleAudioSessionPolicy:)``
  /// so the identity is in place before any networking starts.
  ///
  /// - Parameters:
  ///   - name: Human-readable application name, e.g. `"FooBar player 1.2.3"`.
  ///   - http: HTTP `User-Agent` header value, e.g. `"FooBar/1.2.3"`.
  public func setUserAgent(name: String, http: String) {
    libvlc_set_user_agent(pointer, name, http)
  }

  /// Sets meta-information about the application.
  ///
  /// Fire-and-forget: libVLC offers no getter, so the values cannot be
  /// read back. See also ``setUserAgent(name:http:)``.
  ///
  /// - Parameters:
  ///   - id: Java-style application identifier, e.g. `"com.acme.foobar"`.
  ///   - version: Application version numbers, e.g. `"1.2.3"`.
  ///   - icon: Application icon name, e.g. `"foobar"`.
  public func setAppID(_ id: String, version: String, icon: String) {
    libvlc_set_app_id(pointer, id, version, icon)
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
