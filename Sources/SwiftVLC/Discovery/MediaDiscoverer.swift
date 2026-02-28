import CLibVLC
import Foundation

/// Discovers media sources on the local network, devices, or local directories.
///
/// ```swift
/// let services = MediaDiscoverer.availableServices(category: .lan)
/// for service in services {
///     let discoverer = try MediaDiscoverer(name: service.name)
///     try discoverer.start()
///     let mediaList = discoverer.mediaList
///     // Monitor mediaList for discovered items
/// }
/// ```
public final class MediaDiscoverer: @unchecked Sendable {
    nonisolated(unsafe) let pointer: OpaquePointer // libvlc_media_discoverer_t*

    /// Creates a media discoverer by service name.
    ///
    /// Use ``availableServices(category:instance:)`` to get valid service names.
    /// - Parameters:
    ///   - name: The discoverer service name (e.g. "upnp", "smb").
    ///   - instance: The VLC instance.
    /// - Throws: `VLCError.instanceCreationFailed` if the discoverer cannot be created.
    public init(name: String, instance: VLCInstance = .shared) throws(VLCError) {
        guard let p = libvlc_media_discoverer_new(instance.pointer, name) else {
            throw .instanceCreationFailed
        }
        pointer = p
    }

    deinit {
        libvlc_media_discoverer_release(pointer)
    }

    /// Starts discovery.
    /// - Throws: `VLCError.instanceCreationFailed` if discovery cannot start.
    public func start() throws(VLCError) {
        if libvlc_media_discoverer_start(pointer) != 0 {
            throw .instanceCreationFailed
        }
    }

    /// Stops discovery.
    public func stop() {
        libvlc_media_discoverer_stop(pointer)
    }

    /// Whether discovery is currently running.
    public var isRunning: Bool {
        libvlc_media_discoverer_is_running(pointer)
    }

    /// The media list containing discovered media items.
    ///
    /// Discovered items are added/removed from this list dynamically.
    public var mediaList: MediaList? {
        guard let list = libvlc_media_discoverer_media_list(pointer) else { return nil }
        return MediaList(retaining: list)
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

public extension MediaDiscoverer {
    /// Lists available discovery services for a given category.
    ///
    /// - Parameters:
    ///   - category: The category of services to list.
    ///   - instance: The VLC instance.
    /// - Returns: Available discovery service descriptions.
    static func availableServices(
        category: DiscoveryCategory,
        instance: VLCInstance = .shared
    ) -> [DiscoveryService] {
        var ppp: UnsafeMutablePointer<UnsafeMutablePointer<libvlc_media_discoverer_description_t>?>?
        let count = libvlc_media_discoverer_list_get(instance.pointer, category.cValue, &ppp)
        guard count > 0, let ppp else { return [] }
        defer { libvlc_media_discoverer_list_release(ppp, count) }

        var results: [DiscoveryService] = []
        for i in 0 ..< Int(count) {
            guard let desc = ppp[i]?.pointee else { continue }
            results.append(DiscoveryService(
                name: String(cString: desc.psz_name),
                longName: String(cString: desc.psz_longname),
                category: DiscoveryCategory(from: desc.i_cat)
            ))
        }
        return results
    }
}
