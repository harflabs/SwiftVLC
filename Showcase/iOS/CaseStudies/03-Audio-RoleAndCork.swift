import SwiftUI
import SwiftVLC

private let readMe = """
`PlayerRole` hints the system about what the audio is for: `.music`, \
`.video`, `.communication`, `.game`, and so on. The role influences AirPods \
switching, Do Not Disturb treatment, and ducking priority. Corking is the \
system-driven side: `.corked` fires when something else (a phone call, Siri, \
another app's audio-focus request) takes priority, and `.uncorked` when it \
releases. The badge below flips live when it happens.
"""

struct RoleAndCorkCase: View {
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
    Form {
      Section { AboutView(readMe: readMe) }

      Section {
        VideoView(player)
          .aspectRatio(16 / 9, contentMode: .fit)
          .listRowInsets(EdgeInsets())
          .accessibilityIdentifier(AccessibilityID.RoleAndCork.videoView)
      } footer: {
        PlayPauseFooter(player: player)
          .accessibilityIdentifier(AccessibilityID.RoleAndCork.playPauseButton)
      }

      Section("Role") {
        Picker("Role", selection: $selectedRole) {
          ForEach(roles, id: \.self) { role in
            Text(role.description.capitalized).tag(role)
          }
        }
        .accessibilityIdentifier(AccessibilityID.RoleAndCork.rolePicker)
        .onChange(of: selectedRole) { _, new in
          player.role = new
        }
      }

      Section {
        HStack {
          Text("Status")
          Spacer()
          Text(isCorked ? "Corked" : "Active")
            .foregroundStyle(isCorked ? .orange : .green)
            .fontWeight(.semibold)
            .accessibilityIdentifier(AccessibilityID.RoleAndCork.statusLabel)
        }
        HStack {
          Text("Cork events")
          Spacer()
          Text("\(corkedCount)")
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .accessibilityIdentifier(AccessibilityID.RoleAndCork.corkedCountLabel)
        }
        HStack {
          Text("Uncork events")
          Spacer()
          Text("\(uncorkedCount)")
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .accessibilityIdentifier(AccessibilityID.RoleAndCork.uncorkedCountLabel)
        }
      } header: {
        Text("Corking")
      } footer: {
        Text("To trigger corking: start a phone call, open Siri, or play audio in another app. libVLC will report `.corked` automatically.")
      }
    }
    .showcaseFormStyle()
    .navigationTitle("Role & corking")
    .task { await task() }
    .onDisappear { player.stop() }
  }

  private func task() async {
    player.role = selectedRole
    try? player.play(url: TestMedia.demo)
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
}
