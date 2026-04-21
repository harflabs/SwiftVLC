import SwiftUI
import SwiftVLC

private let readMe = """
`chapters(forTitle:)` returns chapters for the current or specified title. Bind \
`currentChapter` to a `Picker`, or step with `nextChapter()` / `previousChapter()`.
"""

struct ChaptersCase: View {
  @State private var player = Player()

  var body: some View {
    @Bindable var bindable = player

    Form {
      Section { AboutView(readMe: readMe) }

      Section {
        VideoView(player)
          .aspectRatio(16 / 9, contentMode: .fit)
          .listRowInsets(EdgeInsets())
          .accessibilityIdentifier(AccessibilityID.Chapters.videoView)
      } footer: {
        PlayPauseFooter(player: player)
          .accessibilityIdentifier(AccessibilityID.Chapters.playPauseButton)
      }

      Section("Chapters") {
        let chapters = player.chapters(forTitle: -1)
        if chapters.isEmpty {
          Text("No chapters in this media")
            .foregroundStyle(.secondary)
            .accessibilityIdentifier(AccessibilityID.Chapters.emptyLabel)
        } else {
          Picker("Chapter", selection: $bindable.currentChapter) {
            ForEach(chapters) { chapter in
              Text(chapter.name ?? "Chapter \(chapter.index + 1)").tag(chapter.index)
            }
          }
          .accessibilityIdentifier(AccessibilityID.Chapters.picker)
          HStack {
            Button("Previous", systemImage: "backward.fill") { player.previousChapter() }
              .accessibilityIdentifier(AccessibilityID.Chapters.previousButton)
            Spacer()
            Button("Next", systemImage: "forward.fill") { player.nextChapter() }
              .accessibilityIdentifier(AccessibilityID.Chapters.nextButton)
          }
          // Form rows with multiple buttons need explicit hit targets.
          .buttonStyle(.borderless)
        }
      }
    }
    .showcaseFormStyle()
    .navigationTitle("Chapters")
    .task { try? player.play(url: TestMedia.bigBuckBunny) }
    .onDisappear { player.stop() }
  }
}
