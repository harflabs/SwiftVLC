import SwiftUI
import SwiftVLC

private let readMe = """
`startRecording(to:)` writes the live stream to disk. Observe \
`.recordingChanged(isRecording:filePath:)` in the event stream to learn where it lands.
"""

struct RecordingCase: View {
  @State private var player = Player()
  @State private var isRecording = false
  @State private var outputFile: String?

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

      Section {
        Button(
          isRecording ? "Stop recording" : "Start recording",
          systemImage: isRecording ? "stop.circle.fill" : "record.circle.fill",
          action: toggle
        )
        .tint(isRecording ? .red : .accentColor)
        .frame(maxWidth: .infinity)

        if let outputFile {
          LabeledContent(
            "Saved to",
            value: URL(fileURLWithPath: outputFile).lastPathComponent
          )
          .font(.caption)
        }
      }
    }
    .navigationTitle("Recording")
    .task {
      try? player.play(url: TestMedia.bigBuckBunny)
      for await event in player.events {
        if case .recordingChanged(let rec, let path) = event {
          isRecording = rec
          if let path { outputFile = path }
        }
      }
    }
    .onDisappear { player.stop() }
  }

  private func toggle() {
    if isRecording {
      player.stopRecording()
    } else {
      player.startRecording(to: FileManager.default.temporaryDirectory.path)
    }
  }
}
