#if os(iOS) || os(macOS)
@_spi(PrivateMacOSPiP) @testable import SwiftVLC
import AVKit
import Testing

/// `start()` used to return `Void` from four indistinguishable early exits, so
/// a caller could not tell a request that reached AVKit from one that never
/// left the controller — and therefore could not decide whether to fall back to
/// full-screen playback.
extension Integration {
  @Suite(.tags(.mainActor))
  @MainActor struct PiPStartResultTests {
    @Test
    func `Starting without media reports noMedia`() {
      let player = Player(instance: TestInstance.shared)
      let controller = PiPController(player: player)

      #expect(player.currentMedia == nil)
      #expect(controller.start() == .noMedia)
    }

    /// The distinction that motivates the type: with media loaded, the result
    /// must describe why the request could not be issued rather than silently
    /// collapsing to the same nothing as the no-media case.
    @Test
    func `Starting with media never reports noMedia`() throws {
      let player = Player(instance: TestInstance.shared)
      try player.load(Media(url: TestMedia.twosecURL))
      let controller = PiPController(player: player)

      let result = controller.start()

      #expect(result != .noMedia)
      // Headless CI has no PiP, a Mac desktop may. Both are legitimate; what
      // matters is that the outcome is named either way.
      #expect(
        result == .accepted || result == .notPossible || result == .backendUnavailable,
        "unexpected start result: \(result)"
      )
    }

    /// An accepted result has to mean the request was actually issued, so it
    /// must not be reachable when PiP is unavailable.
    @Test
    func `Accepted is never reported when PiP is not possible`() throws {
      let player = Player(instance: TestInstance.shared)
      try player.load(Media(url: TestMedia.twosecURL))
      let controller = PiPController(player: player)

      let result = controller.start()

      if !controller.isPossible {
        #expect(result != .accepted, "start claimed acceptance while PiP was impossible")
      }
    }

    @Test
    func `A direct impossible start records no lifecycle attribution`() throws {
      let player = Player(instance: TestInstance.shared)
      try player.load(Media(url: TestMedia.twosecURL))
      let controller = PiPController(player: player)
      if controller.pipController == nil {
        let contentSource = AVPictureInPictureController.ContentSource(
          sampleBufferDisplayLayer: controller.layer,
          playbackDelegate: controller._playbackDelegateForTesting
        )
        controller.pipController = AVPictureInPictureController(contentSource: contentSource)
      }
      controller._setStateForTesting(isPossible: false)

      #expect(controller.start() == .notPossible)
      #expect(controller.pipLifecycleAttribution == nil)
      #expect(controller.pipLifecycleAttributionPhase == .idle)
    }

    /// `toggle()` has to propagate the start result when it takes the start
    /// branch. A caller that wants to fall back on a refused start needs to
    /// tell "I tried to start and it was refused" from "I stopped".
    @Test
    func `Toggle propagates the start result and reports nil for a stop`() {
      let player = Player(instance: TestInstance.shared)
      let controller = PiPController(player: player)

      #expect(controller.isActive == false)
      #expect(controller.toggle() == .noMedia, "toggle discarded the start result")

      controller._setStateForTesting(isActive: true)
      #expect(controller.toggle() == nil, "toggle reported a start result for a stop")
    }

    #if os(macOS)
    /// The macOS backend must report the same four cases as the controller, or
    /// "equivalent result semantics across backends" is only true on paper.
    @Test
    func `The macOS backend reports noMedia without media`() {
      let player = Player(instance: TestInstance.shared)
      let backend = MacNativePiPBackend()
      backend.attach(to: player)

      #expect(player.currentMedia == nil)
      #expect(backend.start() == .noMedia)
    }

    /// With media loaded but no video output, PiP is genuinely impossible —
    /// which must read as .notPossible rather than collapsing into the same
    /// nothing as the no-media case.
    @Test
    func `The macOS backend reports notPossible without video output`() throws {
      let instance = try VLCInstance(
        arguments: ["--no-video-title-show", "--no-video", "--no-audio", "--quiet"]
      )
      let player = Player(instance: instance)
      try player.load(Media(url: TestMedia.twosecURL))
      let backend = MacNativePiPBackend()
      backend.attach(to: player)

      #expect(backend.start() == .notPossible)
    }

    /// With the private-framework opt-in enabled, PiP can become possible while
    /// the host and drawable views have not been wired up yet. That window must
    /// report backendUnavailable — a transient setup state the caller should
    /// retry — rather than notPossible, which says this machine will never do
    /// PiP and invites the caller to hide its button permanently.
    @Test
    func `The macOS backend separates an unwired backend from an impossible one`() throws {
      let initial = PiPController.allowsPrivateMacOSAPI
      defer { PiPController.allowsPrivateMacOSAPI = initial }
      PiPController.allowsPrivateMacOSAPI = true

      let player = Player(instance: TestInstance.shared)
      try player.load(Media(url: TestMedia.twosecURL))
      let backend = MacNativePiPBackend()
      backend.attach(to: player)

      let result = backend.start()

      // Whether PIP.framework loads is a property of the host, so both outcomes
      // are legitimate. What must never happen is the two collapsing together.
      if backend.isPossible {
        #expect(result == .backendUnavailable, "an unwired backend reported \(result)")
      } else {
        #expect(result == .notPossible)
      }
    }
    #endif

    /// The remaining early exit: a controller whose AVKit controller was never
    /// created has nowhere to send the request. That is a transient setup
    /// state, so it must read as backendUnavailable rather than notPossible.
    @Test
    func `A controller with no AVKit controller reports backendUnavailable`() throws {
      let player = Player(instance: TestInstance.shared)
      try player.load(Media(url: TestMedia.twosecURL))
      let controller = PiPController(player: player)
      controller.pipController = nil

      #expect(controller.start() == .backendUnavailable)
    }

    #if os(macOS)
    /// A controller that owns a native backend must delegate to it rather than
    /// answering from its own AVKit controller, or the two could disagree about
    /// the same request.
    @Test
    func `A controller with a native backend delegates the start result`() throws {
      let player = Player(instance: TestInstance.shared)
      let backend = MacNativePiPBackend()
      backend.attach(to: player)
      let controller = PiPController(player: player, nativeBackend: backend)

      #expect(controller.start() == .noMedia)

      try player.load(Media(url: TestMedia.twosecURL))
      #expect(controller.start() == backend.start())
    }
    #endif

    @Test
    func `Start results are distinct`() {
      let all: [PiPStartResult] = [.accepted, .noMedia, .notPossible, .backendUnavailable]
      #expect(Set(all.map(String.init(describing:))).count == all.count)
    }
  }
}
#endif
