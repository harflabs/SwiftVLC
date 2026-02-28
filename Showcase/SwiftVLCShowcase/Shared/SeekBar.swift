#if !os(tvOS)
import SwiftUI
import SwiftVLC

/// Polished seek slider with elapsed/remaining time.
///
/// Decouples drag state from the player's position so scrubbing
/// is smooth — seeks are only committed when the user lifts their finger.
struct SeekBar: View {
  @Bindable var player: Player
  var showTimeLabels = true
  var onEditingChanged: ((Bool) -> Void)?

  @State private var isDragging = false
  @State private var dragPosition: Double = 0

  /// The position shown in the slider: local drag value while
  /// scrubbing, player's actual position otherwise.
  private var displayPosition: Double {
    isDragging ? dragPosition : player.position
  }

  var body: some View {
    VStack(spacing: 4) {
      Slider(
        value: Binding(
          get: { displayPosition },
          set: { dragPosition = $0 }
        ),
        in: 0...1
      ) { editing in
        isDragging = editing
        if editing {
          dragPosition = player.position
        } else {
          player.position = dragPosition
        }
        onEditingChanged?(editing)
      }
      .tint(.accentColor)

      if showTimeLabels {
        HStack {
          Text(displayTime.formatted)
            .contentTransition(.numericText())
          Spacer()
          Text(displayRemaining.remainingFormatted)
            .contentTransition(.numericText())
        }
        .monospacedDigit()
        .font(.caption)
        .foregroundStyle(.secondary)
      }
    }
  }

  /// Elapsed time matching the visible slider position.
  private var displayTime: Duration {
    guard let duration = player.duration else { return player.currentTime }
    if isDragging {
      let ms = Int64(dragPosition * Double(duration.milliseconds))
      return .milliseconds(ms)
    }
    return player.currentTime
  }

  /// Remaining time matching the visible slider position.
  private var displayRemaining: Duration {
    guard let duration = player.duration else { return .zero }
    let elapsed = isDragging
      ? Duration.milliseconds(Int64(dragPosition * Double(duration.milliseconds)))
      : player.currentTime
    let left = duration - elapsed
    return left < .zero ? .zero : left
  }
}

#endif
