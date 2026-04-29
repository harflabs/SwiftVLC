import SwiftUI
import SwiftVLC

struct MacEqualizerCase: View {
  @State private var player = Player()
  @State private var equalizer = Equalizer()
  @State private var preset = 0

  var body: some View {
    MacShowcaseContent(
      title: "Equalizer",
      summary: "Attach an Observable Equalizer to Player and tweak preamp, presets, and bands live.",
      usage: "Choose a preset or adjust preamp and bands while audio plays to hear the Equalizer update through Player."
    ) {
      VStack(spacing: 16) {
        MacVideoPanel(player: player)
        MacPlaybackControls(player: player, showsVolume: false)
        controls
      }
    } sidebar: {
      MacSection(title: "Current") {
        MacMetricGrid {
          MacMetricRow(title: "Preset", value: Equalizer.presetName(at: preset) ?? "--")
          MacMetricRow(title: "Preamp", value: String(format: "%+.1f dB", equalizer.preamp))
          MacMetricRow(title: "Bands", value: "\(Equalizer.bandCount)")
        }
      }
      MacLibrarySurface(symbols: ["Equalizer()", "Equalizer(preset:)", "player.equalizer"])
    }
    .task { task() }
    .onDisappear { player.stop() }
  }

  private var controls: some View {
    MacEqualizerControls(
      equalizer: equalizer,
      preset: $preset,
      presetPickerChanged: presetPickerChanged
    )
  }

  private func task() {
    try? player.play(url: MacTestMedia.demo)
    player.equalizer = equalizer
  }

  private func presetPickerChanged() {
    equalizer = Equalizer(preset: preset)
    player.equalizer = equalizer
  }
}

private struct MacEqualizerControls: View {
  @Bindable var equalizer: Equalizer
  @Binding var preset: Int
  let presetPickerChanged: () -> Void

  var body: some View {
    MacSection(title: "Equalizer") {
      Picker("Preset", selection: $preset) {
        ForEach(0..<Equalizer.presetCount, id: \.self) { index in
          Text(Equalizer.presetName(at: index) ?? "Preset \(index + 1)").tag(index)
        }
      }
      .onChange(of: preset) { presetPickerChanged() }

      HStack(spacing: 8) {
        Text("Preamp")
        Slider(value: $equalizer.preamp, in: -20...20, step: 0.5)
        Text(String(format: "%+.1f dB", equalizer.preamp))
          .font(.callout.monospacedDigit())
          .foregroundStyle(.secondary)
          .frame(width: 70, alignment: .trailing)
      }

      VStack(spacing: 8) {
        ForEach(0..<Equalizer.bandCount, id: \.self) { band in
          bandSlider(
            value: $equalizer.bands[band],
            label: frequencyLabel(for: band),
            currentValue: equalizer.bands[band]
          )
        }
      }
      .controlSize(.small)
    }
  }

  private func frequencyLabel(for band: Int) -> String {
    let frequency = Equalizer.bandFrequency(at: band)
    return frequency >= 1000
      ? String(format: "%.0fk", frequency / 1000)
      : String(format: "%.0f", frequency)
  }

  private func bandSlider(
    value: Binding<Float>,
    label: String,
    currentValue: Float
  ) -> some View {
    HStack(spacing: 8) {
      Text(label)
        .frame(width: 44, alignment: .leading)
      Slider(value: value, in: -20...20, step: 0.5)
      Text(String(format: "%+.1f", Double(currentValue)))
        .font(.callout.monospacedDigit())
        .foregroundStyle(.secondary)
        .frame(width: 48, alignment: .trailing)
    }
    .accessibilityLabel("\(label) Hz")
    .accessibilityValue(String(format: "%+.1f dB", Double(currentValue)))
  }
}
