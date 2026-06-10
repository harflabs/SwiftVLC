import SwiftUI
import SwiftVLC

private let readMe = """
Engine smoke for one stream class: start latency (`play()` call to the \
first `.playing` state), output and track topology, buffering, live \
statistics, and a lenient mid-stream seek probe. Use the reload button \
to re-measure latency. Record anything that looks off for this stream \
class — missing tracks, zero bitrates, a failed seek probe — in the \
result note.
"""

struct SmokeScreen: View {
  let title: String
  let streamKey: HarnessStreams.Key
  let url: URL

  @State private var player = Player()
  @State private var playStart: ContinuousClock.Instant?
  @State private var startLatency: Duration?
  @State private var log: [LogLine] = []

  private struct LogLine: Identifiable {
    let id = UUID()
    let text: String
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

      Section("Start latency") {
        LabeledContent(
          "play() → first .playing",
          value: startLatency.map { "\($0.milliseconds) ms" } ?? "measuring…"
        )
        Button("Reload & re-measure") { startPlayback() }
      }

      Section("Output") {
        LabeledContent(
          "videoSize",
          value: player.videoSize.map { "\(Int($0.width))×\(Int($0.height))" } ?? "none"
        )
        LabeledContent("hasVideoOutput", value: player.hasVideoOutput ? "yes" : "no")
        LabeledContent("activeVideoOutputs", value: "\(player.activeVideoOutputs)")
      }

      Section("Timeline") {
        LabeledContent("currentTime", value: player.currentTime.formatted)
        LabeledContent("duration", value: player.duration?.formatted ?? "unknown")
        LabeledContent("isSeekable", value: player.isSeekable ? "yes" : "no")
        LabeledContent("bufferFill", value: String(format: "%.0f%%", player.bufferFill * 100))
      }

      tracksSection

      statisticsSection

      Section("Seek probe") {
        Button("seek(toPosition: 0.5)") {
          let accepted = player.seek(toPosition: 0.5)
          append("seek(toPosition: 0.5) → \(accepted)")
        }
      }

      logSection

      ResultRecorderSection(screenID: "smoke-\(streamKey.rawValue)")
    }
    .showcaseFormStyle()
    .navigationTitle("Smoke: \(title)")
    .task {
      startPlayback()
      await observeEvents()
    }
    .onDisappear { player.stop() }
  }

  private var tracksSection: some View {
    Section("Tracks") {
      LabeledContent("Audio", value: "\(player.audioTracks.count)")
      LabeledContent("Video", value: "\(player.videoTracks.count)")
      LabeledContent("Subtitle", value: "\(player.subtitleTracks.count)")
      ForEach(player.videoTracks + player.audioTracks + player.subtitleTracks) { track in
        VStack(alignment: .leading, spacing: 2) {
          Text("\(track.type) — \(track.name)")
          Text(trackDetail(for: track))
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
        }
      }
    }
  }

  @ViewBuilder
  private var statisticsSection: some View {
    if let stats = player.statistics {
      Section("Statistics") {
        LabeledContent("Input bitrate", value: String(format: "%.2f", stats.inputBitrate))
        LabeledContent("Demux bitrate", value: String(format: "%.2f", stats.demuxBitrate))
        LabeledContent("Demux corrupted", value: "\(stats.demuxCorrupted)")
        LabeledContent("Demux discontinuity", value: "\(stats.demuxDiscontinuity)")
        LabeledContent("Decoded video", value: "\(stats.decodedVideo)")
        LabeledContent("Late pictures", value: "\(stats.latePictures)")
        LabeledContent("Lost pictures", value: "\(stats.lostPictures)")
        LabeledContent("Decoded audio", value: "\(stats.decodedAudio)")
        LabeledContent("Lost audio buffers", value: "\(stats.lostAudioBuffers)")
      }
    } else {
      Section("Statistics") {
        Text("Waiting for statistics…")
          .foregroundStyle(.secondary)
      }
    }
  }

  private var logSection: some View {
    Section {
      if log.isEmpty {
        Text("Waiting…")
          .foregroundStyle(.secondary)
      } else {
        ForEach(log) { entry in
          Text(entry.text)
            .font(.caption.monospaced())
        }
      }
    } header: {
      Text("Event log")
    } footer: {
      if !log.isEmpty {
        Button("Clear log") { log.removeAll() }
      }
    }
  }

  private func startPlayback() {
    startLatency = nil
    playStart = .now
    append("play() → \(streamKey.rawValue)")
    do {
      try player.play(url: url)
    } catch {
      append("play() threw: \(error)")
    }
  }

  private func trackDetail(for track: Track) -> String {
    var parts = ["codec \(fourCC(track.codec))"]
    if let language = track.language, !language.isEmpty {
      parts.append(language)
    }
    if let width = track.width, let height = track.height {
      parts.append("\(width)×\(height)")
    }
    if let channels = track.channels, let sampleRate = track.sampleRate {
      parts.append("\(channels)ch \(sampleRate)Hz")
    }
    if track.bitrate > 0 {
      parts.append("\(track.bitrate) b/s")
    }
    return parts.joined(separator: ", ")
  }

  private func fourCC(_ codec: Int) -> String {
    let value = UInt32(truncatingIfNeeded: codec)
    let characters = (0..<4).map { index -> Character in
      let byte = UInt8((value >> (8 * index)) & 0xFF)
      guard byte >= 0x20, byte < 0x7F else { return "?" }
      return Character(Unicode.Scalar(byte))
    }
    return String(characters)
  }

  private func observeEvents() async {
    for await event in player.events {
      switch event {
      case .timeChanged, .positionChanged, .bufferingProgress:
        continue
      case .stateChanged(let state):
        if state == .playing, startLatency == nil, let playStart {
          let latency = playStart.duration(to: .now)
          startLatency = latency
          append("first .playing after \(latency.milliseconds) ms")
        }
        append("state → \(state)")
      default:
        append("\(event)")
      }
    }
  }

  private func append(_ text: String) {
    let timestamp = Date.now.formatted(
      .dateTime.hour().minute().second().secondFraction(.fractional(2))
    )
    log.insert(LogLine(text: "\(timestamp)  \(text)"), at: 0)
    if log.count > 200 {
      log.removeLast()
    }
  }
}
