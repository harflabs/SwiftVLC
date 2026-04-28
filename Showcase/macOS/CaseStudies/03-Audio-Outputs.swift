import SwiftUI
import SwiftVLC

struct MacAudioOutputsCase: View {
  @State private var player = Player()
  @State private var outputs: [AudioOutput] = []
  @State private var devices: [AudioDevice] = []
  @State private var selectedOutput = ""
  @State private var selectedDevice = ""

  var body: some View {
    MacShowcaseContent(
      title: "Audio Outputs",
      summary: "List libVLC audio outputs and devices, then route playback through the selected device.",
      usage: "Select an output and device from the available hardware lists, then verify Player.currentAudioDevice in the inspector."
    ) {
      VStack(spacing: 16) {
        MacVideoPanel(player: player)
        MacPlaybackControls(player: player)
        MacSection(title: "Output Routing") {
          Picker("Output", selection: $selectedOutput) {
            ForEach(outputs) { output in
              Text(output.outputDescription).tag(output.name)
            }
          }
          .disabled(outputs.isEmpty)
          .onChange(of: selectedOutput) { outputPickerChanged() }

          Picker("Device", selection: $selectedDevice) {
            ForEach(devices) { device in
              Text(device.deviceDescription).tag(device.deviceId)
            }
          }
          .disabled(devices.isEmpty)
          .onChange(of: selectedDevice) { devicePickerChanged() }
        }
      }
    } sidebar: {
      MacSection(title: "Available") {
        MacMetricGrid {
          MacMetricRow(title: "Outputs", value: "\(outputs.count)")
          MacMetricRow(title: "Devices", value: "\(devices.count)")
          MacMetricRow(title: "Current", value: player.currentAudioDevice ?? "--")
        }
      }
      MacLibrarySurface(symbols: ["VLCInstance.audioOutputs()", "player.audioDevices()", "player.setAudioDevice(_:)"])
    }
    .task { task() }
    .onDisappear { player.stop() }
  }

  private func task() {
    outputs = VLCInstance.shared.audioOutputs()
    selectedOutput = outputs.first?.name ?? ""
    try? player.play(url: MacTestMedia.demo)
    refreshDevices()
  }

  private func outputPickerChanged() {
    try? player.setAudioOutput(selectedOutput)
    refreshDevices()
  }

  private func devicePickerChanged() {
    try? player.setAudioDevice(selectedDevice)
  }

  private func refreshDevices() {
    devices = player.audioDevices()
    selectedDevice = devices.first?.deviceId ?? ""
  }
}
