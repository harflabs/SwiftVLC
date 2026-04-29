import SwiftUI
import SwiftVLC

struct MacMarqueeCase: View {
  @State private var player = Player()
  @State private var isEnabled = true
  @State private var text = "SwiftVLC"
  @State private var color: MarqueeColor = .white
  @State private var anchor: MarqueeAnchor = .bottomRight
  @State private var opacity: Double = 255
  @State private var fontSize: Double = 28
  @State private var x: Double = 24
  @State private var y: Double = 24

  var body: some View {
    MacShowcaseContent(
      title: "Marquee",
      summary: "Render text directly over video and tune placement, color, size, and opacity.",
      usage: "Turn on the overlay, edit its text and placement, and adjust opacity, color, and font size while video plays."
    ) {
      VStack(spacing: 16) {
        MacVideoPanel(player: player)
        MacPlaybackControls(player: player, showsVolume: false)
        MacSection(title: "Text Overlay") {
          Toggle("Enabled", isOn: $isEnabled)
            .toggleStyle(.checkbox)

          HStack {
            Text("Text")
              .frame(width: 52, alignment: .leading)
            TextField("Overlay text", text: $text)
          }

          LazyVGrid(columns: controlColumns, alignment: .leading, spacing: 10) {
            Picker("Color", selection: $color) {
              ForEach(MarqueeColor.allCases) { color in
                Text(color.label).tag(color)
              }
            }
            Picker("Anchor", selection: $anchor) {
              ForEach(MarqueeAnchor.allCases) { anchor in
                Text(anchor.label).tag(anchor)
              }
            }
          }

          LazyVGrid(columns: controlColumns, alignment: .leading, spacing: 10) {
            sliderRow("Opacity", value: $opacity, range: 0...255)
            sliderRow("Font", value: $fontSize, range: 8...96)
            sliderRow("X", value: $x, range: -400...400)
            sliderRow("Y", value: $y, range: -400...400)
          }
        }
      }
    } sidebar: {
      MacSection(title: "Overlay") {
        MacMetricGrid {
          MacMetricRow(title: "Enabled", value: isEnabled ? "Yes" : "No")
          MacMetricRow(title: "Anchor", value: anchor.label)
          MacMetricRow(title: "Opacity", value: "\(Int(opacity))")
          MacMetricRow(title: "Font", value: "\(Int(fontSize)) px")
        }
      }
      MacLibrarySurface(symbols: ["player.withMarquee { ... }", "Marquee.show(text:)"])
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
    try? player.play(url: MacTestMedia.demo)
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

  private func sliderRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
    HStack {
      Text(title)
        .frame(width: 52, alignment: .leading)
      Slider(value: value, in: range)
      Text("\(Int(value.wrappedValue))")
        .font(.callout.monospacedDigit())
        .foregroundStyle(.secondary)
        .frame(width: 44, alignment: .trailing)
    }
  }

  private var controlColumns: [GridItem] {
    [
      GridItem(.flexible(minimum: 220), spacing: 18),
      GridItem(.flexible(minimum: 220))
    ]
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
