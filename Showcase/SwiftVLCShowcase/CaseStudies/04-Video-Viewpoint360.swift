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
      } footer: {
        PlayPauseFooter(player: player)
      }

      Section("Viewpoint") {
        VStack(alignment: .leading) {
          LabeledContent("Yaw", value: String(format: "%.0f°", yaw))
          CompatSlider(value: $yaw, range: -180...180, step: 5)
        }
        VStack(alignment: .leading) {
          LabeledContent("Pitch", value: String(format: "%.0f°", pitch))
          CompatSlider(value: $pitch, range: -90...90, step: 5)
        }
        VStack(alignment: .leading) {
          LabeledContent("Field of view", value: String(format: "%.0f°", fov))
          CompatSlider(value: $fov, range: 20...120, step: 5)
        }
      }
    }
    .navigationTitle("360° viewpoint")
    .task { try? player.play(url: TestMedia.bigBuckBunny) }
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
