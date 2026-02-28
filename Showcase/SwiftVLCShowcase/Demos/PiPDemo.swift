#if os(iOS) || os(macOS)
import SwiftUI
import SwiftVLC

/// Demonstrates Picture-in-Picture using PiPVideoView and PiPController.
/// PiP uses the vmem rendering path (AVSampleBufferDisplayLayer),
/// which is separate from VideoView's set_nsobject path.
struct PiPDemo: View {
  @State private var player: Player?
  @State private var pipController: PiPController?
  @State private var error: Error?

  #if os(iOS)
  @Environment(\.scenePhase) private var scenePhase
  #endif

  var body: some View {
    List {
      if error != nil {
        ContentUnavailableView(
          "Playback Failed",
          systemImage: "exclamationmark.triangle",
          description: Text("Could not set up the PiP player.")
        )
      } else if let player {
        // Video
        Section {
          PiPVideoView(player, controller: $pipController)
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(.rect(cornerRadius: 12))
            .clipped()
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        }

        // Playback
        Section {
          PlayerStatusBar(player: player)
          SeekBar(player: player)
          TransportControls(player: player)
            .frame(maxWidth: .infinity)
        }

        // PiP Controls
        Section {
          Button {
            pipController?.toggle()
          } label: {
            Label(
              pipController?.isActive == true ? "Exit PiP" : "Enter PiP",
              systemImage: pipController?.isActive == true ? "pip.exit" : "pip.enter"
            )
          }
          .disabled(pipController?.isPossible != true)
          .frame(maxWidth: .infinity)
        }

        // PiP State
        Section("PiP State") {
          LabeledContent("Possible") {
            Image(
              systemName: pipController?.isPossible == true
                ? "checkmark.circle.fill" : "xmark.circle"
            )
            .foregroundStyle(pipController?.isPossible == true ? .green : .secondary)
          }
          LabeledContent("Active") {
            Image(
              systemName: pipController?.isActive == true
                ? "checkmark.circle.fill" : "xmark.circle"
            )
            .foregroundStyle(pipController?.isActive == true ? .green : .secondary)
          }
        }
      } else {
        ProgressView("Loading player...")
          .frame(maxWidth: .infinity)
          .frame(height: 200)
          .listRowBackground(Color.clear)
      }
    }
    #if os(iOS)
    .listStyle(.insetGrouped)
    #endif
    .navigationTitle("Picture in Picture")
    #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
    #endif
      .task {
        do {
          let p = try Player()
          player = p
          try p.play(url: TestMedia.bigBuckBunny)
        } catch {
          self.error = error
        }
      }
      .onDisappear {
        player?.stop()
      }
    #if os(iOS)
      .onChange(of: scenePhase) { _, phase in
        if phase == .background, pipController?.isPossible == true {
          pipController?.start()
        }
      }
    #endif
  }
}
#endif
