import SwiftUI
import SwiftVLC

private let readMe = """
Attach an `Equalizer` to the player and adjust preamp and 10 frequency bands in dB. \
Choose a libVLC preset or dial bands manually.
"""

struct EqualizerCase: View {
  @State private var player = Player()
  @State private var equalizer = Equalizer()
  @State private var preset = 0

  var body: some View {
    Form {
      Section { AboutView(readMe: readMe) }

      Section {
        VideoView(player)
          .aspectRatio(16 / 9, contentMode: .fit)
          .listRowInsets(EdgeInsets())
          .accessibilityIdentifier(AccessibilityID.Equalizer.videoView)
      } footer: {
        PlayPauseFooter(player: player)
          .accessibilityIdentifier(AccessibilityID.Equalizer.playPauseButton)
      }

      Section("Preset") {
        Picker("Preset", selection: $preset) {
          ForEach(Array(Equalizer.presetNames.enumerated()), id: \.offset) { offset, name in
            Text(name).tag(offset)
          }
        }
        .accessibilityIdentifier(AccessibilityID.Equalizer.presetPicker)
        .onChange(of: preset) { _, new in
          equalizer = Equalizer(preset: new)
          player.equalizer = equalizer
        }
      }

      Section("Preamp") {
        CompatSlider(
          value: Binding(
            get: { equalizer.preamp },
            set: { equalizer.preamp = $0; player.equalizer = equalizer }
          ),
          range: -20...20, step: 0.5
        )
        .accessibilityIdentifier(AccessibilityID.Equalizer.preampSlider)
        HStack {
          Text("Gain")
          Spacer()
          Text(String(format: "%+.1f dB", equalizer.preamp))
            .foregroundStyle(.secondary)
            .accessibilityIdentifier(AccessibilityID.Equalizer.preampGainLabel)
        }
      }

      Section("Bands") {
        ForEach(0..<Equalizer.bandCount, id: \.self) { band in
          VStack(alignment: .leading) {
            LabeledContent(frequencyLabel(band)) {
              Text(String(format: "%+.1f dB", equalizer.amplification(forBand: band)))
                .monospacedDigit()
            }
            CompatSlider(
              value: Binding(
                get: { equalizer.amplification(forBand: band) },
                set: {
                  try? equalizer.setAmplification($0, forBand: band)
                  player.equalizer = equalizer
                }
              ),
              range: -20...20, step: 0.5
            )
          }
        }
      }
    }
    .showcaseFormStyle()
    .navigationTitle("Equalizer")
    .task {
      try? player.play(url: TestMedia.bigBuckBunny)
      player.equalizer = equalizer
    }
    .onDisappear { player.stop() }
  }

  private func frequencyLabel(_ band: Int) -> String {
    let frequency = Equalizer.bandFrequency(at: band)
    return frequency >= 1000
      ? String(format: "%.1f kHz", frequency / 1000)
      : "\(Int(frequency)) Hz"
  }
}
