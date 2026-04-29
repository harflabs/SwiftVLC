import SwiftUI
import SwiftVLC

struct TVLogsCase: View {
  @State private var player = Player()
  @State private var entries: [LogLine] = []
  @State private var level: LogLevel = .warning

  private let levels: [LogLevel] = [.debug, .notice, .warning, .error]

  var body: some View {
    TVShowcaseContent(
      title: "Logs",
      summary: "Subscribe to libVLC's log stream and filter messages by minimum severity.",
      usage: "Pick a minimum severity and start playback to watch libVLC log messages stream into the log panel."
    ) {
      VStack(spacing: 16) {
        TVVideoPanel(player: player)
        TVPlaybackControls(player: player)
        TVSection(title: "Minimum Level") {
          TVChoiceGrid {
            ForEach(levels, id: \.self) { level in
              TVChoiceButton(
                title: level.description.capitalized,
                isSelected: self.level == level
              ) {
                self.level = level
              }
            }
          }
        }
      }
    } sidebar: {
      TVSection(title: "Log", isFocusable: true) {
        if entries.isEmpty {
          TVPlaceholderRow(text: "Waiting for log messages...")
        } else {
          ForEach(entries) { entry in
            VStack(alignment: .leading, spacing: 2) {
              Text("[\(entry.value.level.description)] \(entry.value.module ?? "?")")
                .font(.caption2.monospaced())
                .foregroundStyle(color(for: entry.value.level))
              Text(entry.value.message)
                .font(.caption.monospaced())
                .fixedSize(horizontal: false, vertical: true)
            }
          }
        }
      }
      TVLibrarySurface(symbols: ["VLCInstance.logStream(minimumLevel:)", "LogEntry", "LogLevel"])
    }
    .task { try? player.play(url: TVTestMedia.demo) }
    .task(id: level) { await levelTask() }
    .onDisappear { player.stop() }
  }

  private func levelTask() async {
    entries = []
    for await entry in VLCInstance.shared.logStream(minimumLevel: level) {
      entries.insert(LogLine(value: entry), at: 0)
      if entries.count > 80 {
        entries.removeLast()
      }
    }
  }

  private func color(for level: LogLevel) -> Color {
    switch level {
    case .debug: .secondary
    case .notice: .blue
    case .warning: .orange
    case .error: .red
    }
  }
}

private struct LogLine: Identifiable {
  let id = UUID()
  let value: LogEntry
}
