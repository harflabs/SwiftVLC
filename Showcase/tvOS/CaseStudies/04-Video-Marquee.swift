import SwiftUI
import SwiftVLC

struct TVMarqueeCase: View {
  @State private var player = Player()
  @State private var isEnabled = true
  @State private var text = "SwiftVLC"
  @State private var color: MarqueeColor = .white
  @State private var anchor: MarqueeAnchor = .bottomRight
  @State private var opacity: Double = 255
  @State private var fontSize: Double = 28
  @State private var x: Double = 24
  @State private var y: Double = 24

  private let messagePresets = ["SwiftVLC", "Now Playing", "Live Stream", "Playback Info"]

  var body: some View {
    TVShowcaseContent(
      title: "Marquee",
      summary: "Render text directly over video and tune placement, color, size, and opacity.",
      usage: "Turn on the overlay, edit its text and placement, and adjust opacity, color, and font size while video plays."
    ) {
      VStack(spacing: 16) {
        TVVideoPanel(player: player)
        TVPlaybackControls(player: player, showsVolume: false)
        TVSection(title: "Text Overlay") {
          Toggle("Enabled", isOn: $isEnabled)

          VStack(alignment: .leading, spacing: 12) {
            Text("Message")
              .font(.headline)

            TVChoiceGrid {
              ForEach(messagePresets, id: \.self) { message in
                TVChoiceButton(
                  title: message,
                  isSelected: text == message
                ) {
                  text = message
                }
              }
            }
          }

          VStack(alignment: .leading, spacing: 12) {
            Text("Color")
              .font(.headline)

            TVChoiceGrid {
              ForEach(MarqueeColor.allCases) { color in
                TVChoiceButton(
                  title: color.label,
                  isSelected: self.color == color
                ) {
                  self.color = color
                }
              }
            }
          }

          VStack(alignment: .leading, spacing: 12) {
            Text("Anchor")
              .font(.headline)

            TVChoiceGrid {
              ForEach(MarqueeAnchor.allCases) { anchor in
                TVChoiceButton(
                  title: anchor.label,
                  isSelected: self.anchor == anchor
                ) {
                  self.anchor = anchor
                }
              }
            }
          }

          VStack(spacing: 10) {
            sliderRow("Opacity", value: $opacity, range: 0...255, step: 10)
            sliderRow("Font", value: $fontSize, range: 8...96, step: 4)
            sliderRow("X", value: $x, range: -400...400, step: 20)
            sliderRow("Y", value: $y, range: -400...400, step: 20)
          }
        }
      }
    } sidebar: {
      TVSection(title: "Overlay", isFocusable: true) {
        TVMetricGrid {
          TVMetricRow(title: "Enabled", value: isEnabled ? "Yes" : "No")
          TVMetricRow(title: "Anchor", value: anchor.label)
          TVMetricRow(title: "Opacity", value: "\(Int(opacity))")
          TVMetricRow(title: "Font", value: "\(Int(fontSize)) px")
        }
      }
      TVLibrarySurface(symbols: ["player.withMarquee { ... }", "Marquee.show(text:)"])
    }
    .task { task() }
    .onChange(of: isEnabled) { applyMarquee() }
    .onChange(of: text) { applyMarquee() }
    .onChange(of: color) { applyMarquee() }
    .onChange(of: anchor) { applyMarquee() }
    .onChange(of: opacity) { applyMarquee() }
    .onChange(of: fontSize) { applyMarquee() }
    .onChange(of: x) { applyMarquee() }
    .onChange(of: y) { applyMarquee() }
    .onDisappear { player.stop() }
  }

  private func task() {
    try? player.play(url: TVTestMedia.demo)
    applyMarquee()
  }

  private func applyMarquee() {
    player.withMarquee { marquee in
      marquee.setText(text)
      marquee.color = color.rgb
      marquee.position = anchor.bitmask
      marquee.opacity = Int(opacity)
      marquee.fontSize = Int(fontSize)
      marquee.x = Int(x)
      marquee.y = Int(y)
      marquee.isEnabled = isEnabled
    }
  }

  private func sliderRow(
    _ title: String,
    value: Binding<Double>,
    range: ClosedRange<Double>,
    step: Double
  ) -> some View {
    TVSlider(
      title,
      value: value,
      in: range,
      step: step
    ) { "\(Int($0))" }
  }
}

private enum MarqueeColor: String, CaseIterable, Identifiable {
  case white, red, green, blue, yellow, cyan, magenta, black

  var id: Self {
    self
  }

  var label: String {
    rawValue.capitalized
  }

  var rgb: Int {
    switch self {
    case .white: 0xFFFFFF
    case .red: 0xFF0000
    case .green: 0x00FF00
    case .blue: 0x0000FF
    case .yellow: 0xFFFF00
    case .cyan: 0x00FFFF
    case .magenta: 0xFF00FF
    case .black: 0x000000
    }
  }
}

private enum MarqueeAnchor: String, CaseIterable, Identifiable {
  case topLeft, top, topRight, left, center, right, bottomLeft, bottom, bottomRight

  var id: Self {
    self
  }

  var label: String {
    switch self {
    case .topLeft: "Top Left"
    case .top: "Top"
    case .topRight: "Top Right"
    case .left: "Left"
    case .center: "Center"
    case .right: "Right"
    case .bottomLeft: "Bottom Left"
    case .bottom: "Bottom"
    case .bottomRight: "Bottom Right"
    }
  }

  var bitmask: Int {
    switch self {
    case .center: 0
    case .left: 1
    case .right: 2
    case .top: 4
    case .topLeft: 4 | 1
    case .topRight: 4 | 2
    case .bottom: 8
    case .bottomLeft: 8 | 1
    case .bottomRight: 8 | 2
    }
  }
}
