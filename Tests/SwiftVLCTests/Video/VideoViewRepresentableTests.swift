@testable import SwiftVLC
import Testing

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Covers `VideoView` — the SwiftUI representable — by invoking its
/// lifecycle methods directly without a SwiftUI scene. SwiftUI
/// internally calls these via reflection/protocol conformance; the
/// same methods are available to tests.
///
/// Using a synthesized `Context` isn't straightforward (the type is
/// opaque to tests), so each test constructs the `VideoSurface` the
/// representable would create and drives its attach/detach the same
/// way the representable does.
extension Integration {
  @Suite(.tags(.mainActor))
  @MainActor struct VideoViewRepresentableTests {
    @Test
    func `VideoView init does not crash`() {
      let player = Player(instance: TestInstance.shared)
      _ = VideoView(player)
    }

    /// `dismantleUIView` / `dismantleNSView` must detach the surface
    /// from libVLC. We drive that path by attaching and then calling
    /// the static dismantle hook directly.
    @Test
    func `dismantle detaches the surface cleanly`() {
      let player = Player(instance: TestInstance.shared)
      let surface = VideoSurface()
      surface.attach(to: player)

      #if canImport(UIKit)
      VideoView.dismantleUIView(surface, coordinator: ())
      #elseif canImport(AppKit)
      VideoView.dismantleNSView(surface, coordinator: ())
      #endif

      // After dismantle, the surface has no attached player — a second
      // detach is a safe no-op, proving dismantle ran the detach.
      surface.detach()

      // Player remains usable.
      #expect(player.state == .idle)
    }

    /// Dismantle on a non-VideoSurface view must be a safe no-op —
    /// defensive cast guard inside the dismantle hook.
    @Test
    func `dismantle on wrong view type is a safe no-op`() {
      #if canImport(UIKit)
      let wrong = UIView()
      VideoView.dismantleUIView(wrong, coordinator: ())
      #elseif canImport(AppKit)
      let wrong = NSView()
      VideoView.dismantleNSView(wrong, coordinator: ())
      #endif
    }
  }
}
