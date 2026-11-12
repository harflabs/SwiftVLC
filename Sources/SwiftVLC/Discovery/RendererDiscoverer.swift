import CLibVLC

/// Discovers renderer devices exposed by libVLC renderer-discovery plugins.
///
/// Start the discoverer, then observe ``events`` to be notified as renderers
/// come and go. Cast to a discovered renderer by passing its
/// ``RendererItem`` to ``Player/setRenderer(_:)``.
///
/// The bundled libVLC ships two services. `Bonjour_renderer` finds Chromecast
/// devices; `upnp_renderer`, which ``availableServices(instance:)`` lists
/// first, finds UPnP/DLNA renderers and never a Chromecast. Select the one you
/// need by name.
///
/// ```swift
/// let player = Player()
/// try player.play(url: mediaURL)
///
/// let discoverer = try RendererDiscoverer(name: "Bonjour_renderer")
/// let events = discoverer.events
/// try discoverer.start()
///
/// for await event in events {
///     switch event {
///     case let .itemAdded(renderer):
///         do {
///             let outcome = try await player.recastAndWaitForOutcome(to: renderer)
///             guard outcome.isSettled else {
///                 print("Cast did not settle:", outcome)
///                 continue
///             }
///         } catch {
///             print("Cast failed:", error)
///         }
///     case let .itemDeleted(renderer):
///         print("Lost: \(renderer.name)")
///     }
/// }
/// ```
///
/// Casting to a Chromecast additionally requires a ``DialogHandler`` that
/// accepts libVLC's certificate-trust question
/// (``QuestionRequest/isCertificateTrustQuestion``); without one the
/// connection is refused. See <doc:DiscoveryAndCasting>.
public final class RendererDiscoverer: Sendable {
  nonisolated(unsafe) let pointer: OpaquePointer // libvlc_renderer_discoverer_t*
  private let instance: VLCInstance
  private let eventHub: CurrentInventoryEventHub<RendererItem, UInt, RendererEvent>
  private nonisolated(unsafe) let opaque: UnsafeMutableRawPointer
  /// Accessed only on `DiscoveryLifecycle`'s serial queue.
  private nonisolated(unsafe) var isStarted = false

  /// Stream of renderer discovery events. A new independent stream is returned
  /// per access; subscribers don't compete for events. Every new stream begins
  /// with ``RendererEvent/itemAdded(_:)`` for each renderer that is already
  /// present, followed by later additions and removals in native callback order.
  ///
  /// The inventory replay closes the race where libVLC synchronously discovers
  /// a renderer inside ``start()`` before the caller obtains this stream. The
  /// stream remains unbounded because each transition is required to maintain
  /// an exact device picker and discovery is low-rate in practice.
  ///
  /// Discovery is low-rate, so unbounded costs nothing in practice. It matters
  /// when a consumer stalls: building a device picker means touching UI, and a
  /// newest-wins buffer would evict the earliest-found devices — the ones a
  /// user is most likely to be waiting for.
  public var events: AsyncStream<RendererEvent> {
    eventHub.subscribe()
  }

  /// Creates a renderer discoverer by service name.
  ///
  /// Use ``availableServices(instance:)`` to get valid service names.
  /// - Parameters:
  ///   - name: The discoverer service name.
  ///   - instance: The VLC instance.
  /// - Throws: `VLCError.instanceCreationFailed` if the discoverer cannot be created,
  ///   or `VLCError.operationFailed` if its complete native event set cannot
  ///   be registered.
  public init(name: String, instance: VLCInstance = .shared) throws(VLCError) {
    let p = DiscoveryLifecycle.sync {
      libvlc_renderer_discoverer_new(instance.pointer, name)
    }
    guard let p else {
      throw .instanceCreationFailed
    }
    let eventHub = CurrentInventoryEventHub<RendererItem, UInt, RendererEvent>(
      identity: { UInt(bitPattern: UnsafeRawPointer($0.pointer)) },
      addedEvent: RendererEvent.itemAdded,
      removedEvent: RendererEvent.itemDeleted
    )
    let box = Unmanaged.passRetained(eventHub).toOpaque()
    guard
      let em = libvlc_renderer_discoverer_event_manager(p),
      RendererEventAttachment.attachAll(
        attach: { eventType in
          libvlc_event_attach(em, eventType, rendererCallback, box)
        },
        detach: { eventType in
          libvlc_event_detach(em, eventType, rendererCallback, box)
        }
      )
    else {
      eventHub.terminate()
      Unmanaged<CurrentInventoryEventHub<RendererItem, UInt, RendererEvent>>
        .fromOpaque(box).release()
      libvlc_renderer_discoverer_release(p)
      throw .operationFailed("Register renderer discovery events")
    }

    pointer = p
    // Retain the instance so it outlives the discoverer. See the
    // matching note in `MediaDiscoverer`.
    self.instance = instance
    self.eventHub = eventHub
    opaque = box
  }

