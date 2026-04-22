import SwiftUI
import SwiftVLC

private let readMe = """
Color adjustments live on `player.adjustments`: brightness, contrast, hue, saturation, \
gamma. Enable first — disabled adjustments pass through untouched.
"""

struct VideoAdjustmentsCase: View {
  @State private var player = Player()
  @State private var isEnabled = false
  @State private var brightness: Float = 1.0
  @State private var contrast: Float = 1.0
  @State private var hue: Float = 0
  @State private var saturation: Float = 1.0
  @State private var gamma: Float = 1.0

  var body: some View {
    Form {
      Section { AboutView(readMe: readMe) }

      Section {
        VideoView(player)
          .aspectRatio(16 / 9, contentMode: .fit)
          .listRowInsets(EdgeInsets())
          .accessibilityIdentifier(AccessibilityID.Adjustments.videoView)
      } footer: {
        PlayPauseFooter(player: player)
          .accessibilityIdentifier(AccessibilityID.Adjustments.playPauseButton)
      }

      Section("Adjustments") {
        Toggle("Enabled", isOn: $isEnabled)
          .accessibilityIdentifier(AccessibilityID.Adjustments.enabledToggle)
        row(
          "Brightness",
          value: $brightness,
          in: 0...2,
          identifier: AccessibilityID.Adjustments.brightnessSlider
        )
        row("Contrast", value: $contrast, in: 0...2, identifier: nil)
        row("Hue", value: $hue, in: 0...360, identifier: nil)
        row("Saturation", value: $saturation, in: 0...3, identifier: nil)
        row("Gamma", value: $gamma, in: 0.1...10, identifier: nil)
      }
    }
    .showcaseFormStyle()
    .navigationTitle("Adjustments")
    .task { task() }
    .onDisappear { player.stop() }
    .onChange(of: isEnabled) { player.withAdjustments { $0.isEnabled = isEnabled } }
    .onChange(of: brightness) { player.withAdjustments { $0.brightness = brightness } }
    .onChange(of: contrast) { player.withAdjustments { $0.contrast = contrast } }
    .onChange(of: hue) { player.withAdjustments { $0.hue = hue } }
    .onChange(of: saturation) { player.withAdjustments { $0.saturation = saturation } }
    .onChange(of: gamma) { player.withAdjustments { $0.gamma = gamma } }
  }

  private func task() {
    try? player.play(url: TestMedia.bigBuckBunny)
    // Push initial slider values before the user touches anything —
    // `onChange` doesn't fire for initial state.
    player.withAdjustments { adj in
      adj.brightness = brightness
      adj.contrast = contrast
      adj.hue = hue
      adj.saturation = saturation
      adj.gamma = gamma
      adj.isEnabled = isEnabled
    }
  }

  private func row(
    _ title: String,
    value: Binding<Float>,
    in range: ClosedRange<Float>,
    identifier: String?
  ) -> some View {
    VStack(alignment: .leading) {
      HStack {
        Text(title)
        Spacer()
        Text(String(format: "%.2f", value.wrappedValue))
          .foregroundStyle(.secondary)
      }
      CompatSlider(value: value, range: range, step: 0.05)
        .accessibilityIdentifier(ifPresent: identifier)
    }
  }
}
