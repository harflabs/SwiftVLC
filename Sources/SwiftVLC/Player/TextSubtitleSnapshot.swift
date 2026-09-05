/// A complete, ordered snapshot of the semantic text subtitles currently
/// displayed by libVLC.
///
/// An empty `regions` array represents a cleared subtitle presentation. Use
/// ``text`` when only the traditional flattened subtitle string is needed.
public struct TextSubtitleSnapshot: Sendable, Hashable {
  /// The text regions in libVLC presentation order.
  public let regions: [TextSubtitleRegion]

  /// Creates a subtitle snapshot.
  public init(regions: [TextSubtitleRegion] = []) {
    self.regions = regions
  }

  /// The region texts flattened in presentation order, separated by newlines.
  public var text: String {
    regions.map(\.text).joined(separator: "\n")
  }

  /// Whether this snapshot represents a cleared subtitle presentation.
  public var isEmpty: Bool {
    regions.isEmpty
  }
}

/// One semantic text region in a subtitle snapshot.
public struct TextSubtitleRegion: Sendable, Hashable {
  /// The region's decoded text.
  public let text: String

  /// The placement information supplied by the subtitle decoder.
  public let placement: TextSubtitlePlacement

  /// Creates a text region.
  public init(
    text: String,
    placement: TextSubtitlePlacement = .automatic
  ) {
    self.text = text
    self.placement = placement
  }
}

/// Placement information for a semantic text subtitle region.
public enum TextSubtitlePlacement: Sendable, Hashable {
  /// Placement is intentionally left to the custom presenter.
  ///
  /// This is used for SRT, TTML, `mov_text`, and all other non-WebVTT
  /// semantic text formats.
  case automatic

  /// Parsed placement supplied explicitly by the WebVTT decoder.
  case webVTT(WebVTTPlacement)
}

/// Parsed WebVTT cue placement in normalized video coordinates.
///
/// Positions can fall outside `0 ... 1` when the cue intentionally extends
/// beyond the viewport. Maximum dimensions constrain the cue box when
/// present; they are not its measured size. Renderer safety margins and
/// collision avoidance are not folded into these semantic values.
public struct WebVTTPlacement: Sendable, Hashable {
  /// The point on the cue box selected along the horizontal axis.
  public enum HorizontalAnchor: Sendable, Hashable {
    /// The horizontal center of the cue box.
    case center

    /// The left edge of the cue box.
    case left

    /// The right edge of the cue box.
    case right
  }

  /// The point on the cue box selected along the vertical axis.
  public enum VerticalAnchor: Sendable, Hashable {
    /// The vertical center of the cue box.
    case center

    /// The top edge of the cue box.
    case top

    /// The bottom edge of the cue box.
    case bottom
  }

  /// The resolved physical alignment of text inside the cue box.
  public enum TextAlignment: Sendable, Hashable {
    /// Text is centered within the cue box.
    case center

    /// Text is aligned with the left edge of the cue box.
    case left

    /// Text is aligned with the right edge of the cue box.
    case right
  }

  /// The direction in which lines are laid out.
  public enum WritingDirection: Sendable, Hashable {
    /// Lines are laid out horizontally from top to bottom.
    case horizontal

    /// Lines are vertical and successive lines grow toward the left.
    case verticalGrowingLeft

    /// Lines are vertical and successive lines grow toward the right.
    case verticalGrowingRight
  }

  /// The normalized horizontal viewport position.
  public let horizontalPosition: Float

  /// The normalized vertical viewport position.
  public let verticalPosition: Float

  /// The cue-box anchor placed at ``horizontalPosition``.
  public let horizontalAnchor: HorizontalAnchor

  /// The cue-box anchor placed at ``verticalPosition``.
  public let verticalAnchor: VerticalAnchor

  /// The optional maximum cue-box width, normalized to the viewport width.
  public let maximumWidth: Float?

  /// The optional maximum cue-box height, normalized to the viewport height.
  public let maximumHeight: Float?

  /// The resolved physical text alignment inside the cue box.
  public let textAlignment: TextAlignment

  /// The cue's resolved writing direction.
  public let writingDirection: WritingDirection

  /// Creates parsed WebVTT placement information.
  public init(
    horizontalPosition: Float,
    verticalPosition: Float,
    horizontalAnchor: HorizontalAnchor = .center,
    verticalAnchor: VerticalAnchor = .bottom,
    maximumWidth: Float? = nil,
    maximumHeight: Float? = nil,
    textAlignment: TextAlignment = .center,
    writingDirection: WritingDirection = .horizontal
  ) {
    self.horizontalPosition = horizontalPosition
    self.verticalPosition = verticalPosition
    self.horizontalAnchor = horizontalAnchor
    self.verticalAnchor = verticalAnchor
    self.maximumWidth = maximumWidth
    self.maximumHeight = maximumHeight
    self.textAlignment = textAlignment
    self.writingDirection = writingDirection
  }
}
