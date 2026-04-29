import SwiftUI
import SwiftVLC

struct MacRoleAndCorkCase: View {
  @State private var player = Player()
  @State private var selectedRole: PlayerRole = .music
  @State private var isCorked = false
  @State private var corkedCount = 0
  @State private var uncorkedCount = 0

  private let roles: [PlayerRole] = [
    .none, .music, .video, .communication, .game,
    .notification, .animation, .production, .accessibility, .test
  ]

  var body: some View {
    MacShowcaseContent(
      title: "Role & Corking",
      summary: "Set the system audio role and observe cork/uncork events when another audio session takes priority.",
      usage: "Choose the audio role and keep playback active; the counters show cork and uncork events when the system interrupts audio."
    ) {
      VStack(spacing: 16) {
        MacVideoPanel(player: player)
        MacPlaybackControls(player: player)
        MacSection(title: "Audio Role") {
          Picker("Role", selection: $selectedRole) {
            ForEach(roles, id: \.self) { role in
              Text(role.description.capitalized).tag(role)
            }
          }
          .onChange(of: selectedRole) { rolePickerChanged() }
        }
      }
    } sidebar: {
      MacSection(title: "Corking") {
        MacMetricGrid {
          MacMetricRow(title: "Status", value: isCorked ? "Corked" : "Active")
          MacMetricRow(title: "Corked", value: "\(corkedCount)")
          MacMetricRow(title: "Uncorked", value: "\(uncorkedCount)")
        }
      }
      MacLibrarySurface(symbols: ["player.role", "PlayerEvent.corked", "PlayerEvent.uncorked"])
    }
    .task { await task() }
    .onDisappear { player.stop() }
  }

  private func task() async {
    rolePickerChanged()
    try? player.play(url: MacTestMedia.demo)
    for await event in player.events {
      switch event {
      case .corked:
        isCorked = true
        corkedCount += 1
      case .uncorked:
        isCorked = false
        uncorkedCount += 1
      default:
        break
      }
    }
  }

  private func rolePickerChanged() {
    player.role = selectedRole
  }
}
