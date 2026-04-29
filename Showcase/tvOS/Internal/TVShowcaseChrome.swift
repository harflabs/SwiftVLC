import SwiftUI
import SwiftVLC

private enum TVShowcaseLayout {
  static let contentWidth: CGFloat = 1680
  static let primaryColumnWidth: CGFloat = 980
  static let sidebarColumnWidth: CGFloat = 560
  static let columnGap: CGFloat = 140
  static let minimumColumnHeight: CGFloat = 880
}

struct TVShowcaseContent<Primary: View, Sidebar: View>: View {
  let title: String
  let summary: String
  let usage: String
  @ViewBuilder var primary: Primary
  @ViewBuilder var sidebar: Sidebar

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 34) {
        header

        HStack(alignment: .top, spacing: 0) {
          TVFocusColumn {
            primary
          }
          .frame(width: TVShowcaseLayout.primaryColumnWidth, alignment: .topLeading)

          Spacer(minLength: TVShowcaseLayout.columnGap)

          TVFocusColumn(spacing: 24) {
            TVAboutSection(summary: summary, usage: usage)
            sidebar
          }
          .frame(width: TVShowcaseLayout.sidebarColumnWidth, alignment: .topLeading)
        }
        .frame(width: TVShowcaseLayout.contentWidth, alignment: .topLeading)
        .frame(minHeight: TVShowcaseLayout.minimumColumnHeight, alignment: .topLeading)
        .focusSection()
      }
      .frame(width: TVShowcaseLayout.contentWidth, alignment: .leading)
      .frame(maxWidth: .infinity, alignment: .center)
    }
    .safeAreaPadding(.horizontal, 80)
    .safeAreaPadding(.vertical, 48)
    .background(Color.black)
    .toolbar(.hidden, for: .navigationBar)
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title)
        .font(.system(size: 42, weight: .semibold, design: .rounded))
      Text(summary)
        .font(.system(size: 24, weight: .medium))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: TVShowcaseLayout.contentWidth, alignment: .leading)
    }
  }
}

private struct TVFocusColumn<Content: View>: View {
  var spacing: CGFloat = 22
  @ViewBuilder var content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: spacing) {
      content
      Spacer(minLength: 0)
    }
    .frame(
      maxWidth: .infinity,
      minHeight: TVShowcaseLayout.minimumColumnHeight,
      alignment: .topLeading
    )
    .focusSection()
  }
}

struct TVAboutSection: View {
  let summary: String
  let usage: String

  @FocusState private var isFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("About")
        .font(.system(size: 26, weight: .semibold))

      VStack(alignment: .leading, spacing: 10) {
        descriptionRow(title: "What it shows", text: summary)
        Divider()
        descriptionRow(title: "How to use it", text: usage)
      }
      .font(.body)
    }
    .padding(24)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.regularMaterial, in: .rect(cornerRadius: 18, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .strokeBorder(isFocused ? .white.opacity(0.55) : .white.opacity(0.14), lineWidth: isFocused ? 4 : 1)
    }
    .scaleEffect(isFocused ? 1.01 : 1)
    .animation(.easeOut(duration: 0.18), value: isFocused)
    .focusable()
    .focused($isFocused)
    .focusSection()
    .accessibilityElement(children: .combine)
    .accessibilityLabel("About")
  }

  private func descriptionRow(title: String, text: String) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title)
        .fontWeight(.semibold)
      Text(text)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}

struct TVVideoPanel: View {
  let player: Player

  @FocusState private var isFocused: Bool

  var body: some View {
    VideoView(player)
      .aspectRatio(16 / 9, contentMode: .fit)
      .frame(maxWidth: 660)
      .background(.black, in: .rect(cornerRadius: 18, style: .continuous))
      .clipShape(.rect(cornerRadius: 18, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
          .strokeBorder(isFocused ? .white.opacity(0.55) : .white.opacity(0.16), lineWidth: isFocused ? 4 : 1)
      }
      .scaleEffect(isFocused ? 1.025 : 1)
      .shadow(color: .black.opacity(isFocused ? 0.45 : 0), radius: isFocused ? 24 : 0, y: 12)
      .animation(.easeOut(duration: 0.18), value: isFocused)
      .focusable()
      .focused($isFocused)
      .focusSection()
      .accessibilityLabel("Video preview")
      .accessibilityValue(player.isPlaying ? "Playing" : "Paused")
  }
}

struct TVPlaybackControls: View {
  let player: Player
  var showsVolume = false

