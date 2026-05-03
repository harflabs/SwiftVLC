// macOS PiP backend. The public AVKit sample-buffer PiP path on macOS
// mirrors video through a `CALayerHost` that, on the macOS releases
// SwiftVLC supports, crops to 1:1 instead of scaling into the PiP
// panel. The private `PIPViewController` (loaded dynamically from
// `PIP.framework`) reparents the real VLC drawable instead, which
// matches the approach used by native macOS players such as IINA.

#if os(macOS)
import AppKit
import CLibVLC
import Foundation

@MainActor
final class MacNativePiPBackend: NSObject, @unchecked Sendable {
  let mediaController = MacNativePiPMediaController()
  weak var owner: PiPController?
  weak var hostView: MacNativePiPHostView?
  weak var drawableView: MacNativePiPDrawableView?

  private let presenter = MacPrivatePiPPresenter()
  private(set) var isPossible = false
  private(set) var isActive = false

  func attach(to player: Player) {
    mediaController.player = player
    refreshPossible()
  }

  func detach() {
    presenter.stop()
    mediaController.player = nil
    setPossible(false)
    setActive(false)
  }

  func start() {
    guard mediaController.player?.currentMedia != nil else {
      return
    }

    refreshPossible()
    guard
      isPossible,
      let hostView,
      let drawableView,
      let player = mediaController.player
    else {
      return
    }

    let didStart = presenter.start(
      player: player,
      hostView: hostView,
      drawableView: drawableView,
      mediaController: mediaController,
      onActiveChanged: { [weak self] isActive in
        self?.setActive(isActive)
      },
      onPlay: { [weak self] in
        self?.handleSetPlaying(true)
      },
      onPause: { [weak self] in
        self?.handleSetPlaying(false)
      }
    )

    if !didStart {
      setPossible(false)
    }
  }

  func stop() {
    presenter.stop()
  }

  func invalidatePlaybackState() {
    presenter.updatePlaybackState(isPlaying: mediaController.isMediaPlaying())
  }

  private func refreshPossible() {
    // `allowsPrivateMacOSAPI` is a global opt-in (default `false`). When
    // a consumer leaves it disabled, macOS PiP remains unavailable
    // outright: `isPossible` returns `false` and `start()` is a no-op.
    // The check happens here (rather than at PiPController init) so the
    // flag can be flipped at runtime and take effect on the next attach
    // or start.
    guard PiPController.allowsPrivateMacOSAPI else {
      setPossible(false)
      return
    }
    setPossible(
      mediaController.player?.instance.usesPiPSafeDarwinDisplay == true
        && MacPrivatePiPPresenter.isRuntimeAvailable
    )
  }

  private func setPossible(_ isPossible: Bool) {
    guard self.isPossible != isPossible else { return }
    self.isPossible = isPossible
    Task { @MainActor [weak owner] in
      owner?.handleNativePictureInPictureReady()
    }
  }

  private func setActive(_ isActive: Bool) {
    guard self.isActive != isActive else { return }
    self.isActive = isActive
    Task { @MainActor [weak owner] in
      owner?.handleNativePictureInPictureActiveChanged(isActive)
    }
  }

  private func handleSetPlaying(_ playing: Bool) {
    if let owner {
      owner.handleNativePictureInPictureSetPlaying(playing)
    } else if playing {
      mediaController.play()
    } else {
      mediaController.pause()
    }
  }
}

@MainActor
private final class MacPrivatePiPPresenter {
  static var isRuntimeAvailable: Bool {
    makePictureInPictureViewController() != nil
  }

  private weak var hostView: MacNativePiPHostView?
  private weak var drawableView: MacNativePiPDrawableView?
  private var pictureInPictureViewController: NSViewController?
  private var contentViewController: NSViewController?
  private var delegate: MacPrivatePiPDelegate?
  private var onActiveChanged: (@MainActor @Sendable (Bool) -> Void)?
  private var dismissalCompletion: MacPrivatePiPDismissCompletion?
  private var isClosing = false

