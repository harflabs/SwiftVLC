import SwiftUI
import SwiftVLC

struct TVChaptersCase: View {
  @State private var player = Player()

  var body: some View {
    let chapters = player.chapters(forTitle: -1)

    TVShowcaseContent(
      title: "Chapters",
      summary: "Inspect chapter descriptions and bind the current chapter to native navigation controls.",
      usage: "Use chapter navigation controls to move between discovered chapters and watch currentChapter and time update."
    ) {
      VStack(spacing: 16) {
        TVVideoPanel(player: player)
        TVPlaybackControls(player: player, showsVolume: false)
        TVSection(title: "Chapters", isFocusable: chapters.isEmpty) {
          if chapters.isEmpty {
            TVPlaceholderRow(text: "No chapters in this media yet.")
          } else {
            TVChoiceGrid {
              ForEach(chapters) { chapter in
                TVChoiceButton(
                  title: chapter.name ?? "Chapter \(chapter.index + 1)",
                  subtitle: "Chapter \(chapter.index + 1)",
                  isSelected: player.currentChapter == chapter.index
                ) {
                  player.currentChapter = chapter.index
                }
              }
            }

            TVControlGrid {
              Button("Previous", systemImage: "backward.fill") { player.previousChapter() }
              Button("Next", systemImage: "forward.fill") { player.nextChapter() }
            }
          }
        }
      }
    } sidebar: {
      TVSection(title: "Current", isFocusable: true) {
        TVMetricGrid {
          TVMetricRow(title: "Count", value: "\(chapters.count)")
          TVMetricRow(title: "Current", value: "\(max(player.currentChapter + 1, 0))")
          TVMetricRow(title: "Time", value: durationLabel(player.currentTime))
        }
      }
      TVLibrarySurface(symbols: ["player.chapters(forTitle:)", "player.currentChapter", "player.nextChapter()"])
    }
    .task { try? player.play(url: TVTestMedia.demo) }
    .onDisappear { player.stop() }
  }
}
