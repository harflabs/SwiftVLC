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
          .accessibilityIdentifier(AccessibilityID.Recording.videoView)
      } footer: {
        PlayPauseFooter(player: player)
          .accessibilityIdentifier(AccessibilityID.Recording.playPauseButton)
      }

      Section {
        Button(
          isRecording ? "Stop recording" : "Start recording",
          systemImage: isRecording ? "stop.circle.fill" : "record.circle.fill",
          action: toggle
        )
        .accessibilityIdentifier(AccessibilityID.Recording.toggleButton)
        .tint(isRecording ? .red : .accentColor)
        .frame(maxWidth: .infinity)

        if let outputFile {
          HStack {
            Text("Saved to")
            Spacer()
            Text(URL(fileURLWithPath: outputFile).lastPathComponent)
              .foregroundStyle(.secondary)
              .accessibilityIdentifier(AccessibilityID.Recording.savedToLabel)
          }
          .font(.caption)
        }
      }
    }
    .showcaseFormStyle()
    .navigationTitle("Recording")
    .task { await task() }
    .onDisappear { player.stop() }
  }

  private func task() async {
    try? player.play(url: TestMedia.demo)
    for await event in player.events {
      if case .recordingChanged(let rec, let path) = event {
        isRecording = rec
        if let path { outputFile = path }
      }
    }
  }

  private func toggle() {
    if isRecording {
      player.stopRecording()
    } else {
      player.startRecording(to: FileManager.default.temporaryDirectory.path)
    }
  }
}
