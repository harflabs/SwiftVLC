import SwiftUI

/// Floating thumbnail bubble that hovers above a slider thumb while
/// the user is scrubbing. Width is fixed so the bubble tip can slide
/// inside its frame when the bubble itself is clamped against the
/// container's edges — the tip always points at the slider thumb even
/// when the bubble can't fully center on it.
///
/// The parent reserves `bubbleHeight` of vertical space by embedding
/// this view above the slider; when `isVisible` is false the reserve
/// renders empty so there's no layout shift on scrub start.
struct ScrubBubble: View {
  let isVisible: Bool
  /// Slider fraction in `0...1`.
  let fraction: Double
  /// Tile image to display; `nil` renders a loading placeholder.
  let image: PlatformImage?
  /// Formatted time for the caption (e.g. `"1:23"`).
  let timeLabel: String

  private let width: CGFloat = 160
  /// Slider tracks inset ~14 pt on each side for the thumb radius.
  private let thumbInset: CGFloat = 14

  var body: some View {
    GeometryReader { geo in
      if isVisible {
        let thumbX = thumbInset + max(0, geo.size.width - 2 * thumbInset) * fraction
        let bubbleCenterX = min(max(width / 2, thumbX), max(width / 2, geo.size.width - width / 2))
        // Slide the tip inside the bubble when the bubble itself is
        // clamped so the pointer still aligns with the slider thumb.
        let maxTipOffset = width / 2 - 10
        let tipOffset = min(max(-maxTipOffset, thumbX - bubbleCenterX), maxTipOffset)

        bubble(tipOffsetX: tipOffset)
          .frame(width: width)
          .position(x: bubbleCenterX, y: geo.size.height / 2)
          .transition(.opacity)
      }
    }
    .frame(height: height)
    .padding(.bottom, 6)
  }

  private func bubble(tipOffsetX: CGFloat) -> some View {
    VStack(spacing: 0) {
      preview
        .aspectRatio(16 / 9, contentMode: .fit)
        .frame(width: width - 8)
        .clipShape(.rect(cornerRadius: 6))

      Text(timeLabel)
        .font(.caption2.monospaced())
        .foregroundStyle(.white)
        .padding(.top, 2)
        .padding(.bottom, 4)
    }
    .padding(4)
    .background(.black.opacity(0.85), in: .rect(cornerRadius: 8))
    .overlay(alignment: .bottom) {
      Triangle()
        .fill(.black.opacity(0.85))
        .frame(width: 10, height: 6)
        .offset(x: tipOffsetX, y: 6)
    }
    .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
  }

  @ViewBuilder
  private var preview: some View {
    if let image {
      Image(platformImage: image).resizable()
    } else {
      ZStack {
        Rectangle().fill(.gray.opacity(0.5))
        ProgressView().controlSize(.small).tint(.white)
      }
    }
  }

  private var height: CGFloat {
    let imageHeight = (width - 8) * 9 / 16
    return imageHeight + 22 + 8 // +caption row, +vertical padding, +tip
  }
}

/// Downward-pointing tip that anchors the bubble to the slider thumb.
private struct Triangle: Shape {
  func path(in rect: CGRect) -> Path {
    var path = Path()
    path.move(to: CGPoint(x: rect.midX, y: rect.maxY))
    path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
    path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
    path.closeSubpath()
    return path
  }
}
