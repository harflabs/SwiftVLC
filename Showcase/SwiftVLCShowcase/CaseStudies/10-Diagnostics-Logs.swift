import SwiftUI
import SwiftVLC

private let readMe = """
`VLCInstance.shared.logStream(minimumLevel:)` exposes libVLC's internal log stream. \
Filter by level to control verbosity.
"""

struct LogsCase: View {
  @State private var player = Player()
  @State private var entries: [Entry] = []
  @State private var level: LogLevel = .warning

  private struct Entry: Identifiable {
    let id = UUID()
    let value: LogEntry
  }

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

      Section("Minimum level") {
        Picker("Level", selection: $level) {
          Text("Debug").tag(LogLevel.debug)
          Text("Notice").tag(LogLevel.notice)
          Text("Warning").tag(LogLevel.warning)
          Text("Error").tag(LogLevel.error)
        }
        .pickerStyle(.segmented)
      }

      Section("Log") {
        if entries.isEmpty {
          Text("Waiting…").foregroundStyle(.secondary)
        } else {
          ForEach(entries) { entry in
            VStack(alignment: .leading, spacing: 2) {
              Text("[\(levelText(entry.value.level))] \(entry.value.module ?? "?")")
                .font(.caption2.monospaced())
                .foregroundStyle(color(for: entry.value.level))
              Text(entry.value.message)
                .font(.caption.monospaced())
            }
          }
        }
      }
    }
    .showcaseFormStyle()
    .navigationTitle("Logs")
    .task { try? player.play(url: TestMedia.bigBuckBunny) }
    .task(id: level) {
      entries.removeAll()
      for await entry in VLCInstance.shared.logStream(minimumLevel: level) {
        entries.insert(Entry(value: entry), at: 0)
        if entries.count > 100 { entries.removeLast() }
      }
    }
    .onDisappear { player.stop() }
  }

  private func levelText(_ level: LogLevel) -> String {
    switch level {
    case .debug: "D"
    case .notice: "N"
    case .warning: "W"
    case .error: "E"
    }
  }

  private func color(for level: LogLevel) -> Color {
    switch level {
    case .error: .red
    case .warning: .orange
    case .notice: .blue
    case .debug: .secondary
    }
  }
}