  var body: some View {
    @Bindable var bindable = player

    VStack(spacing: 12) {
      HStack(spacing: 16) {
        Button {
          player.togglePlayPause()
        } label: {
          Label(player.isPlaying ? "Pause" : "Play", systemImage: player.isPlaying ? "pause.fill" : "play.fill")
        }
        .buttonStyle(.borderedProminent)

        Spacer()

        Text(durationLabel(player.currentTime))
          .monospacedDigit()
          .foregroundStyle(.secondary)
          .frame(width: 88, alignment: .trailing)
      }

      TVSlider(
        "Position",
        value: $bindable.position,
        in: 0...1,
        step: 0.05
      ) { _ in durationLabel(player.currentTime) }
        .disabled(!player.isSeekable)

      if showsVolume {
        VStack(alignment: .leading, spacing: 10) {
          Toggle("Muted", isOn: $bindable.isMuted)

          TVSlider(
            "Volume",
            value: $bindable.volume,
            in: 0...1.25,
            step: 0.05
          ) { "\(Int($0 * 100))%" }
        }
      }
    }
    .padding(16)
    .frame(maxWidth: 660)
    .font(.system(size: 21, weight: .medium))
    .controlSize(.large)
    .background(.regularMaterial, in: .rect(cornerRadius: 18, style: .continuous))
    .focusSection()
  }
}

struct TVSlider<Value: BinaryFloatingPoint>: View {
  let title: String
  @Binding var value: Value
  let range: ClosedRange<Value>
  let step: Value
  let valueLabel: (Value) -> String

  @Environment(\.isEnabled) private var isEnabled

  init(
    _ title: String,
    value: Binding<Value>,
    in range: ClosedRange<Value>,
    step: Value,
    valueLabel: @escaping (Value) -> String
  ) {
    self.title = title
    _value = value
    self.range = range
    self.step = step
    self.valueLabel = valueLabel
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text(title)
          .foregroundStyle(.secondary)
        Spacer()
        Text(valueLabel(clampedValue))
          .monospacedDigit()
      }

      HStack(spacing: 14) {
        Button {
          decrement()
        } label: {
          Image(systemName: "minus")
            .frame(width: 32, height: 32)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .accessibilityLabel("Decrease \(title)")
        .disabled(clampedValue <= range.lowerBound)

        GeometryReader { proxy in
          let width = proxy.size.width
          let progressWidth = width * normalizedValue

          ZStack(alignment: .leading) {
            trackBackground
            progressTrack(width: progressWidth)
            thumb(progressWidth: progressWidth, totalWidth: width)
          }
          .frame(height: 42)
          .flipsForRightToLeftLayoutDirection(true)
        }
        .frame(height: 42)

        Button {
          increment()
        } label: {
          Image(systemName: "plus")
            .frame(width: 32, height: 32)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .accessibilityLabel("Increase \(title)")
        .disabled(clampedValue >= range.upperBound)
      }
      .focusSection()
    }
    .padding(12)
    .background(.white.opacity(0.045), in: .rect(cornerRadius: 16, style: .continuous))
    .opacity(isEnabled ? 1 : 0.45)
    .accessibilityLabel(title)
    .accessibilityValue(valueLabel(clampedValue))
    .accessibilityAdjustableAction { direction in
      switch direction {
      case .decrement:
        decrement()
      case .increment:
        increment()
      @unknown default:
        break
      }
    }
  }

  private var clampedValue: Value {
    min(max(value, range.lowerBound), range.upperBound)
  }

  private var normalizedValue: CGFloat {
    guard range.upperBound > range.lowerBound else { return 0 }
    let distance = Double(range.upperBound - range.lowerBound)
    let progress = Double(clampedValue - range.lowerBound) / distance
    return CGFloat(min(1, max(0, progress)))
  }

  private var trackHeight: CGFloat {
    7
  }

  private var thumbSize: CGFloat {
    22
  }

  private var trackBackground: some View {
    RoundedRectangle(cornerRadius: trackHeight / 2)
      .fill(.white.opacity(0.18))
      .frame(height: trackHeight)
  }

