import SwiftUI
import SwiftVLC

private let readMe = """
`VLCInstance.shared.audioOutputs()` lists available output modules; \
`player.audioDevices()` enumerates devices for the current output. Most iOS apps only \
see the system default; Mac Catalyst builds may expose additional outputs.
"""

struct AudioOutputsCase: View {
  @State private var player = Player()
  @State private var outputs: [AudioOutput] = []
  @State private var devices: [AudioDevice] = []
  @State private var selectedOutput = ""
  @State private var selectedDevice = ""

  var body: some View {
    Form {
      Section { AboutView(readMe: readMe) }

      Section {
        VideoView(player)
          .aspectRatio(16 / 9, contentMode: .fit)
          .listRowInsets(EdgeInsets())
          .accessibilityIdentifier(AccessibilityID.AudioOutputs.videoView)
      } footer: {
        PlayPauseFooter(player: player)
          .accessibilityIdentifier(AccessibilityID.AudioOutputs.playPauseButton)
      }

      Section("Output") {
        if outputs.isEmpty {
          Text("None available")
            .foregroundStyle(.secondary)
            .accessibilityIdentifier(AccessibilityID.AudioOutputs.outputEmptyLabel)
        } else {
          Picker("Output", selection: $selectedOutput) {
            ForEach(outputs) { output in
              Text(output.outputDescription).tag(output.name)
            }
          }
          .accessibilityIdentifier(AccessibilityID.AudioOutputs.outputPicker)
          .onChange(of: selectedOutput) { outputPickerChanged() }
        }
      }

      Section("Device") {
        if devices.isEmpty {
          Text("None available")
            .foregroundStyle(.secondary)
            .accessibilityIdentifier(AccessibilityID.AudioOutputs.deviceEmptyLabel)
        } else {
          Picker("Device", selection: $selectedDevice) {
            ForEach(devices) { device in
              Text(device.deviceDescription).tag(device.deviceId)
            }
          }
          .accessibilityIdentifier(AccessibilityID.AudioOutputs.devicePicker)
          .onChange(of: selectedDevice) {
            try? player.setAudioDevice(selectedDevice)
          }
        }
      }
    }
    .showcaseFormStyle()
    .navigationTitle("Audio outputs")
    .task { task() }
    .onDisappear { player.stop() }
  }

  private func task() {
    outputs = VLCInstance.shared.audioOutputs()
    try? player.play(url: TestMedia.demo)
    devices = player.audioDevices()
  }

  private func outputPickerChanged() {
    try? player.setAudioOutput(selectedOutput)
    devices = player.audioDevices()
  }
}
