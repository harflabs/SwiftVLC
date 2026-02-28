import CLibVLC
import SwiftUI

#if canImport(UIKit)
    import UIKit

    /// A SwiftUI view that renders video from a ``Player``.
    ///
    /// This is the entire public API for video rendering — one line:
    /// ```swift
    /// VideoView(player)
    ///     .frame(maxWidth: .infinity)
    /// ```
    ///
    /// No `UIViewRepresentable` coordinator needed. No delegate proxy.
    /// No lifecycle management. Just works.
    public struct VideoView: UIViewRepresentable {
        private let player: Player

        /// Creates a video view attached to a player.
        /// - Parameter player: The player whose video output to display.
        public init(_ player: Player) {
            self.player = player
        }

        public func makeUIView(context _: Context) -> UIView {
            let surface = VideoSurface()
            surface.backgroundColor = .black
            surface.clipsToBounds = true
            surface.isUserInteractionEnabled = false
            return surface
        }

        public func updateUIView(_ uiView: UIView, context _: Context) {
            (uiView as? VideoSurface)?.attach(to: player)
        }

        public static func dismantleUIView(_ uiView: UIView, coordinator _: ()) {
            (uiView as? VideoSurface)?.detach()
        }
    }

    /// Internal UIView that serves as the video drawable surface.
    ///
    /// libVLC's `set_nsobject` creates its own rendering subview and adds it
    /// to the drawable view. We handle sublayer frame updates automatically.
    @MainActor
    final class VideoSurface: UIView {
        private weak var attachedPlayer: Player?
        private var lastBounds: CGRect = .zero

        func attach(to player: Player) {
            guard attachedPlayer !== player else { return }
            attachedPlayer = player
            let viewPtr = Unmanaged.passUnretained(self).toOpaque()
            libvlc_media_player_set_nsobject(player.pointer, viewPtr)
        }

        func detach() {
            guard let player = attachedPlayer else { return }
            libvlc_media_player_set_nsobject(player.pointer, nil)
            attachedPlayer = nil
        }

        override func layoutSubviews() {
            super.layoutSubviews()

            // First valid layout — trigger attach if pending
            if attachedPlayer != nil, lastBounds == .zero, bounds.width > 0 {
                let viewPtr = Unmanaged.passUnretained(self).toOpaque()
                libvlc_media_player_set_nsobject(attachedPlayer!.pointer, viewPtr)
            }

            // Keep VLC's rendering sublayer sized to our bounds
            if bounds != lastBounds, bounds.width > 0, bounds.height > 0 {
                lastBounds = bounds
                layer.sublayers?.forEach { sublayer in
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    sublayer.frame = bounds
                    CATransaction.commit()
                }
            }
        }
    }

#elseif canImport(AppKit)
    import AppKit

    public struct VideoView: NSViewRepresentable {
        private let player: Player

        public init(_ player: Player) {
            self.player = player
        }

        public func makeNSView(context _: Context) -> NSView {
            let surface = VideoSurface()
            surface.wantsLayer = true
            surface.layer?.backgroundColor = NSColor.black.cgColor
            return surface
        }

        public func updateNSView(_ nsView: NSView, context _: Context) {
            (nsView as? VideoSurface)?.attach(to: player)
        }

        public static func dismantleNSView(_ nsView: NSView, coordinator _: ()) {
            (nsView as? VideoSurface)?.detach()
        }
    }

    @MainActor
    final class VideoSurface: NSView {
        private weak var attachedPlayer: Player?
        private var lastBounds: CGRect = .zero

        func attach(to player: Player) {
            guard attachedPlayer !== player else { return }
            attachedPlayer = player
            let viewPtr = Unmanaged.passUnretained(self).toOpaque()
            libvlc_media_player_set_nsobject(player.pointer, viewPtr)
        }

        func detach() {
            guard let player = attachedPlayer else { return }
            libvlc_media_player_set_nsobject(player.pointer, nil)
            attachedPlayer = nil
        }

        override func layout() {
            super.layout()

            if bounds != lastBounds, bounds.width > 0, bounds.height > 0 {
                lastBounds = bounds
                layer?.sublayers?.forEach { sublayer in
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    sublayer.frame = bounds
                    CATransaction.commit()
                }
            }
        }
    }

#endif
