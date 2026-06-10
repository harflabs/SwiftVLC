import SwiftUI

struct HarnessHome: View {
  @State private var config = HarnessStreams.load()

  private var streams: HarnessStreams? {
    config?.streams
  }

  private var screenAAvailable: Bool {
    guard let streams else { return false }
    let zappable = [streams.liveTS, streams.hlsLive, streams.vod].compactMap(\.self)
    return zappable.count >= 2
  }

  private var screenBAvailable: Bool {
    guard let streams else { return false }
    return streams.vod != nil || streams.hlsLive != nil
  }

  private var screenCAvailable: Bool {
    !(streams?.configured.isEmpty ?? true)
  }

  private var screenDAvailable: Bool {
    !(streams?.configured.isEmpty ?? true)
  }

  private var screenEAvailable: Bool {
    guard let streams else { return false }
    return streams.hlsLive != nil || streams.vod != nil || streams.audioOnly != nil
  }

  private var screenFAvailable: Bool {
    streams?.catchup != nil
  }

  private var screenGAvailable: Bool {
    streams?.subtitled != nil
  }

  var body: some View {
    Form {
      configurationSection
      matrixSection
      smokeSection
    }
    .showcaseFormStyle()
    .navigationTitle("Device Validation")
  }

  private var configurationSection: some View {
    Section {
      if let config {
        LabeledContent("Loaded from", value: config.source.label)
        let missing = config.streams.missingKeys
        if missing.isEmpty {
          LabeledContent("Streams", value: "all \(HarnessStreams.Key.allCases.count) configured")
        } else {
          VStack(alignment: .leading, spacing: 4) {
            Text("Missing keys")
            Text(missing.map(\.rawValue).joined(separator: ", "))
              .font(.caption.monospaced())
              .foregroundStyle(.secondary)
          }
        }
      } else {
        Text("No stream configuration found")
          .foregroundStyle(.red)
      }

      Button("Reload configuration") {
        config = HarnessStreams.load()
      }
    } header: {
      Text("Configuration")
    } footer: {
      Text(
        """
        Copy streams.local.example.json to streams.local.json in \
        Showcase/iOS/ValidationHarness/ before building (gitignored, \
        auto-bundled), or drop streams.local.json into this app's \
        Documents folder via the Files app. Screens whose streams are \
        missing are disabled. Launch the app with -UITestRoute \
        HarnessHome to open this screen directly (used for scripted \
        device runs).
        """
      )
    }
  }

  private var matrixSection: some View {
    Section("Matrix") {
      if let streams, screenAAvailable {
        NavigationLink("(a) PiP survival across load()") {
          MatrixScreenA(streams: streams)
        }
      } else {
        unavailableRow(
          "(a) PiP survival across load()",
          detail: "Needs at least two of liveTS, hlsLive, vod"
        )
      }

      if let streams, screenBAvailable {
        NavigationLink("(b) Auto-PiP trigger conditions") {
          MatrixScreenB(streams: streams)
        }
      } else {
        unavailableRow(
          "(b) Auto-PiP trigger conditions",
          detail: "Needs vod or hlsLive"
        )
      }

      if let streams, screenCAvailable {
        NavigationLink("(c) Restore/X baseline (no hook)") {
          MatrixScreenC(streams: streams)
        }
      } else {
        unavailableRow(
          "(c) Restore/X baseline (no hook)",
          detail: "Needs any one configured stream"
        )
      }

      if let streams, screenDAvailable {
        NavigationLink("(d) Cast-start while PiP + recast") {
          MatrixScreenD(streams: streams)
        }
      } else {
        unavailableRow(
          "(d) Cast-start while PiP + recast",
          detail: "Needs any one configured stream"
        )
      }

      if let streams, screenEAvailable {
        NavigationLink("(e) Background audio without PiP") {
          MatrixScreenE(streams: streams)
        }
      } else {
        unavailableRow(
          "(e) Background audio without PiP",
          detail: "Needs hlsLive, vod, or audioOnly"
        )
      }

      if let streams, screenFAvailable {
        NavigationLink("(f) set_position/jump_time on catch-up") {
          MatrixScreenF(streams: streams)
        }
      } else {
        unavailableRow(
          "(f) set_position/jump_time on catch-up",
          detail: "Needs catchup"
        )
      }

      if let streams, screenGAvailable {
        NavigationLink("(g) --freetype-fontsize survival") {
          MatrixScreenG(streams: streams)
        }
      } else {
        unavailableRow(
          "(g) --freetype-fontsize survival",
          detail: "Needs subtitled"
        )
      }
    }
  }

  private var smokeSection: some View {
    Section("Engine smoke") {
      smokeRow("Live TS", key: .liveTS)
      smokeRow("HLS live", key: .hlsLive)
      smokeRow("VOD", key: .vod)
      smokeRow("Catch-up", key: .catchup)
    }
  }

  @ViewBuilder
  private func smokeRow(_ title: String, key: HarnessStreams.Key) -> some View {
    if let url = streams?.url(for: key) {
      NavigationLink(title) {
        SmokeScreen(title: title, streamKey: key, url: url)
      }
    } else {
      unavailableRow(title, detail: "Needs \(key.rawValue)")
    }
  }

  private func unavailableRow(_ title: String, detail: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title)
      Text(detail)
        .font(.caption)
    }
    .foregroundStyle(.secondary)
  }
}