  deinit {
    // libvlc_event_detach blocks on in-progress callbacks, and
    // libvlc_renderer_discoverer_release waits for the discovery
    // thread to stop. Offload off the calling thread. Pointers are
    // trivially transferable via `nonisolated(unsafe)` locals, and the
    // event hub is Sendable so it can be captured directly.
    nonisolated(unsafe) let discoverer = pointer
    nonisolated(unsafe) let box = opaque
    let instance = self.instance
    let eventHub = self.eventHub
    DiscoveryLifecycle.async {
      let em = libvlc_renderer_discoverer_event_manager(discoverer)!
      for eventType in RendererEventAttachment.eventTypes {
        libvlc_event_detach(em, eventType, rendererCallback, box)
      }
      eventHub.terminate()
      Unmanaged<CurrentInventoryEventHub<RendererItem, UInt, RendererEvent>>
        .fromOpaque(box).release()
      libvlc_renderer_discoverer_release(discoverer)
      _ = instance
    }
  }

  /// Starts renderer discovery.
  /// - Throws: `VLCError.operationFailed` if discovery cannot start, or
  ///   `VLCError.invalidState` if this discoverer is already running.
  public func start() throws(VLCError) {
    enum StartResult {
      case started
      case alreadyStarted
      case failed
    }
    let result = DiscoveryLifecycle.sync { () -> StartResult in
      guard !isStarted else { return .alreadyStarted }
      guard libvlc_renderer_discoverer_start(pointer) == 0 else {
        // A module can announce an item synchronously and still fail its open.
        // Never retain that partial generation as current inventory.
        eventHub.removeAll()
        return .failed
      }
      isStarted = true
      return .started
    }
    switch result {
    case .started:
      break
    case .alreadyStarted:
      throw .invalidState("Renderer discovery is already running")
    case .failed:
      throw .operationFailed("Start renderer discovery")
    }
  }

  /// Stops renderer discovery.
  ///
  /// Existing event streams receive a ``RendererEvent/itemDeleted(_:)`` for
  /// each currently known renderer. The streams remain open and can observe a
  /// later ``start()`` on this discoverer.
  public func stop() {
    DiscoveryLifecycle.sync {
      if isStarted {
        libvlc_renderer_discoverer_stop(pointer)
        isStarted = false
      }
      eventHub.removeAll()
    }
  }
}

enum RendererEventAttachment {
  static let eventTypes = [
    Int32(libvlc_RendererDiscovererItemAdded.rawValue),
    Int32(libvlc_RendererDiscovererItemDeleted.rawValue)
  ]

  /// Installs the renderer callbacks as one logical registration. libVLC
  /// requires every detach to match a successful attach, so a partial failure
  /// must roll back only the callbacks that were actually installed.
  static func attachAll(
    attach: (Int32) -> Int32,
    detach: (Int32) -> Void
  ) -> Bool {
    var attached: [Int32] = []
    for eventType in eventTypes {
      guard attach(eventType) == 0 else {
        for attachedType in attached.reversed() {
          detach(attachedType)
        }
        return false
      }
      attached.append(eventType)
    }
    return true
  }
}

// MARK: - Renderer Item

/// A discovered renderer device.
///
/// Holds a reference to the underlying `libvlc_renderer_item_t`.
/// Pass to ``Player/setRenderer(_:)`` to start casting.
///
/// Identity is the retained libVLC renderer-item pointer. Friendly names
/// are not unique on a local network, so equality intentionally avoids
/// collapsing two devices that advertise the same ``type`` and ``name``.
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

  /// Stable identifier for this discovered renderer item while the
  /// underlying libVLC item is alive.
  public var id: String {
    "renderer:\(UInt(bitPattern: UnsafeRawPointer(pointer)))"
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
    if case .itemAdded(let value) = self {
      value
    } else {
      nil
    }
  }

  /// `RendererItem` if this event is `.itemDeleted`, otherwise `nil`.
  public var itemDeleted: RendererItem? {
    if case .itemDeleted(let value) = self {
      value
    } else {
      nil
    }
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
    DiscoveryLifecycle.sync {
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
}

// MARK: - Internals

func rendererCallback(
  event: UnsafePointer<libvlc_event_t>?,
  opaque: UnsafeMutableRawPointer?
) {
  guard let event, let opaque else { return }
  let eventHub = Unmanaged<
    CurrentInventoryEventHub<RendererItem, UInt, RendererEvent>
  >.fromOpaque(opaque).takeUnretainedValue()
  let type = libvlc_event_e(rawValue: UInt32(event.pointee.type))

  switch type {
  case libvlc_RendererDiscovererItemAdded:
    guard let item = event.pointee.u.renderer_discoverer_item_added.item else { return }
    let renderer = RendererItem(retaining: item)
    eventHub.add(renderer)

  case libvlc_RendererDiscovererItemDeleted:
    guard let item = event.pointee.u.renderer_discoverer_item_deleted.item else { return }
    let renderer = RendererItem(retaining: item)
    eventHub.remove(renderer)

  default:
    break
  }
}
