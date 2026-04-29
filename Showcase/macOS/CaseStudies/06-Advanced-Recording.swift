import SwiftUI
import SwiftVLC

struct MacRecordingCase: View {
  @State private var player = Player()
  @State private var isRecording = false
  @State private var outputPath: String?

  var body: some View {
    MacShowcaseContent(
      title: "Recording",
      summary: "Record the currently playing stream to a directory and observe recordingChanged events.",
      usage: "Start recording while media plays, stop it, and check the output file reported from recordingChanged events."
    ) {
      VStack(spacing: 16) {
        MacVideoPanel(player: player)
        MacPlaybackControls(player: player)
        MacSection(title: "Recorder") {
          Button(isRecording ? "Stop Recording" : "Start Recording", systemImage: isRecording ? "stop.circle.fill" : "record.circle.fill") {
            recordingButtonTapped()
          }
          .tint(isRecording ? .red : .accentColor)

          if let outputPath {
            Text(outputPath)
              .font(.caption)
              .foregroundStyle(.secondary)
              .textSelection(.enabled)
          }
        }
      }
    } sidebar: {
      MacSection(title: "Recording") {
        MacMetricGrid {
          MacMetricRow(title: "Active", value: isRecording ? "Yes" : "No")
          MacMetricRow(title: "Directory", value: FileManager.default.temporaryDirectory.lastPathComponent)
          MacMetricRow(title: "Last File", value: outputPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "--")
        }
      }
      MacLibrarySurface(symbols: ["player.startRecording(to:)", "player.stopRecording()", "PlayerEvent.recordingChanged"])
    }
    .task { await task() }
    .onDisappear { player.stop() }
  }

  private func task() async {
    try? player.play(url: MacTestMedia.demo)
    for await event in player.events {
      if case .recordingChanged(let recording, let filePath) = event {
        isRecording = recording
        outputPath = filePath ?? outputPath
      }
    }
  }

  private func recordingButtonTapped() {
    if isRecording {
      player.stopRecording()
    } else {
      player.startRecording(to: FileManager.default.temporaryDirectory.path)
    }
  }
}