  var isActive: Bool {
    pictureInPictureViewController != nil && !isClosing
  }

  func start(
    player: Player,
    hostView: MacNativePiPHostView,
    drawableView: MacNativePiPDrawableView,
    mediaController: MacNativePiPMediaController,
    onActiveChanged: @escaping @MainActor @Sendable (Bool) -> Void,
    onPlay: @escaping @MainActor @Sendable () -> Void,
    onPause: @escaping @MainActor @Sendable () -> Void
  ) -> Bool {
    guard !isClosing else { return false }
    if isActive {
      updatePlaybackState(isPlaying: mediaController.isMediaPlaying())
      return true
    }

    guard let pictureInPictureViewController = Self.makePictureInPictureViewController() else { return false }

    self.hostView = hostView
    self.drawableView = drawableView
    self.pictureInPictureViewController = pictureInPictureViewController
    self.onActiveChanged = onActiveChanged

    let delegate = MacPrivatePiPDelegate()
    delegate.shouldClose = { [weak self] in
      self?.beginClose() ?? true
    }
    delegate.willClose = { [weak self] in
      _ = self?.beginClose()
    }
    delegate.didClose = { [weak self] in
      self?.finish()
    }
    delegate.play = onPlay
    delegate.pause = onPause
    delegate.stop = onPause
    self.delegate = delegate

    let contentViewController = NSViewController()
    drawableView.removeFromSuperview()
    drawableView.frame = NSRect(origin: .zero, size: normalizedContentSize(from: hostView.bounds.size))
    drawableView.autoresizingMask = [.width, .height]
    contentViewController.view = drawableView
    self.contentViewController = contentViewController

    guard
      configure(
        pictureInPictureViewController,
        player: player,
        hostView: hostView,
        isPlaying: mediaController.isMediaPlaying()
      ) else {
      finish()
      return false
    }

    _ = pictureInPictureViewController.perform(
      MacPrivatePiPSelector.present,
      with: contentViewController
    )
    onActiveChanged(true)
    return true
  }

  func stop() {
    guard let pictureInPictureViewController else {
      finish()
      return
    }
    guard !isClosing else { return }

    _ = beginClose()
    if dismissUsingPrivateAPI(pictureInPictureViewController) {
      return
    }

    if
      let contentViewController,
      contentViewController.presentingViewController === pictureInPictureViewController {
      pictureInPictureViewController.dismiss(contentViewController)
    } else {
      finish()
    }
  }

  func updatePlaybackState(isPlaying: Bool) {
    guard let pictureInPictureViewController else { return }
    setPrivateValue(
      isPlaying,
      forKey: "playing",
      requiring: MacPrivatePiPSelector.setPlaying,
      on: pictureInPictureViewController
    )
  }

  @discardableResult
  private func beginClose() -> Bool {
    guard pictureInPictureViewController != nil else { return true }
    isClosing = true
    return prepareForClose()
  }

  @discardableResult
  private func prepareForClose() -> Bool {
    guard let pictureInPictureViewController, let hostView else { return true }
    let replacementRect = hostView.convert(hostView.bounds, to: nil)
    let didSetWindow = setPrivateValue(
      hostView.window,
      forKey: "replacementWindow",
      requiring: MacPrivatePiPSelector.setReplacementWindow,
      on: pictureInPictureViewController
    )
    let didSetRect = setPrivateValue(
      NSValue(rect: replacementRect),
      forKey: "replacementRect",
      requiring: MacPrivatePiPSelector.setReplacementRect,
      on: pictureInPictureViewController
    )
    return didSetWindow && didSetRect
  }

