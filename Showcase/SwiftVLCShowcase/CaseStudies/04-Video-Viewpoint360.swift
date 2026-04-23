import SwiftUI
import SwiftVLC

private let readMe = """
For 360° or VR content, `updateViewpoint(_:absolute:)` sets yaw, pitch, roll, and \
field of view. Pass `absolute: false` for incremental rotation.
"""

struct ViewpointCase: View {
  @State private var player = Player()
  @State private var yaw: Float = 0
  @State private var pitch: Float = 0
  @State private var fov: Float = 80

  var body: some View {
    Form {
      Section { AboutView(readMe: readMe) }

      Section {
        VideoView(player)
          .aspectRatio(16 / 9, contentMode: .fit)
          .listRowInsets(EdgeInsets())
          .accessibilityIdentifier(AccessibilityID.Viewpoint.videoView)
      } footer: {
        PlayPauseFooter(player: player)
          .accessibilityIdentifier(AccessibilityID.Viewpoint.playPauseButton)
      }

      Section("Viewpoint") {
        VStack(alignment: .leading) {
          HStack {
            Text("Yaw")
            Spacer()
            Text(String(format: "%.0f°", yaw)).foregroundStyle(.secondary)
          }
          CompatSlider(value: $yaw, range: -180...180, step: 5)
            .accessibilityIdentifier(AccessibilityID.Viewpoint.yawSlider)
        }
        VStack(alignment: .leading) {
          HStack {
            Text("Pitch")
            Spacer()
            Text(String(format: "%.0f°", pitch)).foregroundStyle(.secondary)
          }
          CompatSlider(value: $pitch, range: -90...90, step: 5)
            .accessibilityIdentifier(AccessibilityID.Viewpoint.pitchSlider)
        }
        VStack(alignment: .leading) {
          HStack {
            Text("Field of view")
            Spacer()
            Text(String(format: "%.0f°", fov)).foregroundStyle(.secondary)
          }
          CompatSlider(value: $fov, range: 20...120, step: 5)
            .accessibilityIdentifier(AccessibilityID.Viewpoint.fovSlider)
        }
      }
    }
    .showcaseFormStyle()
    .navigationTitle("360° viewpoint")
    .task { try? player.play(url: TestMedia.demo) }
    .onChange(of: yaw) { apply() }
    .onChange(of: pitch) { apply() }
    .onChange(of: fov) { apply() }
    .onDisappear { player.stop() }
  }

  private func apply() {
    let viewpoint = Viewpoint(yaw: yaw, pitch: pitch, roll: 0, fieldOfView: fov)
    try? player.updateViewpoint(viewpoint)
  }
}
