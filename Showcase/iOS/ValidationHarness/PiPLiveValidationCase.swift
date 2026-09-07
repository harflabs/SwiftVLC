import SwiftUI
@_spi(Qualification) import SwiftVLC
import UIKit

/// A deterministic, physical-device-only lane for the live-stream PiP
/// regression. The URL is supplied through `-UITestPiPLiveURL`; production
/// showcase launches never discover or play it accidentally.
struct PiPLiveValidationCase: View {
  @Environment(\.scenePhase) private var scenePhase
  @State private var player = Player()
  @State private var controller: PiPController?
  @State private var playbackError: String?
  @State private var capturedRendererDiagnostics = "not-captured"
  @State private var diagnosticCaptureOrdinal: UInt64 = 0
  @State private var lifecycleEvents: [String] = []
  @State private var backgroundAudioObservation = "none"
  @State private var backgroundAudioProbe: Task<Void, Never>?

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
          .accessibilityValue(Text(capturedRendererDiagnostics))
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
          "Played audio buffers",
          value: String(player.statistics?.playedAudioBuffers ?? 0),
          identifier: AccessibilityID.PiPLiveValidation.playedAudioBuffersLabel
        )
        valueRow(
          "Background audio probe",
          value: backgroundAudioObservation,
          identifier: AccessibilityID.PiPLiveValidation.backgroundAudioObservationLabel
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
        valueRow(
          "Linear playback",
          value: controller?.playbackQualificationSnapshot.requiresLinearPlayback == true
            ? "yes" : "no",
          identifier: AccessibilityID.PiPLiveValidation.linearPlaybackLabel
        )
        valueRow(
          "Playback range",
          value: controller?.playbackQualificationSnapshot.durationMilliseconds == nil
            ? "unbounded" : "finite",
          identifier: AccessibilityID.PiPLiveValidation.playbackRangeLabel
        )
        valueRow(
          "Lifecycle",
          value: lifecycleEvents.isEmpty ? "none" : lifecycleEvents.joined(separator: "|"),
          identifier: AccessibilityID.PiPLiveValidation.lifecycleEventsLabel
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
    .toolbar {
      if renderingPath == .direct {
        // System PiP occupies the top-right corner on iPhone. Keep this
        // qualification-only probe on the opposite side so XCUI can capture
        // phase telemetry while the overlay is active.
        ToolbarItem(placement: .topBarLeading) {
          Button("Capture diagnostics", systemImage: "waveform.path.ecg") {
            captureRendererDiagnostics()
          }
          .accessibilityIdentifier(AccessibilityID.PiPLiveValidation.captureDiagnosticsButton)
          .accessibilityLabel("Capture diagnostics")
          .accessibilityValue(Text(capturedRendererDiagnostics))
        }
      }
    }
    .task { startPlayback() }
    .task(id: controller.map(ObjectIdentifier.init)) {
      lifecycleEvents.removeAll()
      guard let controller else { return }
      for await envelope in controller.pipEventEnvelopes {
        lifecycleEvents.append(lifecycleName(envelope))
      }
    }
    .onChange(of: controller?.isPossible) { _, _ in
      captureRendererDiagnostics()
    }
    .onChange(of: controller?.isActive) { _, _ in
      captureRendererDiagnostics()
    }
    .onChange(of: scenePhase) { _, newPhase in
      switch newPhase {
      case .background:
        startBackgroundAudioProbe()
      case .active:
        captureRendererDiagnostics()
      default:
        break
      }
    }
    .onDisappear {
      backgroundAudioProbe?.cancel()
      player.stop()
    }
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

  private func captureRendererDiagnostics() {
    diagnosticCaptureOrdinal &+= 1
    guard renderingPath == .direct, let controller else {
      capturedRendererDiagnostics = "capture=\(diagnosticCaptureOrdinal);not-direct"
      return
    }
    let snapshot = controller.timebaseDiagnosticSnapshot()
    capturedRendererDiagnostics = [
      "capture=\(diagnosticCaptureOrdinal)",
      "decoded=\(snapshot.decodedFrameCount)",
      "contentChanges=\(snapshot.decodedContentChangeCount)",
      "fingerprint=\(snapshot.lastDecodedContentFingerprint.map(String.init) ?? "nil")",
      "renderGeneration=\(snapshot.renderGeneration)",
      "presentationCopyRequired=\(snapshot.presentationCopyRequired)",
      "presentationCopies=\(snapshot.presentationCopyFrameCount)",
      "presentationCopyFailures=\(snapshot.presentationCopyFailureCount)",
      "flushRequests=\(snapshot.displayLayerFlushRequestCount)",
      "decodePoolFailures=\(snapshot.decodePoolAllocationFailureCount)",
      "decodePoolStatus=\(snapshot.lastDecodePoolAllocationStatus.map(String.init) ?? "nil")",
      "renderPoolFailures=\(snapshot.renderPoolAllocationFailureCount)",
      "renderPoolStatus=\(snapshot.lastRenderPoolAllocationStatus.map(String.init) ?? "nil")",
      "lockAttempts=\(snapshot.vmemLockAttemptCount)",
      "lockSuccesses=\(snapshot.vmemLockSuccessCount)",
      "poolUnavailable=\(snapshot.vmemPoolUnavailableCount)",
      "baseLockFailures=\(snapshot.vmemBaseAddressLockFailureCount)",
      "pendingInstallFailures=\(snapshot.vmemPendingInstallFailureCount)",
      "unlocks=\(snapshot.vmemUnlockCallbackCount)",
      "displayCallbacks=\(snapshot.vmemDisplayCallbackCount)",
      "displayConsumeFailures=\(snapshot.vmemDisplayConsumeFailureCount)",
      "enqueued=\(snapshot.enqueuedFrameCount)",
      "delivered=\(snapshot.deliveredFrameCount)",
      "dropped=\(snapshot.droppedFrameCount)",
      "media=\(snapshot.mediaTimeSeconds)",
      "timebase=\(snapshot.controlTimebaseSeconds ?? -1)",
      "rate=\(snapshot.controlTimebaseRate ?? -1)",
      "lastPTS=\(snapshot.lastDeliveredSampleTimeSeconds ?? -1)",
      "layer=\(snapshot.displayLayerStatus)",
      "ready=\(snapshot.isDisplayLayerReadyForDisplay)",
      "requiresFlush=\(snapshot.displayLayerRequiresFlush)",
      "layerError=\(snapshot.displayLayerError ?? "nil")"
    ].joined(separator: ";")
  }

  private func startBackgroundAudioProbe() {
    backgroundAudioProbe?.cancel()
    let before = player.statistics?.playedAudioBuffers ?? 0
    backgroundAudioObservation = "sampling:\(before)"
    backgroundAudioProbe = Task { @MainActor in
      try? await Task.sleep(for: .seconds(3))
      guard !Task.isCancelled, UIApplication.shared.applicationState == .background else { return }
      let after = player.statistics?.playedAudioBuffers ?? 0
      backgroundAudioObservation = "\(before):\(after)"
    }
  }

  private func lifecycleName(_ envelope: PiPEventEnvelope) -> String {
    switch envelope.event {
    case .willStart:
      "willStart"
    case .didStart:
      "didStart"
    case .willStop(let reason):
      "willStop:\(envelope.stopCause?.rawValue ?? String(describing: reason))"
    case .didStop(let reason):
      "didStop:\(envelope.stopCause?.rawValue ?? String(describing: reason))"
    case .failedToStart:
      "failedToStart"
    }
  }

  private func valueRow(_ title: String, value: String, identifier: String) -> some View {
    HStack {
      Text(title)
      Spacer()
      Text(value)
        .foregroundStyle(.secondary)
    }
    .qualificationAccessibilityValue(label: title, value: value, identifier: identifier)
  }
}

private enum PiPValidationRenderingPath: String {
  case native
  case direct
}

/// Hosts the public direct sample-buffer PiP layer so the device suite can
/// validate that route independently from libVLC's native drawable backend.
struct DirectPiPValidationSurface: UIViewRepresentable {
  let player: Player
  @Binding var controller: PiPController?

  func makeUIView(context: Context) -> DirectPiPLayerHostView {
    let view = DirectPiPLayerHostView()
    let controller = PiPController(player: player)
    controller.enableFrameContentDiagnostics()
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
final class DirectPiPLayerHostView: UIView {
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