  private func dismissUsingPrivateAPI(_ pictureInPictureViewController: NSViewController) -> Bool {
    guard pictureInPictureViewController.responds(to: MacPrivatePiPSelector.dismiss) else {
      return false
    }

    let completion: MacPrivatePiPDismissCompletion = { [weak self] in
      Task { @MainActor in
        self?.finish()
      }
    }
    dismissalCompletion = completion
    _ = pictureInPictureViewController.perform(
      MacPrivatePiPSelector.dismiss,
      with: completion
    )
    return true
  }

  private func finish() {
    guard pictureInPictureViewController != nil || isClosing else { return }

    let hostView = hostView
    let drawableView = drawableView

    contentViewController?.view = NSView(frame: .zero)
    if let hostView, let drawableView {
      hostView.restoreDrawableView(drawableView)
    }

    pictureInPictureViewController = nil
    contentViewController = nil
    delegate = nil
    dismissalCompletion = nil
    isClosing = false
    self.hostView = nil
    self.drawableView = nil

    onActiveChanged?(false)
    onActiveChanged = nil
  }

  private func configure(
    _ pictureInPictureViewController: NSViewController,
    player: Player,
    hostView: MacNativePiPHostView,
    isPlaying: Bool
  ) -> Bool {
    pictureInPictureViewController.title = player.currentMedia?.mrl ?? "SwiftVLC"
    let didSetDelegate = setPrivateValue(
      delegate,
      forKey: "delegate",
      requiring: MacPrivatePiPSelector.setDelegate,
      on: pictureInPictureViewController
    )
    let didSetWindow = setPrivateValue(
      hostView.window,
      forKey: "replacementWindow",
      requiring: MacPrivatePiPSelector.setReplacementWindow,
      on: pictureInPictureViewController
    )
    let didSetPlaying = setPrivateValue(
      isPlaying,
      forKey: "playing",
      requiring: MacPrivatePiPSelector.setPlaying,
      on: pictureInPictureViewController
    )
    let didSetRect = setPrivateValue(
      NSValue(rect: hostView.convert(hostView.bounds, to: nil)),
      forKey: "replacementRect",
      requiring: MacPrivatePiPSelector.setReplacementRect,
      on: pictureInPictureViewController
    )
    let didSetAspectRatio = setPrivateValue(
      NSValue(size: normalizedContentSize(from: hostView.bounds.size)),
      forKey: "aspectRatio",
      requiring: MacPrivatePiPSelector.setAspectRatio,
      on: pictureInPictureViewController
    )

    return didSetDelegate
      && didSetWindow
      && didSetPlaying
      && didSetRect
      && didSetAspectRatio
  }

  private func normalizedContentSize(from size: CGSize) -> CGSize {
    guard size.width.isFinite, size.height.isFinite, size.width >= 16, size.height >= 16 else {
      return CGSize(width: 16, height: 9)
    }
    return CGSize(width: ceil(size.width), height: ceil(size.height))
  }

  private static func makePictureInPictureViewController() -> NSViewController? {
    guard let type = loadPictureInPictureViewControllerType() else { return nil }
    let controller = type.init(nibName: nil, bundle: nil)
    guard MacPrivatePiPSelector.required.allSatisfy({ controller.responds(to: $0) }) else {
      return nil
    }
    return controller
  }

  private static func loadPictureInPictureViewControllerType() -> NSViewController.Type? {
    guard
      let bundle = Bundle(path: "/System/Library/PrivateFrameworks/PIP.framework"),
      bundle.isLoaded || bundle.load()
    else {
      return nil
    }
    return NSClassFromString("PIPViewController") as? NSViewController.Type
  }
}

private typealias MacPrivatePiPDismissCompletion = @convention(block) () -> Void

private enum MacPrivatePiPSelector {
  static let present = NSSelectorFromString("presentViewControllerAsPictureInPicture:")
  static let dismiss = NSSelectorFromString("dismissPictureInPictureWithCompletionHandler:")
  static let setDelegate = NSSelectorFromString("setDelegate:")
  static let setReplacementWindow = NSSelectorFromString("setReplacementWindow:")
  static let setReplacementRect = NSSelectorFromString("setReplacementRect:")
  static let setPlaying = NSSelectorFromString("setPlaying:")
  static let setAspectRatio = NSSelectorFromString("setAspectRatio:")

