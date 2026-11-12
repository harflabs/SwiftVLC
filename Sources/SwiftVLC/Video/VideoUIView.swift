#if canImport(UIKit)
  import UIKit

  /// UIKit host using the same drawable ownership and resizing as VideoView.
  @MainActor
  public final class VideoUIView: UIView {
    private let surface = VideoSurface()
    public var player: Player? {
      didSet {
        surface.detach()
        if let player { surface.attach(to: player) }
      }
    }
    public init(player: Player? = nil) {
      self.player = player
      super.init(frame: .zero)
      backgroundColor = .black
      clipsToBounds = true
      addSubview(surface)
      surface.isUserInteractionEnabled = false
      if let player { surface.attach(to: player) }
    }
    public required init?(coder: NSCoder) { fatalError("Use init(player:)") }
    public override func layoutSubviews() {
      super.layoutSubviews()
      surface.frame = bounds
    }
    public func detach() { player = nil }
  }
#endif
