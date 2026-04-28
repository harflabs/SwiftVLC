import SwiftUI
import SwiftVLC

struct MacViewpointCase: View {
  @State private var player = Player()
  @State private var yaw: Float = 0
  @State private var pitch: Float = 0
  @State private var fieldOfView: Float = 80

  var body: some View {
    MacShowcaseContent(
      title: "360 Viewpoint",
      summary: "Update yaw, pitch, and field of view for panoramic or VR video sources.",
      usage: "Move yaw, pitch, and field-of-view controls to send a new viewpoint to panoramic video playback."
    ) {
      VStack(spacing: 16) {
        MacVideoPanel(player: player)
        MacPlaybackControls(player: player, showsVolume: false)
        MacSection(title: "Viewpoint") {
          sliderRow("Yaw", value: $yaw, range: -180...180, suffix: "degrees")
          sliderRow("Pitch", value: $pitch, range: -90...90, suffix: "degrees")
          sliderRow("Field of View", value: $fieldOfView, range: 20...120, suffix: "degrees")
        }
      }
    } sidebar: {
      MacSection(title: "Angles") {
        MacMetricGrid {
          MacMetricRow(title: "Yaw", value: String(format: "%.0f degrees", yaw))
          MacMetricRow(title: "Pitch", value: String(format: "%.0f degrees", pitch))
          MacMetricRow(title: "FOV", value: String(format: "%.0f degrees", fieldOfView))
        }
      }
      MacLibrarySurface(symbols: ["Viewpoint", "player.updateViewpoint(_:absolute:)"])
    }
    .task { try? player.play(url: MacTestMedia.demo) }
    .onChange(of: yaw) { applyViewpoint() }
    .onChange(of: pitch) { applyViewpoint() }
    .onChange(of: fieldOfView) { applyViewpoint() }
    .onDisappear { player.stop() }
  }

  private func applyViewpoint() {
    try? player.updateViewpoint(Viewpoint(yaw: yaw, pitch: pitch, fieldOfView: fieldOfView))
  }

  private func sliderRow(
    _ title: String,
    value: Binding<Float>,
    range: ClosedRange<Float>,
    suffix: String
  ) -> some View {
    HStack {
      Text(title)
        .frame(width: 92, alignment: .leading)
      Slider(value: value, in: range, step: 5)
      Text(String(format: "%.0f %@", value.wrappedValue, suffix))
        .font(.callout.monospacedDigit())
        .foregroundStyle(.secondary)
        .frame(width: 92, alignment: .trailing)
    }
  }
}
