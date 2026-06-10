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

  private var screenCAvailable: Bool {
    !(streams?.configured.isEmpty ?? true)
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
        missing are disabled.
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

      placeholderRow("(b) Auto-PiP trigger conditions")

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

      placeholderRow("(d) Cast-start while PiP")
      placeholderRow("(e) Background audio without PiP")
      placeholderRow("(f) set_position/jump_time on catch-up")
      placeholderRow("(g) --freetype-fontsize survival")
    }
  }

  private var smokeSection: some View {
    Section("Engine smoke") {
      placeholderRow("Live TS")
      placeholderRow("HLS live")
      placeholderRow("VOD")
      placeholderRow("Catch-up")
    }
  }

  private func placeholderRow(_ title: String) -> some View {
    unavailableRow(title, detail: "Not built yet")
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
