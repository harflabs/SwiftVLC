import CLibVLC
import Dispatch

/// Discovers available renderers (Chromecast, AirPlay, etc.) on the local network.
///
/// Start the discoverer, then observe ``events`` to be notified as renderers
/// come and go. Cast to a discovered renderer by passing its
/// ``RendererItem`` to ``Player/setRenderer(_:)``.
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
///         try? player.setRenderer(renderer)
///     case let .itemDeleted(renderer):
///         print("Lost: \(renderer.name)")
///     }
/// }
/// ```
public final class RendererDiscoverer: Sendable {
  nonisolated(unsafe) let pointer: OpaquePointer // libvlc_renderer_discoverer_t*
  private let instance: VLCInstance
  private let broadcaster: Broadcaster<RendererEvent>
  private nonisolated(unsafe) let opaque: UnsafeMutableRawPointer

  /// Stream of renderer discovery events. A new independent stream is
  /// returned per access; subscribers don't compete for events.
  public var events: AsyncStream<RendererEvent> {
    broadcaster.subscribe()
  }

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
    // Retain the instance so it outlives the discoverer. See the
    // matching note in `MediaDiscoverer`.
    self.instance = instance

    let broadcaster = Broadcaster<RendererEvent>(defaultBufferSize: 16)
    self.broadcaster = broadcaster
    let box = Unmanaged.passRetained(broadcaster).toOpaque()
    opaque = box

    let em = libvlc_renderer_discoverer_event_manager(p)!
    libvlc_event_attach(em, Int32(libvlc_RendererDiscovererItemAdded.rawValue), rendererCallback, box)
    libvlc_event_attach(em, Int32(libvlc_RendererDiscovererItemDeleted.rawValue), rendererCallback, box)
  }

  deinit {
    // libvlc_event_detach blocks on in-progress callbacks, and
    // libvlc_renderer_discoverer_release waits for the discovery
    // thread to stop. Offload off the calling thread. Pointers are
    // trivially transferable via `nonisolated(unsafe)` locals, and the
    // broadcaster is Sendable so it can be captured directly.
    nonisolated(unsafe) let discoverer = pointer
    nonisolated(unsafe) let box = opaque
    let broadcaster = self.broadcaster
    DispatchQueue.global(qos: .utility).async {
      let em = libvlc_renderer_discoverer_event_manager(discoverer)!
      libvlc_event_detach(em, Int32(libvlc_RendererDiscovererItemAdded.rawValue), rendererCallback, box)
      libvlc_event_detach(em, Int32(libvlc_RendererDiscovererItemDeleted.rawValue), rendererCallback, box)
      broadcaster.terminate()
      Unmanaged<Broadcaster<RendererEvent>>.fromOpaque(box).release()
      libvlc_renderer_discoverer_release(discoverer)
    }
  }

  /// Starts renderer discovery.
  /// - Throws: `VLCError.operationFailed` if discovery cannot start.
  public func start() throws(VLCError) {
    if libvlc_renderer_discoverer_start(pointer) != 0 {
      throw .operationFailed("Start renderer discovery")
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
///
/// Identity is ``type``-then-``name``, so two `RendererItem`s for the
/// same physical device compare equal even when they wrap distinct C
/// pointers from independent discovery runs.
public final class RendererItem: Sendable, Identifiable, Hashable {
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

  /// Stable identifier composed of ``type`` and ``name``. Suitable as
  /// the `id:` argument to SwiftUI's `ForEach` / `List`.
  public var id: String {
    "\(type)|\(name)"
  }

  /// URI of the renderer's icon, if available.
  public var iconURI: String? {
    guard let cstr = libvlc_renderer_item_icon_uri(pointer) else { return nil }
    return String(cString: cstr)
  }

  private static let audioFlag: Int32 = 0x0001 // LIBVLC_RENDERER_CAN_AUDIO
  private static let videoFlag: Int32 = 0x0002 // LIBVLC_RENDERER_CAN_VIDEO

  /// Whether the renderer supports audio.
  public var canAudio: Bool {
    libvlc_renderer_item_flags(pointer) & Self.audioFlag != 0
  }

  /// Whether the renderer supports video.
  public var canVideo: Bool {
    libvlc_renderer_item_flags(pointer) & Self.videoFlag != 0
  }

  public static func == (lhs: RendererItem, rhs: RendererItem) -> Bool {
    lhs.id == rhs.id
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(id)
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

extension RendererEvent {
  /// `RendererItem` if this event is `.itemAdded`, otherwise `nil`.
  public var itemAdded: RendererItem? {
    if case .itemAdded(let value) = self { value } else { nil }
  }

  /// `RendererItem` if this event is `.itemDeleted`, otherwise `nil`.
  public var itemDeleted: RendererItem? {
    if case .itemDeleted(let value) = self { value } else { nil }
  }
}

// MARK: - Service Listing

/// Description of an available renderer discovery service.
public struct RendererService: Sendable, Hashable {
  /// Internal service name (used to create a ``RendererDiscoverer``).
  public let name: String
  /// Human-readable description.
  public let longName: String
}

extension RendererDiscoverer {
  /// Lists available renderer discovery services.
  ///
  /// - Parameter instance: The VLC instance.
  /// - Returns: Available renderer discovery service descriptions.
  public static func availableServices(
    instance: VLCInstance = .shared
  ) -> [RendererService] {
    var ppp: UnsafeMutablePointer<UnsafeMutablePointer<libvlc_rd_description_t>?>?
    let count = libvlc_renderer_discoverer_list_get(instance.pointer, &ppp)
    guard count > 0, let ppp else { return [] }
    defer { libvlc_renderer_discoverer_list_release(ppp, count) }

    return (0..<Int(count)).compactMap { i -> RendererService? in
      guard let desc = ppp[i]?.pointee else { return nil }
      return RendererService(
        name: String(cString: desc.psz_name),
        longName: String(cString: desc.psz_longname)
      )
    }
  }
}

// MARK: - Internals

private func rendererCallback(
  event: UnsafePointer<libvlc_event_t>?,
  opaque: UnsafeMutableRawPointer?
) {
  guard let event, let opaque else { return }
  let broadcaster = Unmanaged<Broadcaster<RendererEvent>>.fromOpaque(opaque).takeUnretainedValue()
  let type = libvlc_event_e(rawValue: UInt32(event.pointee.type))

  switch type {
  case libvlc_RendererDiscovererItemAdded:
    guard let item = event.pointee.u.renderer_discoverer_item_added.item else { return }
    let renderer = RendererItem(retaining: item)
    broadcaster.broadcast(.itemAdded(renderer))

  case libvlc_RendererDiscovererItemDeleted:
    guard let item = event.pointee.u.renderer_discoverer_item_deleted.item else { return }
    let renderer = RendererItem(retaining: item)
    broadcaster.broadcast(.itemDeleted(renderer))

  default:
    break
  }
}
