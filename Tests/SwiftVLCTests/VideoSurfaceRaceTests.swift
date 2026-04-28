@testable import SwiftVLC
import Testing

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Regression tests for the `VideoSurface` <-> libVLC decoder-thread
/// boundary during dismissal.
///
/// Before the fix, `VideoSurface.attach(to:)` handed libVLC an
/// `Unmanaged.passUnretained(self).toOpaque()` pointer via
/// `libvlc_media_player_set_nsobject`, and UIKit/AppKit could release the
/// view independently of libVLC's decode/vout thread. Dropping the view
/// without calling `detach()` first left libVLC with a dangling `void *`
/// and the next vout init dereferenced freed memory — a reproducible
/// SIGSEGV under parallel test execution.
///
/// The fix moves drawable ownership onto ``Player``: `attach` now calls
/// ``Player/setDrawable(_:)`` which strongly retains the view for the
/// lifetime of the attachment, and `Player.deinit` clears libVLC's
/// pointer *before* releasing the view. Mirrors VLCKit's `_drawable`
/// ivar pattern from `VLCMediaPlayer.m:583-592`.
///
/// These tests exercise the six dismissal patterns most likely to
/// regress that invariant. Serial `swift test` now passes all of them;
/// parallel execution still uncovers a separate upstream libupnp race in
/// renderer discovery, which is why `Integration` is `.serialized`
/// (see `BaseSuites.swift`). A headless `swift test` has no window
/// server so the macOS vout never fully spins up — these tests still
/// cover the attach/detach ordering that the bug lived in.
extension Integration {
  @Suite(
    .tags(.mainActor),
    .enabled(if: TestCondition.canPlayMedia, "Requires video output (skipped on CI)")
  )
  @MainActor struct VideoSurfaceRaceTests {
    /// Scenario (a): attach → play → mid-render detach → drop surface →
    /// drop player. The detach is called explicitly, matching the
    /// `dismantleUIView` path. `Player.setDrawable(nil)` must release
    /// its strong retention of the surface synchronously with telling
    /// libVLC to forget the pointer.
    @Test
    func `attach play detach drop surface drop player 20 iterations`() async throws {
      let instance = try VLCInstance(arguments: ["--quiet"])
      for _ in 0..<20 {
        let player = Player(instance: instance)
        let surface = VideoSurface()
        surface.attach(to: player)
        try player.play(url: TestMedia.twosecURL)
        // Brief yield so the vout thread has a chance to pick up the
        // drawable. Without a real UI host the vout likely fails early,
        // but the pointer is still dereferenced at least once.
        try await Task.sleep(for: .milliseconds(5))
        // The whole suite is @MainActor, so `detach()` is guaranteed to
        // run on main. libVLC's decoder/vout thread is where the
        // dangling-pointer read would occur if this scenario fails.
        surface.detach()
        player.stop()
        _ = surface
        _ = player
      }
    }

    /// Scenario (b): attach → play → drop surface WITHOUT explicit
    /// detach. Reproduces the original bug pattern: `dismantleUIView`
    /// fires after the view has already been deallocated, so libVLC's
    /// stored pointer would be dangling under the old
    /// `passUnretained` design. With ``Player/setDrawable(_:)`` the
    /// player now holds the surface strongly until it is explicitly
    /// replaced or the player itself is released, so the surface stays
    /// live through the player's `stop()`.
    @Test
    func `drop surface without detach triggers pointer reuse 10 iterations`() async throws {
      let instance = try VLCInstance(arguments: ["--quiet"])
      for _ in 0..<10 {
        let player = Player(instance: instance)
        // Drop the surface in a nested scope — ARC releases the local
        // reference, but `player.drawable` is still holding it, so the
        // view outlives this block.
        do {
          let surface = VideoSurface()
          surface.attach(to: player)
          try player.play(url: TestMedia.twosecURL)
          try await Task.sleep(for: .milliseconds(5))
          // NOTE: no explicit detach() — this is the bug pattern the
          // fix has to survive.
          _ = surface
        }
        // `stop()` forces a vout teardown that reads the stored
        // pointer. With the fix, the player's retention keeps the
        // surface alive for this read.
        player.stop()
        try await Task.sleep(for: .milliseconds(5))
      }
    }

