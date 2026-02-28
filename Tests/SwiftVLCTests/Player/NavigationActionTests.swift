@testable import SwiftVLC
import CLibVLC
import Testing

@Suite("NavigationAction", .tags(.logic))
struct NavigationActionTests {
  @Test(
    "Descriptions",
    arguments: [
      (NavigationAction.activate, "activate"),
      (.up, "up"),
      (.down, "down"),
      (.left, "left"),
      (.right, "right"),
      (.popup, "popup")
    ] as [(NavigationAction, String)]
  )
  func descriptions(action: NavigationAction, expected: String) {
    #expect(action.description == expected)
  }

  @Test(
    "C values match C constants",
    arguments: [
      (NavigationAction.activate, UInt32(libvlc_navigate_activate.rawValue)),
      (.up, UInt32(libvlc_navigate_up.rawValue)),
      (.down, UInt32(libvlc_navigate_down.rawValue)),
      (.left, UInt32(libvlc_navigate_left.rawValue)),
      (.right, UInt32(libvlc_navigate_right.rawValue)),
      (.popup, UInt32(libvlc_navigate_popup.rawValue)),
    ] as [(NavigationAction, UInt32)]
  )
  func cValuesMatchConstants(action: NavigationAction, expected: UInt32) {
    #expect(action.cValue == expected)
  }

  @Test("Hashable")
  func hashable() {
    let set: Set<NavigationAction> = [.activate, .up, .down, .left, .right, .popup, .activate]
    #expect(set.count == 6)
  }

  @Test("Exhaustive cases")
  func exhaustiveCases() {
    let all: [NavigationAction] = [.activate, .up, .down, .left, .right, .popup]
    #expect(all.count == 6)
  }
}