  static let required = [
    present,
    setDelegate,
    setReplacementWindow,
    setReplacementRect,
    setPlaying,
    setAspectRatio
  ]
}

@discardableResult
private func setPrivateValue(
  _ value: Any?,
  forKey key: String,
  requiring selector: Selector,
  on object: NSObject
) -> Bool {
  guard object.responds(to: selector) else { return false }
  object.setValue(value, forKey: key)
  return true
}

private final class MacPrivatePiPDelegate: NSObject, @unchecked Sendable {
  var shouldClose: @MainActor @Sendable () -> Bool = { true }
  var willClose: @MainActor @Sendable () -> Void = {}
  var didClose: @MainActor @Sendable () -> Void = {}
  var play: @MainActor @Sendable () -> Void = {}
  var pause: @MainActor @Sendable () -> Void = {}
  var stop: @MainActor @Sendable () -> Void = {}

  @objc(pipShouldClose:)
  func pipShouldClose(_: NSObject) -> Bool {
    pipMainActorSync { [weak self] in
      self?.shouldClose() ?? true
    }
  }

  @objc(pipWillClose:)
  func pipWillClose(_: NSObject) {
    Task { @MainActor [weak self] in
      self?.willClose()
    }
  }

  @objc(pipDidClose:)
  func pipDidClose(_: NSObject) {
    Task { @MainActor [weak self] in
      self?.didClose()
    }
  }

  @objc(pipActionPlay:)
  func pipActionPlay(_: NSObject) {
    Task { @MainActor [weak self] in
      self?.play()
    }
  }

  @objc(pipActionPause:)
  func pipActionPause(_: NSObject) {
    Task { @MainActor [weak self] in
      self?.pause()
    }
  }

  @objc(pipActionStop:)
  func pipActionStop(_: NSObject) {
    Task { @MainActor [weak self] in
      self?.stop()
    }
  }
}

final class MacNativePiPMediaController: NSObject, @unchecked Sendable {
  weak var player: Player?

  @objc func play() {
    Task { @MainActor [weak self] in
      guard let player = self?.player else { return }
      if player.state == .idle || player.state == .stopped {
        try? player.play()
      } else {
        player.resume()
      }
    }
  }

  @objc func pause() {
    Task { @MainActor [weak self] in
      self?.player?.pause()
    }
  }

  @objc(seekBy:completion:)
  func seek(by offset: Int64, completion: (() -> Void)?) {
    nonisolated(unsafe) let completion = completion
    Task { @MainActor [weak self] in
      guard let player = self?.player else {
        completion?()
        return
      }

      let duration = player.duration?.milliseconds ?? Int64.max
      let target = max(0, min(player.currentTime.milliseconds + offset, duration))
      player.seek(to: .milliseconds(target))
      completion?()
    }
  }

  @objc func mediaLength() -> Int64 {
    pipMainActorSync { [weak self] in
      guard let player = self?.player else { return 0 }
      return max(libvlc_media_player_get_length(player.pointer), 0)
    }
  }

  @objc func mediaTime() -> Int64 {
    pipMainActorSync { [weak self] in
      guard let player = self?.player else { return 0 }
      return max(libvlc_media_player_get_time(player.pointer), 0)
    }
  }

  @objc func isMediaSeekable() -> Bool {
    pipMainActorSync { [weak self] in
      guard let player = self?.player else { return false }
      return libvlc_media_player_is_seekable(player.pointer)
    }
  }

  @objc func isMediaPlaying() -> Bool {
    pipMainActorSync { [weak self] in
      guard let player = self?.player else { return false }
      return player.isPlaybackRequestedActive
    }
  }
}

#endif
