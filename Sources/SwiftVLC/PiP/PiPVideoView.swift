#if os(iOS)
    import AVFoundation
    import SwiftUI
    import UIKit

    /// A SwiftUI view that renders video via `AVSampleBufferDisplayLayer`,
    /// enabling Picture-in-Picture support on iOS.
    ///
    /// Unlike ``VideoView`` which uses `libvlc_media_player_set_nsobject()`,
    /// this view uses vmem callbacks for rendering. The two approaches are
    /// mutually exclusive — use one or the other for a given player.
    ///
    /// ```swift
    /// @State private var pipController: PiPController?
    ///
    /// PiPVideoView(player, controller: $pipController)
    ///     .onAppear { pipController?.start() }
    /// ```
    public struct PiPVideoView: UIViewRepresentable {
        private let player: Player
        private let controllerBinding: Binding<PiPController?>?

        /// Creates a PiP-capable video view.
        /// - Parameters:
        ///   - player: The player whose video output to display.
        ///   - controller: Optional binding to receive the `PiPController` for external control.
        public init(_ player: Player, controller: Binding<PiPController?>? = nil) {
            self.player = player
            controllerBinding = controller
        }

        public func makeUIView(context: Context) -> UIView {
            let controller = PiPController(player: player)
            let displayLayer = controller.layer

            let container = SampleBufferVideoView(displayLayer: displayLayer)
            container.backgroundColor = .black
            container.clipsToBounds = true

            context.coordinator.pipController = controller
            context.coordinator.displayLayer = displayLayer

            // Defer binding update — SwiftUI doesn't allow state changes during view construction
            let binding = controllerBinding
            Task { @MainActor in
                binding?.wrappedValue = controller
            }

            return container
        }

        public func updateUIView(_: UIView, context _: Context) {
            // Layout is handled by SampleBufferVideoView.layoutSubviews
        }

        public static func dismantleUIView(_: UIView, coordinator: Coordinator) {
            coordinator.pipController?.stop()
            coordinator.displayLayer?.removeFromSuperlayer()
            coordinator.pipController = nil
            coordinator.displayLayer = nil
        }

        public func makeCoordinator() -> Coordinator {
            Coordinator()
        }

        @MainActor
        public final class Coordinator {
            var pipController: PiPController?
            var displayLayer: AVSampleBufferDisplayLayer?
        }
    }

    /// UIView subclass that keeps the AVSampleBufferDisplayLayer
    /// sized to fill its bounds on every layout pass.
    private final class SampleBufferVideoView: UIView {
        private let displayLayer: AVSampleBufferDisplayLayer

        init(displayLayer: AVSampleBufferDisplayLayer) {
            self.displayLayer = displayLayer
            super.init(frame: .zero)
            layer.addSublayer(displayLayer)
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            // Disable implicit animations so the layer doesn't animate to the new size
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            displayLayer.frame = bounds
            CATransaction.commit()
        }
    }

#elseif os(macOS)
    import AppKit
    import AVFoundation
    import SwiftUI

    /// A SwiftUI view that renders video via `AVSampleBufferDisplayLayer`,
    /// enabling Picture-in-Picture support on macOS.
    public struct PiPVideoView: NSViewRepresentable {
        private let player: Player
        private let controllerBinding: Binding<PiPController?>?

        public init(_ player: Player, controller: Binding<PiPController?>? = nil) {
            self.player = player
            controllerBinding = controller
        }

        public func makeNSView(context: Context) -> NSView {
            let controller = PiPController(player: player)
            let displayLayer = controller.layer

            let container = SampleBufferVideoView(displayLayer: displayLayer)

            context.coordinator.pipController = controller
            context.coordinator.displayLayer = displayLayer

            let binding = controllerBinding
            Task { @MainActor in
                binding?.wrappedValue = controller
            }

            return container
        }

        public func updateNSView(_: NSView, context _: Context) {}

        public static func dismantleNSView(_: NSView, coordinator: Coordinator) {
            coordinator.pipController?.stop()
            coordinator.displayLayer?.removeFromSuperlayer()
            coordinator.pipController = nil
            coordinator.displayLayer = nil
        }

        public func makeCoordinator() -> Coordinator {
            Coordinator()
        }

        @MainActor
        public final class Coordinator {
            var pipController: PiPController?
            var displayLayer: AVSampleBufferDisplayLayer?
        }
    }

    private final class SampleBufferVideoView: NSView {
        private let displayLayer: AVSampleBufferDisplayLayer

        init(displayLayer: AVSampleBufferDisplayLayer) {
            self.displayLayer = displayLayer
            super.init(frame: .zero)
            wantsLayer = true
            layer?.backgroundColor = NSColor.black.cgColor
            layer?.addSublayer(displayLayer)
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError()
        }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            displayLayer.frame = bounds
            CATransaction.commit()
        }
    }

#endif
