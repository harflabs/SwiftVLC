#if os(iOS) || os(macOS)
@testable import SwiftVLC
import AVFoundation
import SwiftUI
import Testing

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Covers `PiPVideoView` paths that don't require a live SwiftUI
/// scene: the `init`, `makeCoordinator`, and the static dismantle
/// hook that SwiftUI calls when the view is removed from the tree.
///
/// The full `makeUIView` / `makeNSView` path is harder to hit without
/// a SwiftUI host — we drive the coordinator directly instead, which
/// is where the actual lifecycle logic lives.
@Suite(.tags(.integration, .mainActor))
@MainActor
struct PiPVideoViewTests {
  @Test
  func `Init without binding does not crash`() {
    let player = Player(instance: TestInstance.shared)
    _ = PiPVideoView(player)
  }

  @Test
  func `Init with controller binding does not crash`() {
    let player = Player(instance: TestInstance.shared)
    let storage = Box<PiPController?>(nil)
    let binding = Binding<PiPController?>(
      get: { storage.value },
      set: { storage.value = $0 }
    )
    _ = PiPVideoView(player, controller: binding)
  }

  @Test
  func `makeCoordinator returns a usable Coordinator`() {
    let player = Player(instance: TestInstance.shared)
    let view = PiPVideoView(player)

    let coordinator = view.makeCoordinator()
    // Fresh coordinator has no references.
    #expect(coordinator.pipController == nil)
    #expect(coordinator.displayLayer == nil)
    #expect(coordinator.player == nil)
  }

  /// Dismantle on an empty coordinator is a safe no-op — no
  /// controller to stop, no layer to remove.
  @Test
  func `dismantle on empty coordinator is a no-op`() {
    let player = Player(instance: TestInstance.shared)
    let view = PiPVideoView(player)
    let coordinator = view.makeCoordinator()

    #if canImport(UIKit)
    let container = UIView()
    PiPVideoView.dismantleUIView(container, coordinator: coordinator)
    #elseif canImport(AppKit)
    let container = NSView()
    PiPVideoView.dismantleNSView(container, coordinator: coordinator)
    #endif
  }

  /// Dismantle with a controller attached must stop it and clear
  /// all coordinator references.
  @Test
  func `dismantle with attached controller clears state`() {
    let player = Player(instance: TestInstance.shared)
    let view = PiPVideoView(player)
    let coordinator = view.makeCoordinator()

    // Simulate what makeUIView/makeNSView would do: attach a
    // controller to the coordinator.
    let controller = PiPController(player: player)
    coordinator.pipController = controller
    coordinator.displayLayer = controller.layer
    coordinator.player = player

    #if canImport(UIKit)
    let container = UIView()
    PiPVideoView.dismantleUIView(container, coordinator: coordinator)
    #elseif canImport(AppKit)
    let container = NSView()
    PiPVideoView.dismantleNSView(container, coordinator: coordinator)
    #endif

    #expect(coordinator.pipController == nil)
    #expect(coordinator.displayLayer == nil)
  }
}

/// Reference-cell backing for a test-built SwiftUI `Binding`. Avoids
/// pulling in `@State`, which requires a real view hierarchy.
private final class Box<T> {
  var value: T
  init(_ initial: T) {
    value = initial
  }
}
#endif
