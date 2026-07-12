import SwiftUI
import SwiftVLC
import UIKit

/// A deterministic, physical-device-only lane for the live-stream PiP
/// regression. The URL is supplied through `-UITestPiPLiveURL`; production
/// showcase launches never discover or play it accidentally.
struct PiPLiveValidationCase: View {
  @State private var player = Player()
  @State private var controller: PiPController?
  @State private var playbackError: String?

  private var renderingPath: PiPValidationRenderingPath {
    PiPValidationRenderingPath(
      rawValue: LaunchArguments.pipRenderingPathValue ?? "native"
    ) ?? .native
  }

  var body: some View {
    // Statistics are point-in-time snapshots. Reading the observable clock
    // makes SwiftUI refresh this validation panel as playback advances.
    _ = player.currentTime

    return Form {
      Section {
        videoSurface
          // Keep the measurement rows on-screen on both phones and tablets.
          // This validation surface tests PiP pixels, not responsive inline
          // sizing; the video layer itself remains aspect-fit.
          .frame(height: 260)
          .listRowInsets(EdgeInsets())
          .accessibilityIdentifier(AccessibilityID.PiPLiveValidation.videoView)
      }

      Section("Measured state") {
        valueRow(
          "Playback",
          value: String(describing: player.state),
          identifier: AccessibilityID.PiPLiveValidation.stateLabel
        )
        valueRow(
          "Duration",
          value: player.duration == nil ? "unknown" : "known",
          identifier: AccessibilityID.PiPLiveValidation.durationLabel
        )
        valueRow(
          "Displayed pictures",
          value: String(player.statistics?.displayedPictures ?? 0),
          identifier: AccessibilityID.PiPLiveValidation.displayedPicturesLabel
        )
        valueRow(
          "PiP possible",
          value: controller?.isPossible == true ? "yes" : "no",
          identifier: AccessibilityID.PiPLiveValidation.possibleLabel
        )
        valueRow(
          "PiP active",
          value: controller?.isActive == true ? "yes" : "no",
          identifier: AccessibilityID.PiPLiveValidation.activeLabel
        )
      }

      Section("Picture in Picture") {
        Button(
          controller?.isActive == true ? "Stop PiP" : "Start PiP",
          systemImage: "pip",
          action: togglePictureInPicture
        )
        .accessibilityIdentifier(AccessibilityID.PiPLiveValidation.toggleButton)
        .disabled(controller?.isPossible != true)

        if let playbackError {
          Text(playbackError)
            .foregroundStyle(.red)
            .accessibilityIdentifier(AccessibilityID.PiPLiveValidation.errorLabel)
        }
      }
    }
    .showcaseFormStyle()
    .navigationTitle("Live PiP validation")
    .task { startPlayback() }
    .onDisappear { player.stop() }
  }

  @ViewBuilder
  private var videoSurface: some View {
    switch renderingPath {
    case .native:
      PiPVideoView(
        player,
        controller: $controller,
        startsAutomaticallyFromInline: false
      )
    case .direct:
      DirectPiPValidationSurface(player: player, controller: $controller)
    }
  }

  private func togglePictureInPicture() {
    controller?.toggle()
  }

  private func startPlayback() {
    guard let url = LaunchArguments.pipLiveURLValue else {
      playbackError = "Missing -UITestPiPLiveURL"
      return
    }

    do {
      try player.play(url: url)
    } catch {
      playbackError = String(describing: error)
    }
  }

  private func valueRow(_ title: String, value: String, identifier: String) -> some View {
    HStack {
      Text(title)
      Spacer()
      Text(value)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier(identifier)
    }
  }
}

private enum PiPValidationRenderingPath: String {
  case native
  case direct
}

/// Hosts the public direct sample-buffer PiP layer so the device suite can
/// validate that route independently from libVLC's native drawable backend.
private struct DirectPiPValidationSurface: UIViewRepresentable {
  let player: Player
  @Binding var controller: PiPController?

  func makeUIView(context: Context) -> DirectPiPLayerHostView {
    let view = DirectPiPLayerHostView()
    let controller = PiPController(player: player)
    view.displayLayer = controller.layer
    context.coordinator.controller = controller
    context.coordinator.publish(controller, to: $controller)
    return view
  }

  func updateUIView(_: DirectPiPLayerHostView, context: Context) {
    context.coordinator.publish(context.coordinator.controller, to: $controller)
  }

  static func dismantleUIView(
    _ uiView: DirectPiPLayerHostView,
    coordinator: Coordinator
  ) {
    coordinator.controller?.stop()
    uiView.displayLayer = nil
    coordinator.clearBinding()
    coordinator.controller = nil
  }

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  @MainActor
  final class Coordinator {
    var controller: PiPController?
    private var generation: UInt64 = 0
    private var binding: Binding<PiPController?>?
    private weak var publishedController: PiPController?

    func publish(
      _ controller: PiPController?,
      to binding: Binding<PiPController?>
    ) {
      if
        publishedController === controller,
        binding.wrappedValue === controller {
        self.binding = binding
        return
      }

      generation &+= 1
      let publicationGeneration = generation
      self.binding = binding
      publishedController = controller
      Task { @MainActor [weak self, weak controller] in
        guard
          let self,
          generation == publicationGeneration
        else { return }
        binding.wrappedValue = controller
      }
    }

    func clearBinding() {
      generation &+= 1
      let previousBinding = binding
      let previousController = publishedController
      binding = nil
      publishedController = nil
      Task { @MainActor in
        guard
          let previousBinding,
          let previousController,
          previousBinding.wrappedValue === previousController
        else { return }
        previousBinding.wrappedValue = nil
      }
    }
  }
}

@MainActor
private final class DirectPiPLayerHostView: UIView {
  var displayLayer: CALayer? {
    didSet {
      oldValue?.removeFromSuperlayer()
      if let displayLayer {
        layer.addSublayer(displayLayer)
        setNeedsLayout()
      }
    }
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    displayLayer?.frame = bounds
  }
}
