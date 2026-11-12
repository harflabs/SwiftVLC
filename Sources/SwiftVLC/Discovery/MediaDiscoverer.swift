import CLibVLC

/// Discovers media sources on the local network, devices, or local directories.
///
/// Use ``availableServices(category:instance:)`` to enumerate the
/// discoverers available on the host, construct one by `name`, then
/// ``start()`` it. Discovered items populate ``mediaList`` as they
/// are found; inspect the list while the discoverer runs.
///
/// ```swift
/// let services = MediaDiscoverer.availableServices(category: .lan)
/// guard let service = services.first else { return }
///
/// let discoverer = try MediaDiscoverer(name: service.name)
/// try discoverer.start()
///
/// // Let discovery run briefly, then inspect the list.
/// try? await Task.sleep(for: .seconds(2))
/// if let list = discoverer.mediaList {
///     for i in 0..<list.count {
///         print(list[i]?.mrl ?? "?")
///     }
/// }
/// ```
public final class MediaDiscoverer: Sendable {
  nonisolated(unsafe) let pointer: OpaquePointer // libvlc_media_discoverer_t*
  private let instance: VLCInstance
  /// Where this service's native start, stop, and release must run.
  private let lane: DiscoveryLifecycle.Lane
  /// Accessed only on ``lane``.
  private nonisolated(unsafe) var isStarted = false

  /// Creates a media discoverer by service name.
  ///
  /// Use ``availableServices(category:instance:)`` to get valid service names.
  /// - Parameters:
  ///   - name: The discoverer service name (e.g. "upnp", "smb").
  ///   - instance: The VLC instance.
  /// - Throws: `VLCError.instanceCreationFailed` if the discoverer cannot be created.
  public init(name: String, instance: VLCInstance = .shared) throws(VLCError) {
    let p = DiscoveryLifecycle.sync {
      libvlc_media_discoverer_new(instance.pointer, name)
    }
    guard let p else {
      throw .instanceCreationFailed
    }
    pointer = p
    lane = DiscoveryLifecycle.lane(forServiceNamed: name)
    // Retain the instance so it outlives the discoverer. Otherwise a
    // caller that drops their only `VLCInstance` reference while the
    // discoverer is still alive would free the libVLC instance out
    // from under our C pointer, crashing on the next callback.
    self.instance = instance
  }

  deinit {
    // libvlc_media_discoverer_release waits for the discovery thread
    // to stop. Offload off the calling thread so the last reference
    // drop doesn't stall main when the discoverer is owned by a
    // SwiftUI view.
    nonisolated(unsafe) let discoverer = pointer
    let instance = self.instance
    DiscoveryLifecycle.async(on: lane) {
      libvlc_media_discoverer_release(discoverer)
      _ = instance
    }
  }

  /// Starts discovery.
  /// - Throws: `VLCError.operationFailed` if discovery cannot start, or
  ///   `VLCError.invalidState` if this discoverer is already running.
  public func start() throws(VLCError) {
    enum StartResult {
      case started
      case alreadyStarted
      case failed
    }
    let result = DiscoveryLifecycle.sync(on: lane) { () -> StartResult in
      // libVLC overwrites its module pointer on every start, so a second
      // start would leak the running module and leave it unreachable.
      guard !isStarted else { return .alreadyStarted }
      guard libvlc_media_discoverer_start(pointer) == 0 else { return .failed }
      isStarted = true
      return .started
    }
    switch result {
    case .started:
      break
    case .alreadyStarted:
      throw .invalidState("Media discovery is already running")
    case .failed:
      throw .operationFailed("Start media discovery")
    }
  }

  /// Stops discovery.
  ///
  /// Does nothing when discovery is not running, including before the first
  /// ``start()``, after a ``start()`` that threw, and when called twice.
  public func stop() {
    DiscoveryLifecycle.sync(on: lane) {
      // libvlc_media_discoverer_stop dereferences the discovery module
      // without checking that one exists.
      guard isStarted else { return }
      libvlc_media_discoverer_stop(pointer)
      isStarted = false
    }
  }

  /// Whether discovery is currently running.
  public var isRunning: Bool {
    DiscoveryLifecycle.sync(on: lane) {
      libvlc_media_discoverer_is_running(pointer)
    }
  }

  /// The media list containing discovered media items.
  ///
  /// Discovered items are added/removed from this list dynamically.
  public var mediaList: MediaList? {
    DiscoveryLifecycle.sync(on: lane) {
      Self.adoptMediaList(libvlc_media_discoverer_media_list(pointer))
    }
  }

  static func adoptMediaList(_ pointer: OpaquePointer?) -> MediaList? {
    guard let pointer else { return nil }
    // Pinned VLC c833c4be0 retains this list in lib/media_discoverer.c before
    // returning it. Adopt that +1 reference; retaining again leaks one list
    // on every property access. Recheck this contract when updating VLC.
    return MediaList(owning: pointer)
  }
}

// MARK: - Service Discovery

/// Description of an available media discovery service.
public struct DiscoveryService: Sendable, Hashable {
  /// Internal service name (used to create a ``MediaDiscoverer``).
  public let name: String
  /// Human-readable description.
  public let longName: String
  /// Service category.
  public let category: DiscoveryCategory
}

/// Category of media discovery services.
public enum DiscoveryCategory: Sendable, Hashable {
  /// Physical devices (portable music players, etc.).
  case devices
  /// LAN/WAN services (UPnP, SMB, SAP).
  case lan
  /// Podcast directories.
  case podcasts
  /// Local directories (Video, Music, Pictures).
  case localDirectories

  var cValue: libvlc_media_discoverer_category_t {
    switch self {
    case .devices: libvlc_media_discoverer_devices
    case .lan: libvlc_media_discoverer_lan
    case .podcasts: libvlc_media_discoverer_podcasts
    case .localDirectories: libvlc_media_discoverer_localdirs
    }
  }

  init(from cValue: libvlc_media_discoverer_category_t) {
    switch cValue {
    case libvlc_media_discoverer_devices: self = .devices
    case libvlc_media_discoverer_lan: self = .lan
    case libvlc_media_discoverer_podcasts: self = .podcasts
    case libvlc_media_discoverer_localdirs: self = .localDirectories
    default: self = .devices
    }
  }
}

extension MediaDiscoverer {
  /// Lists available discovery services for a given category.
  ///
  /// - Parameters:
  ///   - category: The category of services to list.
  ///   - instance: The VLC instance.
  /// - Returns: Available discovery service descriptions.
  public static func availableServices(
    category: DiscoveryCategory,
    instance: VLCInstance = .shared
  ) -> [DiscoveryService] {
    DiscoveryLifecycle.sync {
      var ppp: UnsafeMutablePointer<UnsafeMutablePointer<libvlc_media_discoverer_description_t>?>?
      let count = libvlc_media_discoverer_list_get(instance.pointer, category.cValue, &ppp)
      guard count > 0, let ppp else { return [] }
      defer { libvlc_media_discoverer_list_release(ppp, count) }

      return (0..<Int(count)).compactMap { i -> DiscoveryService? in
        guard let desc = ppp[i]?.pointee else { return nil }
        return DiscoveryService(
          name: String(cString: desc.psz_name),
          longName: String(cString: desc.psz_longname),
          category: DiscoveryCategory(from: desc.i_cat)
        )
      }
    }
  }
}
