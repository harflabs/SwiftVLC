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
      } footer: {
        PlayPauseFooter(player: player)
      }

      Section("Adjustments") {
        Toggle("Enabled", isOn: $isEnabled)
        row("Brightness", value: $brightness, in: 0...2)
        row("Contrast", value: $contrast, in: 0...2)
        row("Hue", value: $hue, in: 0...360)
        row("Saturation", value: $saturation, in: 0...3)
        row("Gamma", value: $gamma, in: 0.1...10)
      }
    }
    .navigationTitle("Adjustments")
    .task { try? player.play(url: TestMedia.bigBuckBunny) }
    .onDisappear { player.stop() }
    .onChange(of: isEnabled) { player.withAdjustments { $0.isEnabled = isEnabled } }
    .onChange(of: brightness) { player.withAdjustments { $0.brightness = brightness } }
    .onChange(of: contrast) { player.withAdjustments { $0.contrast = contrast } }
    .onChange(of: hue) { player.withAdjustments { $0.hue = hue } }
    .onChange(of: saturation) { player.withAdjustments { $0.saturation = saturation } }
    .onChange(of: gamma) { player.withAdjustments { $0.gamma = gamma } }
  }

  private func row(_ title: String, value: Binding<Float>, in range: ClosedRange<Float>) -> some View {
    VStack(alignment: .leading) {
      LabeledContent(title, value: String(format: "%.2f", value.wrappedValue))
      CompatSlider(value: value, range: range, step: 0.05)
    }
  }
}
