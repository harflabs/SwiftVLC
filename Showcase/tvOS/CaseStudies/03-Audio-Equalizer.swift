import SwiftUI
import SwiftVLC

struct TVEqualizerCase: View {
  @State private var player = Player()
  @State private var equalizer = Equalizer()
  @State private var preset = 0

  var body: some View {
    TVShowcaseContent(
      title: "Equalizer",
      summary: "Attach an Observable Equalizer to Player and tweak preamp, presets, and bands live.",
      usage: "Choose a preset or adjust preamp and bands while audio plays to hear the Equalizer update through Player."
    ) {
      VStack(spacing: 16) {
        TVVideoPanel(player: player)
        TVPlaybackControls(player: player, showsVolume: false)
        controls
      }
    } sidebar: {
      TVSection(title: "Current", isFocusable: true) {
        TVMetricGrid {
          TVMetricRow(title: "Preset", value: Equalizer.presetName(at: preset) ?? "--")
          TVMetricRow(title: "Preamp", value: String(format: "%+.1f dB", equalizer.preamp))
          TVMetricRow(title: "Bands", value: "\(Equalizer.bandCount)")
        }
      }
      TVLibrarySurface(symbols: ["Equalizer()", "Equalizer(preset:)", "player.equalizer"])
    }
    .task { task() }
    .onDisappear { player.stop() }
  }

  private var controls: some View {
    TVEqualizerControls(
      equalizer: equalizer,
      preset: $preset,
      presetButtonTapped: presetButtonTapped
    )
  }

  private func task() {
    try? player.play(url: TVTestMedia.demo)
    player.equalizer = equalizer
  }

  private func presetButtonTapped() {
    guard let presetEqualizer = Equalizer(preset: preset) else { return }
    equalizer = presetEqualizer
    player.equalizer = equalizer
  }
}

private struct TVEqualizerControls: View {
  let equalizer: Equalizer
  @Binding var preset: Int
  let presetButtonTapped: () -> Void

  var body: some View {
    TVSection(title: "Equalizer") {
      Text("Preset")
        .font(.headline)

      TVChoiceGrid {
        ForEach(0..<Equalizer.presetCount, id: \.self) { index in
          TVChoiceButton(
            title: Equalizer.presetName(at: index) ?? "Preset \(index + 1)",
            isSelected: preset == index
          ) {
            preset = index
            presetButtonTapped()
          }
        }
      }

      TVSlider(
        "Preamp",
        value: Binding(
          get: { equalizer.preamp },
          set: { equalizer.preampGain = EqualizerGain($0) }
        ),
        in: -20...20,
        step: 0.5
      ) { String(format: "%+.1f dB", $0) }

      VStack(spacing: 8) {
        ForEach(0..<Equalizer.bandCount, id: \.self) { band in
          bandSlider(
            value: bandBinding(band),
            label: frequencyLabel(for: band),
            currentValue: bandValue(band)
          )
        }
      }
      .controlSize(.small)
    }
  }

  private func frequencyLabel(for band: Int) -> String {
    guard let frequency = Equalizer.bandFrequency(at: band) else { return "B\(band + 1)" }
    return frequency >= 1000
      ? String(format: "%.0fk", frequency / 1000)
      : String(format: "%.0f", frequency)
  }

  private func bandValue(_ band: Int) -> Float {
    equalizer.amplification(forBand: band) ?? 0
  }

  private func bandBinding(_ band: Int) -> Binding<Float> {
    Binding(
      get: { bandValue(band) },
      set: { try? equalizer.setAmplification($0, forBand: band) }
    )
  }

  private func bandSlider(
    value: Binding<Float>,
    label: String,
    currentValue: Float
  ) -> some View {
    TVSlider(
      label,
      value: value,
      in: -20...20,
      step: 0.5
    ) { String(format: "%+.1f", $0) }
      .accessibilityLabel("\(label) Hz")
      .accessibilityValue(String(format: "%+.1f dB", Double(currentValue)))
  }
}
