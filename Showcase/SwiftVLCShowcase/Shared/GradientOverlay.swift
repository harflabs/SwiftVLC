import SwiftUI

/// Dark gradient overlays for text legibility over video content.
enum GradientOverlay {
  #if os(tvOS)
  private static let topHeight: CGFloat = 180
  private static let bottomHeight: CGFloat = 200
  #else
  private static let topHeight: CGFloat = 120
  private static let bottomHeight: CGFloat = 140
  #endif

  /// Top-down gradient for title bars over video.
  static var top: some View {
    LinearGradient(
      colors: [.black.opacity(0.7), .black.opacity(0.3), .clear],
      startPoint: .top,
      endPoint: .bottom
    )
    .frame(height: topHeight)
    .allowsHitTesting(false)
  }

  /// Bottom-up gradient for controls over video.
  static var bottom: some View {
    LinearGradient(
      colors: [.clear, .black.opacity(0.3), .black.opacity(0.7)],
      startPoint: .top,
      endPoint: .bottom
    )
    .frame(height: bottomHeight)
    .allowsHitTesting(false)
  }
}
