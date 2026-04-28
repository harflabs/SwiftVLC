import SwiftUI
import SwiftVLC

struct MacChaptersCase: View {
  @State private var player = Player()

  var body: some View {
    @Bindable var bindable = player
    let chapters = player.chapters(forTitle: -1)

    MacShowcaseContent(
      title: "Chapters",
      summary: "Inspect chapter descriptions and bind the current chapter to native navigation controls.",
      usage: "Use chapter navigation controls to move between discovered chapters and watch currentChapter and time update."
    ) {
      VStack(spacing: 16) {
        MacVideoPanel(player: player)
        MacPlaybackControls(player: player, showsVolume: false)
        MacSection(title: "Chapters") {
          if chapters.isEmpty {
            MacPlaceholderRow(text: "No chapters in this media yet.")
          } else {
            Picker("Chapter", selection: $bindable.currentChapter) {
              ForEach(chapters) { chapter in
                Text(chapter.name ?? "Chapter \(chapter.index + 1)").tag(chapter.index)
              }
            }
            HStack {
              Button("Previous", systemImage: "backward.fill") { player.previousChapter() }
              Button("Next", systemImage: "forward.fill") { player.nextChapter() }
            }
          }
        }
      }
    } sidebar: {
      MacSection(title: "Current") {
        MacMetricGrid {
          MacMetricRow(title: "Count", value: "\(chapters.count)")
          MacMetricRow(title: "Current", value: "\(max(player.currentChapter + 1, 0))")
          MacMetricRow(title: "Time", value: durationLabel(player.currentTime))
        }
      }
      MacLibrarySurface(symbols: ["player.chapters(forTitle:)", "player.currentChapter", "player.nextChapter()"])
    }
    .task { try? player.play(url: MacTestMedia.demo) }
    .onDisappear { player.stop() }
  }
}
