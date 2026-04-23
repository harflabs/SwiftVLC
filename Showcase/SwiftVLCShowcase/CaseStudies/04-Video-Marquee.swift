import SwiftUI
import SwiftVLC

private let readMe = """
`player.marquee` renders text over video. Every property (text, font size, color, \
opacity, anchor, `x`/`y` pixel offset, timeout) is a nonmutating write through the \
non-copyable `~Escapable` borrow. Drag the video to reposition the overlay \
interactively; each gesture tick re-enters `player.withMarquee`.
"""

struct MarqueeCase: View {
  @State private var player = Player()
  @State private var isEnabled = false
  @State private var text = "SwiftVLC"
  @State private var opacity: Double = 255
  @State private var fontSize: Double = 24
  @State private var color: MarqueeColor = .white
  @State private var anchor: MarqueeAnchor = .center
  @State private var x: Double = 0
  @State private var y: Double = 0
  @State private var timeoutMs: Double = 0
  @State private var dragOrigin: CGPoint?

  var body: some View {
    Form {
      Section { AboutView(readMe: readMe) }

      Section {
        VideoView(player)
          .aspectRatio(16 / 9, contentMode: .fit)
          .listRowInsets(EdgeInsets())
          .accessibilityIdentifier(AccessibilityID.Marquee.videoView)
        #if os(iOS) || os(macOS)
          .highPriorityGesture(repositionDrag)
        #endif
      } footer: {
        PlayPauseFooter(player: player)
          .accessibilityIdentifier(AccessibilityID.Marquee.playPauseButton)
      }

      Section("Marquee") {
        Toggle("Enabled", isOn: $isEnabled)
          .accessibilityIdentifier(AccessibilityID.Marquee.enabledToggle)
        TextField("Text", text: $text)
          .accessibilityIdentifier(AccessibilityID.Marquee.textField)

        Picker("Color", selection: $color) {
          ForEach(MarqueeColor.allCases) { c in
            Text(c.label).tag(c)
          }
        }
        .accessibilityIdentifier(AccessibilityID.Marquee.colorPicker)

        Picker("Anchor", selection: $anchor) {
          ForEach(MarqueeAnchor.allCases) { a in
            Text(a.label).tag(a)
          }
        }
        .accessibilityIdentifier(AccessibilityID.Marquee.anchorPicker)

        sliderRow(
          "Opacity",
          value: $opacity,
          range: 0...255,
          format: { String(format: "%.0f%%", $0 / 255 * 100) },
          valueID: AccessibilityID.Marquee.opacityLabel,
          sliderID: AccessibilityID.Marquee.opacitySlider
        )
        sliderRow(
          "Font Size",
          value: $fontSize,
          range: 8...96,
          format: { "\(Int($0)) px" },
          valueID: nil,
          sliderID: AccessibilityID.Marquee.fontSizeSlider
        )
        sliderRow(
          "X Offset",
          value: $x,
          range: -400...400,
          format: { "\(Int($0)) px" },
          valueID: nil,
          sliderID: AccessibilityID.Marquee.xSlider
        )
        sliderRow(
          "Y Offset",
          value: $y,
          range: -400...400,
          format: { "\(Int($0)) px" },
          valueID: nil,
          sliderID: AccessibilityID.Marquee.ySlider
        )
        sliderRow(
          "Timeout",
          value: $timeoutMs,
          range: 0...10000,
          format: { $0 == 0 ? "permanent" : String(format: "%.1f s", $0 / 1000) },
          valueID: nil,
          sliderID: AccessibilityID.Marquee.timeoutSlider
        )

        Button("Reset Position") {
          x = 0
          y = 0
        }
        .accessibilityIdentifier(AccessibilityID.Marquee.resetButton)
      }
    }
    .showcaseFormStyle()
    .navigationTitle("Marquee")
    .task { task() }
    .onChange(of: isEnabled) { player.withMarquee { $0.isEnabled = isEnabled } }
    .onChange(of: text) { player.withMarquee { $0.setText(text) } }
    .onChange(of: opacity) { player.withMarquee { $0.opacity = Int(opacity) } }
    .onChange(of: fontSize) { player.withMarquee { $0.fontSize = Int(fontSize) } }
    .onChange(of: color) { player.withMarquee { $0.color = color.rgb } }
    .onChange(of: anchor) { player.withMarquee { $0.position = anchor.bitmask } }
    .onChange(of: x) { player.withMarquee { $0.x = Int(x) } }
    .onChange(of: y) { player.withMarquee { $0.y = Int(y) } }
    .onChange(of: timeoutMs) { player.withMarquee { $0.timeout = Int(timeoutMs) } }
    .onDisappear { player.stop() }
  }

  private func task() {
    try? player.play(url: TestMedia.demo)
    // Push every property into libVLC *before* the Enable flag flips.
    // Otherwise the overlay filter activates with NULL text or a zero-
    // size font and draws nothing. `onChange` can't do this: it doesn't
    // fire for initial values.
    player.withMarquee { m in
      m.setText(text)
      m.fontSize = Int(fontSize)
      m.color = color.rgb
      m.opacity = Int(opacity)
      m.position = anchor.bitmask
      m.x = Int(x)
      m.y = Int(y)
      m.timeout = Int(timeoutMs)
      m.isEnabled = isEnabled
    }
  }

  #if os(iOS) || os(macOS)
  private var repositionDrag: some Gesture {
    // Stress-tests the borrow path: every touch-move fires `player.withMarquee`,
    // which re-constructs the `~Copyable` `~Escapable` view on each call.
    DragGesture(minimumDistance: 1)
      .onChanged { g in
        let origin = dragOrigin ?? CGPoint(x: x, y: y)
        if dragOrigin == nil { dragOrigin = origin }
        x = (origin.x + g.translation.width).clamped(to: -400...400)
        y = (origin.y + g.translation.height).clamped(to: -400...400)
      }
      .onEnded { _ in dragOrigin = nil }
  }
  #endif

  private func sliderRow(
    _ title: String,
    value: Binding<Double>,
    range: ClosedRange<Double>,
    format: (Double) -> String,
    valueID: String?,
    sliderID: String?
  ) -> some View {
    VStack(alignment: .leading) {
      HStack {
        Text(title)
        Spacer()
        Text(format(value.wrappedValue))
          .foregroundStyle(.secondary)
          .accessibilityIdentifier(ifPresent: valueID)
      }
      CompatSlider(value: value, range: range)
        .accessibilityIdentifier(ifPresent: sliderID)
    }
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

extension Double {
  fileprivate func clamped(to range: ClosedRange<Double>) -> Double {
    min(max(self, range.lowerBound), range.upperBound)
  }
}