  private func progressTrack(width: CGFloat) -> some View {
    RoundedRectangle(cornerRadius: trackHeight / 2)
      .fill(.blue)
      .frame(width: max(0, width), height: trackHeight)
  }

  private func thumb(progressWidth: CGFloat, totalWidth: CGFloat) -> some View {
    let offset = max(0, min(progressWidth - thumbSize / 2, totalWidth - thumbSize))

    return Circle()
      .fill(.white)
      .frame(width: thumbSize, height: thumbSize)
      .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
      .offset(x: offset)
  }

  private func decrement() {
    value = max(range.lowerBound, value - step)
  }

  private func increment() {
    value = min(range.upperBound, value + step)
  }
}

struct TVMetricGrid<Content: View>: View {
  @ViewBuilder var content: Content

  var body: some View {
    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
      content
    }
    .font(.body)
  }
}

struct TVMetricRow: View {
  let title: String
  let value: String

  var body: some View {
    GridRow {
      Text(title)
        .foregroundStyle(.secondary)
      Text(value)
        .foregroundStyle(.primary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}

struct TVSection<Content: View>: View {
  let title: String
  var isFocusable = false
  @ViewBuilder var content: Content

  @FocusState private var isFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text(title)
        .font(.system(size: 26, weight: .semibold))
      VStack(alignment: .leading, spacing: 16) {
        content
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(22)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.regularMaterial, in: .rect(cornerRadius: 18, style: .continuous))
    .controlSize(.large)
    .overlay {
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .strokeBorder(isFocused ? .white.opacity(0.5) : .white.opacity(0.12), lineWidth: isFocused ? 4 : 1)
    }
    .scaleEffect(isFocused ? 1.01 : 1)
    .animation(.easeOut(duration: 0.18), value: isFocused)
    .focusable(isFocusable)
    .focused($isFocused)
    .focusSection()
    .accessibilityElement(children: isFocusable ? .combine : .contain)
  }
}

struct TVControlGrid<Content: View>: View {
  @ViewBuilder var content: Content

  private let columns = [
    GridItem(.flexible(minimum: 180), spacing: 16),
    GridItem(.flexible(minimum: 180), spacing: 16),
    GridItem(.flexible(minimum: 180), spacing: 16)
  ]

  var body: some View {
    LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
      content
    }
    .focusSection()
  }
}

struct TVChoiceGrid<Content: View>: View {
  @ViewBuilder var content: Content

  private let columns = [
    GridItem(.flexible(minimum: 300), spacing: 14),
    GridItem(.flexible(minimum: 300), spacing: 14)
  ]

  var body: some View {
    LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
      content
    }
    .focusSection()
  }
}

struct TVLibrarySurface: View {
  let symbols: [String]

  var body: some View {
    TVSection(title: "Library Surface", isFocusable: true) {
      ForEach(symbols, id: \.self) { symbol in
        Text(symbol)
          .fontDesign(.monospaced)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}

struct TVChoiceButton: View {
  let title: String
  var subtitle: String?
  var isSelected = false
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 14) {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
          .foregroundStyle(isSelected ? .green : .secondary)
        VStack(alignment: .leading, spacing: 4) {
          Text(title)
            .font(.body.weight(.semibold))
            .fixedSize(horizontal: false, vertical: true)
          if let subtitle {
            Text(subtitle)
              .font(.callout)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        Spacer(minLength: 0)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(.rect)
    }
    .buttonStyle(.bordered)
    .frame(minHeight: 70)
  }
}

struct TVPlaceholderRow: View {
  let text: String

  var body: some View {
    Text(text)
      .foregroundStyle(.secondary)
      .font(.body)
      .frame(maxWidth: .infinity, alignment: .leading)
  }
}

func durationLabel(_ duration: Duration) -> String {
  let seconds = max(0, Int(duration.components.seconds))
  let h = seconds / 3600
  let m = (seconds % 3600) / 60
  let s = seconds % 60
  return h > 0
    ? String(format: "%d:%02d:%02d", h, m, s)
    : String(format: "%d:%02d", m, s)
}

func durationLabel(_ duration: Duration?) -> String {
  duration.map(durationLabel) ?? "--:--"
}