    /// Scenario (c): rapid surface swap while playback is active.
    /// `attach(to:)` on B calls `Player.setDrawable(B)`, which internally
    /// binds the previous drawable (A) to a local so its lifetime
    /// extends across the `libvlc_media_player_set_nsobject` call — the
    /// vout thread never sees A's pointer after B's has been stored,
    /// but A is still alive through the atomic swap. A is released at
    /// the end of `setDrawable`.
    @Test
    func `rapid surface swap A to B 20 iterations`() async throws {
      let instance = try VLCInstance(arguments: ["--quiet"])
      let player = Player(instance: instance)
      try player.play(url: TestMedia.twosecURL)
      for _ in 0..<20 {
        let surfaceA = VideoSurface()
        surfaceA.attach(to: player)
        try await Task.sleep(for: .milliseconds(2))
        let surfaceB = VideoSurface()
        surfaceB.attach(to: player)
        // Drop both locals. `player.drawable` retains B; A was already
        // released when B was attached.
        _ = surfaceA
        _ = surfaceB
      }
      player.stop()
    }

    /// Scenario (d): concurrent attach from multiple surfaces within the
    /// same main-actor turn. Swift's main-actor serialization means
    /// these can't truly race on the Swift side, but libVLC's
    /// `var_SetAddress` is what actually orders the stores — and the
    /// decode thread may read between two stores.
    @Test
    func `serial multi-surface attach ordering 10 iterations`() async throws {
      let instance = try VLCInstance(arguments: ["--quiet"])
      for _ in 0..<10 {
        let player = Player(instance: instance)
        let surfaces = (0..<4).map { _ in VideoSurface() }
        for surface in surfaces {
          surface.attach(to: player)
        }
        try player.play(url: TestMedia.twosecURL)
        try await Task.sleep(for: .milliseconds(3))
        // Detach the last-attached surface — the only one libVLC
        // actually knows about — then drop the rest (which never cleared
        // their `attachedPlayer` ivar because attach() short-circuits
        // on re-attach to the same player).
        surfaces.last?.detach()
        player.stop()
      }
    }

    /// Scenario (e): attach → play → reach `.playing` → drop surface
    /// without explicit detach. Waits for the real `.playing` state
    /// transition so the vout thread has actually latched the drawable
    /// pointer at least once. With the fix, `player.drawable` retains
    /// the surface until the player is stopped and released; the
    /// surface's local reference leaving scope does not affect the
    /// retention.
    @Test
    func `reach playing then drop surface without detach`() async throws {
      let instance = try VLCInstance(arguments: ["--quiet"])
      let player = Player(instance: instance)
      let reached = subscribeAndAwait(.playing, on: player, timeout: .seconds(3))
      do {
        let surface = VideoSurface()
        surface.attach(to: player)
        try player.play(url: TestMedia.twosecURL)
        _ = await reached.value
        _ = surface
      }
      player.stop()
    }

    // Scenario (f): host the surface in a real AppKit window (macOS
    // only). `NSWindow.contentView = surface` triggers the
    // view-hierarchy wiring that libVLC's vout expects, and dropping
    // the window exercises the real dismiss path. Closest a headless
    // test can get to the Showcase runtime.
    //
    // Disabled on CI: GitHub Actions' `macos-latest` runners are
    // paravirtualized M2 instances that lack
    // `AppleM2ScalerParavirtDriver`. libVLC's h264 decoder tries to
    // allocate hardware-backed frame buffers, `IOServiceMatching`
    // fails, and the process aborts before any test assertion can
    // run. The test passes locally against a real macOS GPU and is
    // kept around for manual runs; a proper equivalent for CI belongs
    // in the `iOSUITests` target, which hosts the real
    // Showcase app with a real `NSApplication`.
    #if canImport(AppKit)
    @Test(.disabled("CI runners lack AppleM2ScalerParavirtDriver; run locally or via UI-test target"))
    func `NSWindow hosted surface attach play drop window 10 iterations`() async throws {
      let instance = try VLCInstance(arguments: ["--quiet"])
      for _ in 0..<10 {
        let player = Player(instance: instance)
        do {
          let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
          )
          let surface = VideoSurface()
          surface.frame = NSRect(x: 0, y: 0, width: 320, height: 240)
          window.contentView = surface
          surface.attach(to: player)
          try player.play(url: TestMedia.twosecURL)
          try await Task.sleep(for: .milliseconds(5))
          // Intentionally do NOT detach — simulate the SwiftUI
          // teardown order where the view is released before the
          // representable's dismantle hook runs.
          _ = window
        }
        player.stop()
        try await Task.sleep(for: .milliseconds(5))
      }
    }
    #endif
  }
}
