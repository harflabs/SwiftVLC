@testable import SwiftVLC
import Testing

@Suite("Viewpoint", .tags(.logic))
struct ViewpointTests {
  @Test("Default init values")
  func defaultInitValues() {
    let vp = Viewpoint()
    #expect(vp.yaw == 0)
    #expect(vp.pitch == 0)
    #expect(vp.roll == 0)
    #expect(vp.fieldOfView == 80)
  }

  @Test("Custom init")
  func customInit() {
    let vp = Viewpoint(yaw: 90, pitch: -45, roll: 10, fieldOfView: 120)
    #expect(vp.yaw == 90)
    #expect(vp.pitch == -45)
    #expect(vp.roll == 10)
    #expect(vp.fieldOfView == 120)
  }

  @Test("Hashable equality")
  func hashableEquality() {
    let a = Viewpoint(yaw: 10, pitch: 20)
    let b = Viewpoint(yaw: 10, pitch: 20)
    #expect(a == b)
  }

  @Test("Hashable inequality")
  func hashableInequality() {
    let a = Viewpoint(yaw: 10, pitch: 20)
    let b = Viewpoint(yaw: 10, pitch: 30)
    #expect(a != b)
  }

  @Test("Is Sendable")
  func isSendable() {
    let vp = Viewpoint()
    let sendable: any Sendable = vp
    _ = sendable
  }

  @Test("Mutability")
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

  @Test("Player updateViewpoint safety", .tags(.mainActor, .integration))
  @MainActor
  func playerUpdateViewpointSafety() throws {
    let player = try Player()
    // updateViewpoint on idle player should not crash (may throw but won't crash)
    let vp = Viewpoint(yaw: 45, pitch: 0)
    do {
      try player.updateViewpoint(vp)
    } catch {
      // Expected — no media loaded
    }
  }
}
