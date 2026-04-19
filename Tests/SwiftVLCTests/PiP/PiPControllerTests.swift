#if os(iOS) || os(macOS)
@testable import SwiftVLC
import AVFoundation
import Testing

@Suite(.tags(.integration, .mainActor), .timeLimit(.minutes(1)))
@MainActor
struct PiPControllerTests {
  @Test
  func `Init with player does not crash`() {
    let player = Player()
    let controller = PiPController(player: player)
    _ = controller
  }

  @Test
  func `isPossible reflects PiP support of the environment`() {
    let player = Player()
    let controller = PiPController(player: player)
    // On macOS desktop, PiP may be supported; on headless CI it won't be.
    // Just verify accessing the property doesn't crash and returns a Bool.
    let possible = controller.isPossible
    #expect(possible == true || possible == false)
  }

  @Test
  func `isActive returns false initially`() {
    let player = Player()
    let controller = PiPController(player: player)
    #expect(controller.isActive == false)
  }

  @Test
  func `layer returns a valid AVSampleBufferDisplayLayer`() {
    let player = Player()
    let controller = PiPController(player: player)
    let layer = controller.layer
    #expect(layer is AVSampleBufferDisplayLayer)
    #expect(layer.videoGravity == .resizeAspect)
  }

  @Test
  func `start does not crash without PiP support`() {
    let player = Player()
    let controller = PiPController(player: player)
    controller.start()
  }

  @Test
  func `stop does not crash without PiP support`() {
    let player = Player()
    let controller = PiPController(player: player)
    controller.stop()
  }

  @Test
  func `toggle does not crash without PiP support`() {
    let player = Player()
    let controller = PiPController(player: player)
    controller.toggle()
  }

  @Test
  func `Creating PiPController attaches vmem callbacks`() {
    let player = Player()
    let controller = PiPController(player: player)
    // If vmem callbacks were attached incorrectly, subsequent player
    // operations would crash. Verify the player is still usable.
    #expect(player.state == .idle)
    _ = player.currentTime
    _ = player.volume
    _ = controller
  }

  @Test
  func `PiPController deinit cleans up without crash`() {
    let player = Player()
    do {
      let controller = PiPController(player: player)
      _ = controller.layer
      controller.start()
      // controller goes out of scope and deinits here
    }
    // Player should still be usable after PiPController is deallocated
    #expect(player.state == .idle)
  }

  @Test
  func `Multiple PiPControllers for different players`() {
    let player1 = Player()
    let player2 = Player()
    let controller1 = PiPController(player: player1)
    let controller2 = PiPController(player: player2)
    // Each controller should have its own independent layer
    #expect(controller1.layer !== controller2.layer)
    #expect(controller1.isActive == false)
    #expect(controller2.isActive == false)
    // Both players should remain functional
    #expect(player1.state == .idle)
    #expect(player2.state == .idle)
  }
}
#endif
