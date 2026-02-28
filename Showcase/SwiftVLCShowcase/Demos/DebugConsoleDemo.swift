#if os(iOS) || os(macOS)
import SwiftUI
import SwiftVLC

/// Developer-facing diagnostics: real-time log viewer with level filtering,
/// live playback statistics, and player state inspection.
struct DebugConsoleDemo: View {
  @State private var player: Player?
  @State private var logEntries: [TimestampedLog] = []
  @State private var minimumLevel: LogLevel = .notice
  @State private var logTask: Task<Void, Never>?
  @State private var error: Error?

  var body: some View {
    List {
      if error != nil {
        ContentUnavailableView(
          "Player Failed",
          systemImage: "exclamationmark.triangle",
          description: Text("Could not create the debug player.")
        )
      } else if let player {
        // Video — use a fixed-height container with clipping to prevent
        // the platform view (UIView/NSView) from bleeding over content.
        Section {
          VideoView(player)
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(.rect(cornerRadius: 12))
            .clipped()
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        }

        Section("Player State") {
          LabeledContent("State", value: stateLabel(player.state))
          LabeledContent("Time") {
            Text("\(player.currentTime.formatted) / \(player.duration.formatted)")
              .monospacedDigit()
              .contentTransition(.numericText())
          }
          LabeledContent("libVLC", value: VLCInstance.shared.version)
        }

        Section("Statistics") {
          if let stats = player.statistics {
            LabeledContent("Input bitrate") {
              Text(formatBitrate(stats.inputBitrate))
                .monospacedDigit()
                .contentTransition(.numericText())
            }
            LabeledContent("Decoded video") {
              Text("\(stats.decodedVideo) frames")
                .monospacedDigit()
                .contentTransition(.numericText())
            }
            LabeledContent("Displayed") {
              Text("\(stats.displayedPictures)")
                .monospacedDigit()
                .contentTransition(.numericText())
            }
            LabeledContent("Late pictures") {
              Text("\(stats.latePictures)")
                .monospacedDigit()
                .contentTransition(.numericText())
                .foregroundStyle(stats.latePictures > 0 ? .yellow : .primary)
            }
            LabeledContent("Lost pictures") {
              Text("\(stats.lostPictures)")
                .monospacedDigit()
                .contentTransition(.numericText())
                .foregroundStyle(stats.lostPictures > 0 ? .red : .primary)
            }
            LabeledContent("Decoded audio") {
              Text("\(stats.decodedAudio)")
                .monospacedDigit()
                .contentTransition(.numericText())
            }
            LabeledContent("Lost audio") {
              Text("\(stats.lostAudioBuffers)")
                .monospacedDigit()
                .contentTransition(.numericText())
                .foregroundStyle(stats.lostAudioBuffers > 0 ? .red : .primary)
            }
          } else {
            Text("Waiting for statistics...")
              .foregroundStyle(.tertiary)
          }
        }
      } else {
        ProgressView("Loading player...")
          .frame(maxWidth: .infinity)
          .frame(height: 120)
          .listRowBackground(Color.clear)
      }

      logSection
    }
    #if os(iOS)
    .listStyle(.insetGrouped)
    #endif
    .navigationTitle("Debug Console")
    #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
    #endif
      .task {
        do {
          let p = try Player()
          player = p
          startLogStream()
          try p.play(url: TestMedia.bigBuckBunny)
        } catch {
          self.error = error
        }
      }
      .onDisappear {
        logTask?.cancel()
        player?.stop()
      }
  }

  // MARK: - Logs

  private var logSection: some View {
    Section {
      HStack {
        Picker("Level", selection: $minimumLevel) {
          Text("Debug").tag(LogLevel.debug)
          Text("Notice").tag(LogLevel.notice)
          Text("Warning").tag(LogLevel.warning)
          Text("Error").tag(LogLevel.error)
        }
        .labelsHidden()
        #if os(iOS)
          .pickerStyle(.menu)
        #endif
          .onChange(of: minimumLevel) { _, _ in
            logEntries.removeAll()
            startLogStream()
          }

        Spacer()

        Button("Clear") {
          logEntries.removeAll()
        }
        .buttonStyle(.bordered)
      }

      ForEach(filteredEntries) { entry in
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text("[\(entry.entry.level.description)]")
            .foregroundStyle(levelColor(entry.entry.level))
            .font(.caption2)
            .frame(width: 60, alignment: .leading)
          if let module = entry.entry.module {
            Text(module)
              .foregroundStyle(.tertiary)
              .font(.caption2)
              .frame(width: 60, alignment: .leading)
          }
          Text(entry.entry.message)
            .font(.caption2)
            .lineLimit(2)
        }
      }
    } header: {
      Text("Logs")
    }
  }

  private var filteredEntries: [TimestampedLog] {
    Array(logEntries.suffix(200))
  }

  private func startLogStream() {
    logTask?.cancel()
    logTask = Task {
      for await entry in VLCInstance.shared.logStream(minimumLevel: minimumLevel) {
        guard !Task.isCancelled else { break }
        logEntries.append(TimestampedLog(entry: entry))
        // Keep buffer reasonable
        if logEntries.count > 500 {
          logEntries.removeFirst(100)
        }
      }
    }
  }

  // MARK: - Helpers

  private func stateLabel(_ state: PlayerState) -> String {
    switch state {
    case .idle: "Idle"
    case .opening: "Opening"
    case .buffering(let pct): "Buffering \(Int(pct * 100))%"
    case .playing: "Playing"
    case .paused: "Paused"
    case .stopped: "Stopped"
    case .stopping: "Stopping"
    case .error: "Error"
    }
  }

  private func formatBitrate(_ bitrate: Float) -> String {
    if bitrate > 1_000_000 {
      return String(format: "%.1f Mbps", bitrate / 1_000_000)
    } else if bitrate > 1000 {
      return String(format: "%.1f kbps", bitrate / 1000)
    }
    return String(format: "%.0f bps", bitrate)
  }

  private func levelColor(_ level: LogLevel) -> Color {
    switch level {
    case .debug: .secondary
    case .notice: .primary
    case .warning: .yellow
    case .error: .red
    }
  }
}

private struct TimestampedLog: Identifiable {
  let id = UUID()
  let entry: LogEntry
}
#endif
