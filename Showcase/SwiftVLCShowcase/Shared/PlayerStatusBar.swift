import SwiftUI
import SwiftVLC

/// Compact player state and timecode display for niche demos.
struct PlayerStatusBar: View {
  let player: Player

  var body: some View {
    HStack {
      Label(stateLabel, systemImage: stateIcon)
        .foregroundStyle(.secondary)
      Spacer()
      Text("\(player.currentTime.formatted) / \(player.duration.formatted)")
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .contentTransition(.numericText())
    }
    .font(.caption)
  }

  private var stateLabel: String {
    switch player.state {
    case .idle: "Idle"
    case .opening: "Opening"
    case .buffering(let pct): "Buffering \(Int(pct * 100))%"
    case .playing: "Playing"
    case .paused: "Paused"
    case .stopped: "Stopped"
    case .stopping: "Stopping"
    case .error: "Error"
    }
  }

  private var stateIcon: String {
    switch player.state {
    case .playing: "play.fill"
    case .paused: "pause.fill"
    case .buffering: "arrow.clockwise"
    case .error: "exclamationmark.triangle"
    default: "circle"
    }
  }
}
