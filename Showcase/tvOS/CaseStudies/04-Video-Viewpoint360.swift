import SwiftUI
import SwiftVLC

struct TVViewpointCase: View {
  @State private var player = Player()
  @State private var yaw: Float = 0
  @State private var pitch: Float = 0
  @State private var fieldOfView: Float = 80

  var body: some View {
    TVShowcaseContent(
      title: "360 Viewpoint",
      summary: "Update yaw, pitch, and field of view for panoramic or VR video sources.",
      usage: "Move yaw, pitch, and field-of-view controls to send a new viewpoint to panoramic video playback."
    ) {
      VStack(spacing: 16) {
        TVVideoPanel(player: player)
        TVPlaybackControls(player: player, showsVolume: false)
        TVSection(title: "Viewpoint") {
          sliderRow("Yaw", value: $yaw, range: -180...180, suffix: "degrees")
          sliderRow("Pitch", value: $pitch, range: -90...90, suffix: "degrees")
          sliderRow("Field of View", value: $fieldOfView, range: 20...120, suffix: "degrees")
        }
      }
    } sidebar: {
      TVSection(title: "Angles", isFocusable: true) {
        TVMetricGrid {
          TVMetricRow(title: "Yaw", value: String(format: "%.0f degrees", yaw))
          TVMetricRow(title: "Pitch", value: String(format: "%.0f degrees", pitch))
          TVMetricRow(title: "FOV", value: String(format: "%.0f degrees", fieldOfView))
        }
      }
      TVLibrarySurface(symbols: ["Viewpoint", "player.updateViewpoint(_:absolute:)"])
    }
    .task { try? player.play(url: TVTestMedia.demo) }
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
    TVSlider(
      title,
      value: value,
      in: range,
      step: 5
    ) { String(format: "%.0f %@", $0, suffix) }
  }
}
