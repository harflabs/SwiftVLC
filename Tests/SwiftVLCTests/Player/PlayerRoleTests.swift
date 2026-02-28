@testable import SwiftVLC
import CLibVLC
import Testing

@Suite("PlayerRole", .tags(.logic))
struct PlayerRoleTests {
  @Test(
    "Descriptions",
    arguments: [
      (PlayerRole.none, "none"),
      (.music, "music"),
      (.video, "video"),
      (.communication, "communication"),
      (.game, "game"),
      (.notification, "notification"),
      (.animation, "animation"),
      (.production, "production"),
      (.accessibility, "accessibility"),
      (.test, "test")
    ] as [(PlayerRole, String)]
  )
  func descriptions(role: PlayerRole, expected: String) {
    #expect(role.description == expected)
  }

  @Test(
    "C value round-trip",
    arguments: [
      PlayerRole.none, .music, .video, .communication, .game,
      .notification, .animation, .production, .accessibility, .test,
    ]
  )
  func cValueRoundTrip(role: PlayerRole) {
    let reconstructed = PlayerRole(from: Int32(role.cValue))
    #expect(reconstructed == role)
  }

  @Test("Unknown defaults to .none")
  func unknownDefaultsToNone() {
    let role = PlayerRole(from: 999)
    #expect(role == .none)
  }

  @Test("Hashable")
  func hashable() {
    let set: Set<PlayerRole> = [.none, .music, .video, .none]
    #expect(set.count == 3)
  }
}
