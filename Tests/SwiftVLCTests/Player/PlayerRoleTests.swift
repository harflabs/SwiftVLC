@testable import SwiftVLC
import CLibVLC
import Testing

@Suite(.tags(.logic), .timeLimit(.minutes(1)))
struct PlayerRoleTests {
  @Test(
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
    arguments: [
      PlayerRole.none, .music, .video, .communication, .game,
      .notification, .animation, .production, .accessibility, .test,
    ]
  )
  func `C value round-trip`(role: PlayerRole) {
    let reconstructed = PlayerRole(from: Int32(role.cValue))
    #expect(reconstructed == role)
  }

  @Test
  func `Unknown defaults to .none`() {
    let role = PlayerRole(from: 999)
    #expect(role == .none)
  }

  @Test
  func hashable() {
    let set: Set<PlayerRole> = [.none, .music, .video, .none]
    #expect(set.count == 3)
  }
}
