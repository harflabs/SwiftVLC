@testable import SwiftVLC
import Testing

@Suite(.tags(.logic), .timeLimit(.minutes(1)))
struct ViewpointTests {
  @Test
  func `Default init values`() {
    let vp = Viewpoint()
    #expect(vp.yaw == 0)
    #expect(vp.pitch == 0)
    #expect(vp.roll == 0)
    #expect(vp.fieldOfView == 80)
  }

  @Test
  func `Custom init`() {
    let vp = Viewpoint(yaw: 90, pitch: -45, roll: 10, fieldOfView: 120)
    #expect(vp.yaw == 90)
    #expect(vp.pitch == -45)
    #expect(vp.roll == 10)
    #expect(vp.fieldOfView == 120)
  }

  @Test
  func `Hashable equality`() {
    let a = Viewpoint(yaw: 10, pitch: 20)
    let b = Viewpoint(yaw: 10, pitch: 20)
    #expect(a == b)
  }

  @Test
  func `Hashable inequality`() {
    let a = Viewpoint(yaw: 10, pitch: 20)
    let b = Viewpoint(yaw: 10, pitch: 30)
    #expect(a != b)
  }

  @Test
  func `Is Sendable`() {
    let vp = Viewpoint()
    let sendable: any Sendable = vp
    _ = sendable
  }

  @Test
  func mutability() {
    var vp = Viewpoint()
    vp.yaw = 180
    vp.pitch = 90
    vp.roll = -180
    vp.fieldOfView = 60
    #expect(vp.yaw == 180)
    #expect(vp.pitch == 90)
    #expect(vp.roll == -180)
    #expect(vp.fieldOfView == 60)
  }

  @Test(.tags(.mainActor, .integration))
  @MainActor
  func `Player updateViewpoint safety`() throws {
    let player = Player(instance: TestInstance.shared)
    // updateViewpoint on idle player should not crash (may throw but won't crash)
    let vp = Viewpoint(yaw: 45, pitch: 0)
    do {
      try player.updateViewpoint(vp)
    } catch {
      // Expected — no media loaded
    }
  }
}
