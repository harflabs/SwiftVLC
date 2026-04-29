import SwiftUI
import SwiftVLC

struct TVVideoAdjustmentsCase: View {
  @State private var player = Player()
  @State private var isEnabled = false
  @State private var brightness: Float = 1
  @State private var contrast: Float = 1
  @State private var hue: Float = 0
  @State private var saturation: Float = 1
  @State private var gamma: Float = 1

  var body: some View {
    TVShowcaseContent(
      title: "Adjustments",
      summary: "Apply brightness, contrast, hue, saturation, and gamma with scoped access to VideoAdjustments.",
      usage: "Enable adjustments, then tune brightness, contrast, saturation, hue, and gamma while watching the video surface."
    ) {
      VStack(spacing: 16) {
        TVVideoPanel(player: player)
        TVPlaybackControls(player: player, showsVolume: false)
        TVSection(title: "Color") {
          Toggle("Enabled", isOn: $isEnabled)
          sliderRow("Brightness", value: $brightness, range: 0...2)
          sliderRow("Contrast", value: $contrast, range: 0...2)
          sliderRow("Hue", value: $hue, range: 0...360)
          sliderRow("Saturation", value: $saturation, range: 0...3)
          sliderRow("Gamma", value: $gamma, range: 0.1...10)
        }
      }
    } sidebar: {
      TVSection(title: "Current", isFocusable: true) {
        TVMetricGrid {
          TVMetricRow(title: "Enabled", value: isEnabled ? "Yes" : "No")
          TVMetricRow(title: "Brightness", value: String(format: "%.2f", brightness))
          TVMetricRow(title: "Contrast", value: String(format: "%.2f", contrast))
          TVMetricRow(title: "Saturation", value: String(format: "%.2f", saturation))
        }
      }
      TVLibrarySurface(symbols: ["player.withAdjustments { ... }", "VideoAdjustments"])
    }
    .task { task() }
    .onChange(of: isEnabled) { applyAdjustments() }
    .onChange(of: brightness) { applyAdjustments() }
    .onChange(of: contrast) { applyAdjustments() }
    .onChange(of: hue) { applyAdjustments() }
    .onChange(of: saturation) { applyAdjustments() }
    .onChange(of: gamma) { applyAdjustments() }
    .onDisappear { player.stop() }
  }

  private func task() {
    try? player.play(url: TVTestMedia.demo)
    applyAdjustments()
  }

  private func applyAdjustments() {
    player.withAdjustments { adjustments in
      adjustments.isEnabled = isEnabled
      adjustments.brightness = brightness
      adjustments.contrast = contrast
      adjustments.hue = hue
      adjustments.saturation = saturation
      adjustments.gamma = gamma
    }
  }

  private func sliderRow(_ title: String, value: Binding<Float>, range: ClosedRange<Float>) -> some View {
    TVSlider(
      title,
      value: value,
      in: range,
      step: 0.05
    ) { String(format: "%.2f", $0) }
  }
}
