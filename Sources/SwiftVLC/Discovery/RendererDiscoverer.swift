import CLibVLC
import Foundation

/// Discovers available renderers (Chromecast, AirPlay, etc.) on the local network.
///
/// ```swift
/// let services = RendererDiscoverer.availableServices()
/// guard let service = services.first else { return }
///
/// let discoverer = try RendererDiscoverer(name: service.name)
/// try discoverer.start()
///
/// for await event in discoverer.events {
///     switch event {
///     case let .itemAdded(renderer):
///         player.setRenderer(renderer)
///     case let .itemDeleted(renderer):
///         print("Lost: \(renderer.name)")
///     }
/// }
/// ```
public final class RendererDiscoverer: @unchecked Sendable {
    nonisolated(unsafe) let pointer: OpaquePointer // libvlc_renderer_discoverer_t*
    private let continuation: AsyncStream<RendererEvent>.Continuation
    private nonisolated(unsafe) let opaque: UnsafeMutableRawPointer

    /// Stream of renderer discovery events.
    public let events: AsyncStream<RendererEvent>

    /// Creates a renderer discoverer by service name.
    ///
    /// Use ``availableServices(instance:)`` to get valid service names.
    /// - Parameters:
    ///   - name: The discoverer service name.
    ///   - instance: The VLC instance.
    /// - Throws: `VLCError.instanceCreationFailed` if the discoverer cannot be created.
    public init(name: String, instance: VLCInstance = .shared) throws(VLCError) {
        guard let p = libvlc_renderer_discoverer_new(instance.pointer, name) else {
            throw .instanceCreationFailed
        }
        pointer = p

        let (stream, cont) = AsyncStream<RendererEvent>.makeStream(bufferingPolicy: .bufferingNewest(16))
        events = stream
        continuation = cont

        let box = Unmanaged.passRetained(RendererContinuationBox(continuation: cont)).toOpaque()
        opaque = box

        let em = libvlc_renderer_discoverer_event_manager(p)!
        libvlc_event_attach(em, Int32(libvlc_RendererDiscovererItemAdded.rawValue), rendererCallback, box)
        libvlc_event_attach(em, Int32(libvlc_RendererDiscovererItemDeleted.rawValue), rendererCallback, box)
    }

    deinit {
        let em = libvlc_renderer_discoverer_event_manager(pointer)!
        libvlc_event_detach(em, Int32(libvlc_RendererDiscovererItemAdded.rawValue), rendererCallback, opaque)
        libvlc_event_detach(em, Int32(libvlc_RendererDiscovererItemDeleted.rawValue), rendererCallback, opaque)
        Unmanaged<RendererContinuationBox>.fromOpaque(opaque).release()
        continuation.finish()
        libvlc_renderer_discoverer_release(pointer)
    }

    /// Starts renderer discovery.
    /// - Throws: `VLCError.instanceCreationFailed` if discovery cannot start.
    public func start() throws(VLCError) {
        if libvlc_renderer_discoverer_start(pointer) != 0 {
            throw .instanceCreationFailed
        }
    }

    /// Stops renderer discovery.
    public func stop() {
        libvlc_renderer_discoverer_stop(pointer)
    }
}

// MARK: - Renderer Item

/// A discovered renderer (e.g. Chromecast).
///
/// Holds a reference to the underlying `libvlc_renderer_item_t`.
/// Pass to ``Player/setRenderer(_:)`` to start casting.
public final class RendererItem: Sendable {
    nonisolated(unsafe) let pointer: OpaquePointer // libvlc_renderer_item_t*

    init(retaining ptr: OpaquePointer) {
        _ = libvlc_renderer_item_hold(ptr)
        pointer = ptr
    }

    deinit {
        libvlc_renderer_item_release(pointer)
    }

    /// Human-readable name of the renderer.
    public var name: String {
        String(cString: libvlc_renderer_item_name(pointer))
    }

    /// Type of the renderer (e.g. "chromecast").
    public var type: String {
        String(cString: libvlc_renderer_item_type(pointer))
    }

    /// URI of the renderer's icon, if available.
    public var iconURI: String? {
        guard let cstr = libvlc_renderer_item_icon_uri(pointer) else { return nil }
        return String(cString: cstr)
    }

    /// Whether the renderer supports audio.
    public var canAudio: Bool {
        libvlc_renderer_item_flags(pointer) & 0x0001 != 0
    }

    /// Whether the renderer supports video.
    public var canVideo: Bool {
        libvlc_renderer_item_flags(pointer) & 0x0002 != 0
    }
}

// MARK: - Renderer Events

/// Events emitted during renderer discovery.
public enum RendererEvent: Sendable {
    /// A new renderer was discovered.
    case itemAdded(RendererItem)
    /// A previously discovered renderer was removed.
    case itemDeleted(RendererItem)
}

// MARK: - Service Listing

/// Description of an available renderer discovery service.
public struct RendererService: Sendable, Hashable {
    /// Internal service name (used to create a ``RendererDiscoverer``).
    public let name: String
    /// Human-readable description.
    public let longName: String
}

public extension RendererDiscoverer {
    /// Lists available renderer discovery services.
    ///
    /// - Parameter instance: The VLC instance.
    /// - Returns: Available renderer discovery service descriptions.
    static func availableServices(
        instance: VLCInstance = .shared
    ) -> [RendererService] {
        var ppp: UnsafeMutablePointer<UnsafeMutablePointer<libvlc_rd_description_t>?>?
        let count = libvlc_renderer_discoverer_list_get(instance.pointer, &ppp)
        guard count > 0, let ppp else { return [] }
        defer { libvlc_renderer_discoverer_list_release(ppp, count) }

        var results: [RendererService] = []
        for i in 0 ..< Int(count) {
            guard let desc = ppp[i]?.pointee else { continue }
            results.append(RendererService(
                name: String(cString: desc.psz_name),
                longName: String(cString: desc.psz_longname)
            ))
        }
        return results
    }
}

// MARK: - Internals

private final class RendererContinuationBox: @unchecked Sendable {
    let continuation: AsyncStream<RendererEvent>.Continuation
    init(continuation: AsyncStream<RendererEvent>.Continuation) {
        self.continuation = continuation
    }
}

private func rendererCallback(
    event: UnsafePointer<libvlc_event_t>?,
    opaque: UnsafeMutableRawPointer?
) {
    guard let event, let opaque else { return }
    let box = Unmanaged<RendererContinuationBox>.fromOpaque(opaque).takeUnretainedValue()
    let type = libvlc_event_e(rawValue: UInt32(event.pointee.type))

    switch type {
    case libvlc_RendererDiscovererItemAdded:
        guard let item = event.pointee.u.renderer_discoverer_item_added.item else { return }
        let renderer = RendererItem(retaining: item)
        box.continuation.yield(.itemAdded(renderer))

    case libvlc_RendererDiscovererItemDeleted:
        guard let item = event.pointee.u.renderer_discoverer_item_deleted.item else { return }
        let renderer = RendererItem(retaining: item)
        box.continuation.yield(.itemDeleted(renderer))

    default:
        break
    }
}
