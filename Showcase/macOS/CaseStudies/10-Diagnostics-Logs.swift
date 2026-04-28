import SwiftUI
import SwiftVLC

struct MacLogsCase: View {
  @State private var player = Player()
  @State private var entries: [LogLine] = []
  @State private var level: LogLevel = .warning

  private let levels: [LogLevel] = [.debug, .notice, .warning, .error]

  var body: some View {
    MacShowcaseContent(
      title: "Logs",
      summary: "Subscribe to libVLC's log stream and filter messages by minimum severity.",
      usage: "Pick a minimum severity and start playback to watch libVLC log messages stream into the log panel."
    ) {
      VStack(spacing: 16) {
        MacVideoPanel(player: player)
        MacPlaybackControls(player: player)
        MacSection(title: "Minimum Level") {
          Picker("Level", selection: $level) {
            ForEach(levels, id: \.self) { level in
              Text(level.description.capitalized).tag(level)
            }
          }
          .pickerStyle(.segmented)
        }
      }
    } sidebar: {
      MacSection(title: "Log") {
        if entries.isEmpty {
          MacPlaceholderRow(text: "Waiting for log messages...")
        } else {
          ForEach(entries) { entry in
            VStack(alignment: .leading, spacing: 2) {
              Text("[\(entry.value.level.description)] \(entry.value.module ?? "?")")
                .font(.caption2.monospaced())
                .foregroundStyle(color(for: entry.value.level))
              Text(entry.value.message)
                .font(.caption.monospaced())
                .lineLimit(3)
            }
          }
        }
      }
      MacLibrarySurface(symbols: ["VLCInstance.logStream(minimumLevel:)", "LogEntry", "LogLevel"])
    }
    .task { try? player.play(url: MacTestMedia.demo) }
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
