import SwiftUI
import SwiftVLC

private let readMe = """
`VLCInstance.shared.audioOutputs()` lists available output modules; \
`player.audioDevices()` enumerates devices for the current output. Most iOS apps only \
see the system default — macOS and Catalyst see more.
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
      } footer: {
        PlayPauseFooter(player: player)
      }

      Section("Output") {
        if outputs.isEmpty {
          Text("None available").foregroundStyle(.secondary)
        } else {
          Picker("Output", selection: $selectedOutput) {
            ForEach(outputs) { output in
              Text(output.outputDescription).tag(output.name)
            }
          }
          .onChange(of: selectedOutput) {
            try? player.setAudioOutput(selectedOutput)
            devices = player.audioDevices()
          }
        }
      }

      Section("Device") {
        if devices.isEmpty {
          Text("None available").foregroundStyle(.secondary)
        } else {
          Picker("Device", selection: $selectedDevice) {
            ForEach(devices) { device in
              Text(device.deviceDescription).tag(device.deviceId)
            }
          }
          .onChange(of: selectedDevice) {
            try? player.setAudioDevice(selectedDevice)
          }
        }
      }
    }
    .showcaseFormStyle()
    .navigationTitle("Audio outputs")
    .task {
      outputs = VLCInstance.shared.audioOutputs()
      try? player.play(url: TestMedia.bigBuckBunny)
      devices = player.audioDevices()
    }
    .onDisappear { player.stop() }
  }
}
