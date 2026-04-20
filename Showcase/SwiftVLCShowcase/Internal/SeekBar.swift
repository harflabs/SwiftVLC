import SwiftUI
import SwiftVLC

/// Scrub bar with current time and duration. Drop into any Form `Section`.
struct SeekBar: View {
  let player: Player

  var body: some View {
    @Bindable var bindable = player
    Group {
      CompatSlider(value: $bindable.position, range: 0...1)
      LabeledContent("Current", value: format(player.currentTime))
      LabeledContent("Duration", value: format(player.duration ?? .zero))
    }
  }

  private func format(_ duration: Duration) -> String {
    let seconds = Int(duration.components.seconds)
    return String(format: "%d:%02d", seconds / 60, seconds % 60)
  }
}
