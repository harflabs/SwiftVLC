import SwiftUI

/// Dark gradient overlays for text legibility over video content.
enum GradientOverlay {
  /// Top-down gradient for title bars over video.
  static var top: some View {
    LinearGradient(
      colors: [.black.opacity(0.7), .black.opacity(0.3), .clear],
      startPoint: .top,
      endPoint: .bottom
    )
    .frame(height: 120)
    .allowsHitTesting(false)
  }

  /// Bottom-up gradient for controls over video.
  static var bottom: some View {
    LinearGradient(
      colors: [.clear, .black.opacity(0.3), .black.opacity(0.7)],
      startPoint: .top,
      endPoint: .bottom
    )
    .frame(height: 140)
    .allowsHitTesting(false)
  }
}
