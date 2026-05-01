import SwiftUI
import SwiftVLC

struct MacShowcaseContent<Primary: View, Sidebar: View>: View {
  let title: String
  let summary: String
  let usage: String
  @ViewBuilder var primary: Primary
  @ViewBuilder var sidebar: Sidebar

  var body: some View {
    HSplitView {
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          Text(title)
            .font(.largeTitle.weight(.semibold))
          primary
        }
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .leading)
      }

      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          MacAboutSection(summary: summary, usage: usage)
          sidebar
        }
        .padding(20)
        .frame(width: 300, alignment: .topLeading)
      }
      .background(.regularMaterial)
    }
  }
}

struct MacAboutSection: View {
  let summary: String
  let usage: String

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("About")
        .font(.headline)
        .foregroundStyle(Color(nsColor: .labelColor))

      VStack(alignment: .leading, spacing: 10) {
        descriptionRow(title: "What it shows", text: summary)
        Divider()
        descriptionRow(title: "How to use it", text: usage)
      }
      .font(.callout)
      .textSelection(.enabled)
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 8))
    .overlay {
      RoundedRectangle(cornerRadius: 8)
        .stroke(Color(nsColor: .separatorColor))
    }
  }

  private func descriptionRow(title: String, text: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title)
        .fontWeight(.semibold)
        .foregroundStyle(Color(nsColor: .labelColor))
      Text(text)
        .foregroundStyle(Color(nsColor: .secondaryLabelColor))
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}

struct MacVideoPanel: View {
  let player: Player

  var body: some View {
    VideoView(player)
      .aspectRatio(16 / 9, contentMode: .fit)
      .frame(maxWidth: .infinity)
      .background(.black, in: .rect(cornerRadius: 8))
      .overlay {
        RoundedRectangle(cornerRadius: 8)
          .stroke(Color.secondary.opacity(0.25))
      }
  }
}

struct MacPlaybackControls: View {
  let player: Player
  var showsVolume = true

  var body: some View {
    @Bindable var bindable = player

    VStack(spacing: 12) {
      HStack(spacing: 12) {
        Button {
          player.togglePlayPause()
        } label: {
          Label(
            player.isPlaybackRequestedActive ? "Pause" : "Play",
            systemImage: player.isPlaybackRequestedActive ? "pause.fill" : "play.fill"
          )
        }
        .keyboardShortcut(.space, modifiers: [])

        Slider(value: $bindable.position, in: 0...1)
          .disabled(!player.isSeekable)

        Text(durationLabel(player.currentTime))
          .monospacedDigit()
          .foregroundStyle(.secondary)
          .frame(width: 56, alignment: .trailing)
      }

      if showsVolume {
        HStack(spacing: 12) {
          Toggle("Muted", isOn: $bindable.isMuted)
            .toggleStyle(.checkbox)
          Slider(value: $bindable.volume, in: 0...1.25)
          Text("\(Int(player.volume * 100))%")
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .frame(width: 44, alignment: .trailing)
        }
      }
    }
    .controlSize(.regular)
  }
}

struct MacMetricGrid<Content: View>: View {
  @ViewBuilder var content: Content

  var body: some View {
    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
      content
    }
    .font(.callout)
  }
}

struct MacMetricRow: View {
  let title: String
  let value: String
  var valueIdentifier: String?

  var body: some View {
    GridRow {
      Text(title)
        .foregroundStyle(.secondary)
      valueText
    }
  }

  @ViewBuilder
  private var valueText: some View {
    if let valueIdentifier {
      Text(value)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier(valueIdentifier)
    } else {
      Text(value)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}

struct MacSection<Content: View>: View {
  let title: String
  @ViewBuilder var content: Content

  var body: some View {
    GroupBox {
      VStack(alignment: .leading, spacing: 12) {
        content
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(2)
    } label: {
      Text(title)
        .font(.headline)
    }
  }
}

struct MacLibrarySurface: View {
  let symbols: [String]

  var body: some View {
    MacSection(title: "Library Surface") {
      ForEach(symbols, id: \.self) { symbol in
        Text(symbol)
          .fontDesign(.monospaced)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}

struct MacPlaceholderRow: View {
  let text: String

  var body: some View {
    Text(text)
      .foregroundStyle(.secondary)
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
