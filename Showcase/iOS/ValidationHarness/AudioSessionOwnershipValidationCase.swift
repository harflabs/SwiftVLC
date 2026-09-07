import AVFoundation
import Combine
import SwiftUI
@_spi(Qualification) import SwiftVLC

/// Physical proof that SwiftVLC activates lazily, reference-counts multiple
/// native outputs, relinquishes the true final owner, and leaves a host-owned
/// AVAudioSession untouched in application-managed mode.
struct AudioSessionOwnershipValidationCase: View {
  @State private var phase = "ready"
  @State private var result = "not-run"
  @State private var errorMessage: String?
  @State private var interruptionBeganCount = 0
  @State private var interruptionEndedCount = 0
  @State private var interruptionNotificationSequence:
    [AppleAudioInterruptionNotificationRecord] = []
  @State private var retainedProbePlayer: Player?
  @State private var runTask: Task<Void, Never>?
  @State private var focusProbeContinuation: CheckedContinuation<Void, Never>?

  var body: some View {
    Form {
      Section("Measured state") {
        valueRow(
          "Phase",
          value: phase,
          identifier: AccessibilityID.AudioSessionOwnershipValidation.phaseLabel
        )
        valueRow(
          "Interruptions",
          value: "\(interruptionBeganCount):\(interruptionEndedCount)",
          identifier:
          AccessibilityID.AudioSessionOwnershipValidation.interruptionCountsLabel
        )
        valueRow(
          "Qualification",
          value: result,
          identifier: AccessibilityID.AudioSessionOwnershipValidation.resultLabel
        )
      }

      Section {
        Button("Run ownership sequence") {
          runTask?.cancel()
          runTask = Task { await runOwnershipSequence() }
        }
        .accessibilityIdentifier(
          AccessibilityID.AudioSessionOwnershipValidation.runButton
        )
        .disabled(phase != "ready")

        Button("Continue after external focus probe") {
          resumeFocusProbe()
        }
        .accessibilityIdentifier(
          AccessibilityID.AudioSessionOwnershipValidation.continueFocusProbeButton
        )
        .disabled(!phase.hasSuffix("awaiting-focus-probe"))

        if let errorMessage {
          Text(errorMessage)
            .foregroundStyle(.red)
            .accessibilityIdentifier(
              AccessibilityID.AudioSessionOwnershipValidation.errorLabel
            )
        }
      } header: {
        Text("Qualification controls")
      } footer: {
        Text(
          "The sequence forces both pinned native outputs, releases them one "
            + "at a time in both orders, then plays through both outputs in "
            + "application-managed mode. XCTest supplies the staged external "
            + "audio-focus probes."
        )
      }
    }
    .showcaseFormStyle()
    .navigationTitle("Audio-session ownership")
    .onReceive(
      NotificationCenter.default.publisher(
        for: AVAudioSession.interruptionNotification,
        object: AVAudioSession.sharedInstance()
      )
    ) { notification in
      recordInterruption(notification)
    }
    .onDisappear {
      resumeFocusProbe()
      runTask?.cancel()
      retainedProbePlayer?.stop()
    }
  }

  private func runOwnershipSequence() async {
    let session = AVAudioSession.sharedInstance()
    var hostActivatedSession = false
    defer {
      if hostActivatedSession {
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
      }
    }

    do {
      guard LaunchArguments.isUITestMode else {
        throw AppleAudioQualificationFailure("This surface is UI-test only")
      }
      guard let audioURL = LaunchArguments.audioSessionOwnershipURLValue else {
        throw AppleAudioQualificationFailure(
          "Missing per-attempt audio-session ownership fixture"
        )
      }
      interruptionBeganCount = 0
      interruptionEndedCount = 0
      interruptionNotificationSequence = []
      phase = "checking-idle-construction"

      let probe = Player()
      retainedProbePlayer = probe
      let idleSessionBefore = AppleAudioQualificationSupport.sessionRecord(session)
      let idleBrokerBefore = try await AppleAudioQualificationSupport.checkpoint(probe)
      try validateIdle(idleBrokerBefore)

      let audioUnitInstance = try VLCInstance(
        arguments: VLCInstance.defaultArguments + ["--aout=audiounit_ios"]
      )
      let sampleBufferInstance = try VLCInstance(
        arguments: VLCInstance.defaultArguments + ["--aout=avsamplebuffer"]
      )
      let idleAudioUnitPlayer = Player(instance: audioUnitInstance)
      let idleSampleBufferPlayer = Player(instance: sampleBufferInstance)
      try await Task.sleep(for: .milliseconds(500))
      let idleSessionAfter = AppleAudioQualificationSupport.sessionRecord(session)
      let idleBrokerAfter = try await AppleAudioQualificationSupport.checkpoint(probe)
      withExtendedLifetime((idleAudioUnitPlayer, idleSampleBufferPlayer)) {}
      guard idleSessionAfter == idleSessionBefore else {
        throw AppleAudioQualificationFailure("Idle player construction mutated AVAudioSession")
      }
      try validateIdle(idleBrokerAfter)
      guard
        brokerOwnershipFields(idleBrokerAfter.native)
        == brokerOwnershipFields(idleBrokerBefore.native)
      else {
        throw AppleAudioQualificationFailure(
          "Idle player construction mutated native broker ownership"
        )
      }
      // The separately signed XCTest runner must be able to take exclusive
      // focus now. A configuration snapshot alone cannot prove AVAudioSession
      // was inactive because AVAudioSession exposes no public isActive getter.
      try await awaitFocusProbe(phase: "idle-constructed-awaiting-focus-probe")

      let directOrder = try await runLibraryManagedCycle(
        firstModule: "audiounit_ios",
        secondModule: "avsamplebuffer",
        firstChildLog: "library-order1-audiounit",
        secondChildLog: "library-order1-avsamplebuffer",
        url: audioURL,
        probe: probe
      )
      try await awaitFocusProbe(phase: "library-order1-released-awaiting-focus-probe")

      let inverseOrder = try await runLibraryManagedCycle(
        firstModule: "avsamplebuffer",
        secondModule: "audiounit_ios",
        firstChildLog: "library-order2-avsamplebuffer",
        secondChildLog: "library-order2-audiounit",
        url: audioURL,
        probe: probe
      )
      try await awaitFocusProbe(phase: "library-order2-released-awaiting-focus-probe")

      phase = "configuring-application-managed-session"
      try session.setCategory(
        .playback,
        mode: .spokenAudio,
        policy: .longFormAudio,
        options: []
      )
      try session.setActive(true)
      hostActivatedSession = true
      let applicationSessionReference = AppleAudioQualificationSupport.sessionRecord(session)
      let applicationAudioUnit = try await runApplicationManagedCycle(
        module: "audiounit_ios",
        childLog: "application-audiounit",
        url: audioURL,
        session: session,
        expectedSession: applicationSessionReference,
        expectedOwnership: inverseOrder.afterFinalOutputRelease.native,
        probe: probe
      )
      try await awaitFocusProbe(
        phase: "application-audiounit-released-awaiting-focus-probe"
      )
      // The external probe deliberately interrupted the host-owned session.
      // Reactivation remains a host responsibility in application-managed mode.
      try session.setActive(true)
      let applicationSampleBuffer = try await runApplicationManagedCycle(
        module: "avsamplebuffer",
        childLog: "application-avsamplebuffer",
        url: audioURL,
        session: session,
        expectedSession: applicationSessionReference,
        expectedOwnership: inverseOrder.afterFinalOutputRelease.native,
        probe: probe
      )
      try await awaitFocusProbe(
        phase: "application-avsamplebuffer-released-awaiting-focus-probe"
      )
      try session.setActive(true)
      let brokerSnapshots = [
        idleBrokerBefore.native,
        idleBrokerAfter.native,
        directOrder.firstOutputActive.native,
        directOrder.bothOutputsActive.native,
        directOrder.afterFirstOutputRelease.native,
        directOrder.afterFinalOutputRelease.native,
        inverseOrder.firstOutputActive.native,
        inverseOrder.bothOutputsActive.native,
        inverseOrder.afterFirstOutputRelease.native,
        inverseOrder.afterFinalOutputRelease.native,
        applicationAudioUnit.brokerBeforePlayback,
        applicationAudioUnit.brokerDuringPlayback,
        applicationAudioUnit.brokerAfterPlayback,
        applicationSampleBuffer.brokerBeforePlayback,
        applicationSampleBuffer.brokerDuringPlayback,
        applicationSampleBuffer.brokerAfterPlayback
      ]
      guard
        brokerSnapshots.allSatisfy({ $0.brokerPhase == "ready" }),
        brokerSnapshots.allSatisfy({
          brokerEpochFields($0) == brokerEpochFields(idleBrokerBefore.native)
        })
      else {
        throw AppleAudioQualificationFailure(
          "Ownership sequence crossed a media-services broker epoch"
        )
      }
      try session.setActive(false, options: .notifyOthersOnDeactivation)
      hostActivatedSession = false

      let raw = AudioSessionOwnershipQualificationRawResult(
        formatVersion: 3,
        libraryManagedForcedModules: ["audiounit_ios", "avsamplebuffer"],
        applicationManagedForcedModules: ["audiounit_ios", "avsamplebuffer"],
        idleSessionBeforePlayerConstruction: idleSessionBefore,
        idleSessionAfterPlayerConstruction: idleSessionAfter,
        idleBrokerBeforePlayerConstruction: idleBrokerBefore.native,
        idleBrokerAfterPlayerConstruction: idleBrokerAfter.native,
        libraryManagedCycles: [directOrder, inverseOrder],
        applicationManagedCycles: [applicationAudioUnit, applicationSampleBuffer],
        interruptionNotificationSequence: interruptionNotificationSequence
      )
      result = try AppleAudioQualificationSupport.encodedLabel(raw)
      phase = "complete-awaiting-host-release-focus-probe"
    } catch is CancellationError {
      phase = "cancelled"
    } catch {
      fail(error)
    }
  }

  private func runLibraryManagedCycle(
    firstModule: String,
    secondModule: String,
    firstChildLog: String,
    secondChildLog: String,
    url: URL,
    probe: Player
  )
    async throws -> AppleAudioLibraryManagedOwnershipCycleRecord {
    phase = "starting-\(firstModule)-then-\(secondModule)"
    let initial = try await AppleAudioQualificationSupport.checkpoint(probe)
    let firstInstance = try VLCInstance(
      arguments: VLCInstance.defaultArguments + ["--aout=\(firstModule)", "--no-video"]
    )
    let secondInstance = try VLCInstance(
      arguments: VLCInstance.defaultArguments + ["--aout=\(secondModule)", "--no-video"]
    )
    UITestSupport.startAdditionalLogMirrorIfRequested(
      from: firstInstance,
      childName: firstChildLog
    )
    UITestSupport.startAdditionalLogMirrorIfRequested(
      from: secondInstance,
      childName: secondChildLog
    )
    let first = Player(instance: firstInstance)
    let second = Player(instance: secondInstance)
    defer {
      first.stop()
      second.stop()
    }

    try first.play(url: url)
    try await waitForAudioProgress(first, above: 0)
    let firstActive = try await AppleAudioQualificationSupport.checkpoint(first)
    guard
      firstActive.native.liveOutputCount > 0,
      firstActive.native.brokerActiveOwnerCount == 1,
      firstActive.native.brokerLiveLeaseCount == 0,
      brokerDeactivationFields(firstActive.native)
      == brokerDeactivationFields(initial.native)
    else {
      throw AppleAudioQualificationFailure("First library output owns an invalid count")
    }

    try second.play(url: url)
    try await waitForAudioProgress(second, above: 0)
    let bothActive = try await AppleAudioQualificationSupport.checkpoint(second)
    guard
      bothActive.native.liveOutputCount > 0,
      bothActive.native.brokerActiveOwnerCount == 2,
      bothActive.native.brokerLiveLeaseCount == 0,
      brokerDeactivationFields(bothActive.native)
      == brokerDeactivationFields(firstActive.native)
    else {
      throw AppleAudioQualificationFailure("Two library outputs were not co-owned")
    }
    let firstPlaybackStart = AppleAudioQualificationSupport.playbackRecord(from: first)
    try await Task.sleep(for: .seconds(2))
    let firstPlaybackEnd = AppleAudioQualificationSupport.playbackRecord(from: first)
    guard playbackAdvanced(from: firstPlaybackStart, to: firstPlaybackEnd) else {
      throw AppleAudioQualificationFailure("First concurrent native output did not advance")
    }
    let secondPlaybackStart = AppleAudioQualificationSupport.playbackRecord(from: second)

    await first.shutdown()
    try await AppleAudioQualificationSupport.waitUntil(timeout: .seconds(15)) {
      guard let snapshot = probe.appleAudioRecoveryQualificationSnapshot else {
        return false
      }
      return snapshot.brokerActiveOwnerCount == 1
        && snapshot.brokerLiveLeaseCount == 0
    }
    try await Task.sleep(for: .seconds(2))
    let secondPlaybackEnd = AppleAudioQualificationSupport.playbackRecord(from: second)
    let afterFirstRelease = try await AppleAudioQualificationSupport.checkpoint(second)
    guard
      afterFirstRelease.playerState == "playing",
      afterFirstRelease.playbackRequestedActive,
      afterFirstRelease.native.liveOutputCount > 0,
      afterFirstRelease.native.brokerActiveOwnerCount == 1,
      afterFirstRelease.native.brokerLiveLeaseCount == 0,
      playbackAdvanced(from: secondPlaybackStart, to: secondPlaybackEnd),
      brokerDeactivationFields(afterFirstRelease.native)
      == brokerDeactivationFields(bothActive.native)
    else {
      throw AppleAudioQualificationFailure(
        "Non-final release stopped the surviving output or deactivated the session"
      )
    }

    await second.shutdown()
    try await AppleAudioQualificationSupport.waitUntil(timeout: .seconds(15)) {
      guard let snapshot = probe.appleAudioRecoveryQualificationSnapshot else {
        return false
      }
      return snapshot.brokerActiveOwnerCount == 0
        && snapshot.brokerLiveLeaseCount == 0
        && snapshot.brokerSuccessfulDeactivationCount
        == bothActive.native.brokerSuccessfulDeactivationCount + 1
    }
    let afterFinalRelease = try await AppleAudioQualificationSupport.checkpoint(probe)
    guard
      afterFinalRelease.native.brokerActiveOwnerCount == 0,
      afterFinalRelease.native.brokerLiveLeaseCount == 0,
      afterFinalRelease.native.brokerSuccessfulDeactivationCount
      == bothActive.native.brokerSuccessfulDeactivationCount + 1,
      afterFinalRelease.native.brokerFailedDeactivationCount
      == bothActive.native.brokerFailedDeactivationCount
    else {
      throw AppleAudioQualificationFailure("Final physical deactivation failed")
    }
    return AppleAudioLibraryManagedOwnershipCycleRecord(
      forcedModuleOrder: [firstModule, secondModule],
      firstOutputActive: firstActive,
      bothOutputsActive: bothActive,
      afterFirstOutputRelease: afterFirstRelease,
      afterFinalOutputRelease: afterFinalRelease,
      firstOutputPlaybackStart: firstPlaybackStart,
      firstOutputPlaybackEnd: firstPlaybackEnd,
      secondOutputPlaybackStart: secondPlaybackStart,
      secondOutputPlaybackEnd: secondPlaybackEnd
    )
  }

  private func runApplicationManagedCycle(
    module: String,
    childLog: String,
    url: URL,
    session: AVAudioSession,
    expectedSession: AppleAudioSessionConfigurationRecord,
    expectedOwnership: AppleAudioNativeRecoveryRecord,
    probe: Player
  )
    async throws -> AppleAudioApplicationManagedOwnershipCycleRecord {
    phase = "checking-application-managed-\(module)"
    let instance = try VLCInstance(
      arguments: VLCInstance.defaultArguments + ["--aout=\(module)", "--no-video"],
      appleAudioSessionPolicy: .applicationManaged
    )
    UITestSupport.startAdditionalLogMirrorIfRequested(from: instance, childName: childLog)
    let player = Player(instance: instance)
    defer { player.stop() }
    let sessionBefore = AppleAudioQualificationSupport.sessionRecord(session)
    let brokerBefore = try await AppleAudioQualificationSupport.checkpoint(player)
    try player.play(url: url)
    try await waitForAudioProgress(player, above: 0)
    let playbackStart = AppleAudioQualificationSupport.playbackRecord(from: player)
    try await Task.sleep(for: .seconds(2))
    let playbackEnd = AppleAudioQualificationSupport.playbackRecord(from: player)
    let brokerDuring = try await AppleAudioQualificationSupport.checkpoint(player)
    let sessionDuring = AppleAudioQualificationSupport.sessionRecord(session)
    guard
      sessionBefore == expectedSession,
      sessionDuring == expectedSession,
      playbackAdvanced(from: playbackStart, to: playbackEnd),
      brokerBefore.native.liveOutputCount == 0,
      brokerDuring.native.liveOutputCount > 0,
      brokerOwnershipFields(brokerBefore.native)
      == brokerOwnershipFields(expectedOwnership),
      brokerOwnershipFields(brokerDuring.native)
      == brokerOwnershipFields(expectedOwnership)
    else {
      throw AppleAudioQualificationFailure(
        "Application-managed \(module) playback mutated host ownership"
      )
    }
    await player.shutdown()
    let brokerAfter = try await AppleAudioQualificationSupport.checkpoint(probe)
    let sessionAfter = AppleAudioQualificationSupport.sessionRecord(session)
    guard
      sessionAfter == expectedSession,
      brokerAfter.native.liveOutputCount == 0,
      brokerOwnershipFields(brokerAfter.native)
      == brokerOwnershipFields(expectedOwnership)
    else {
      throw AppleAudioQualificationFailure(
        "Application-managed \(module) teardown mutated host ownership"
      )
    }
    return AppleAudioApplicationManagedOwnershipCycleRecord(
      forcedAudioOutputModule: module,
      sessionBeforePlayback: sessionBefore,
      sessionDuringPlayback: sessionDuring,
      sessionAfterPlayback: sessionAfter,
      brokerBeforePlayback: brokerBefore.native,
      brokerDuringPlayback: brokerDuring.native,
      brokerAfterPlayback: brokerAfter.native,
      playbackStart: playbackStart,
      playbackEnd: playbackEnd
    )
  }

  private func awaitFocusProbe(phase value: String) async throws {
    phase = value
    await withCheckedContinuation { continuation in
      focusProbeContinuation = continuation
    }
    try Task.checkCancellation()
  }

  private func resumeFocusProbe() {
    let continuation = focusProbeContinuation
    focusProbeContinuation = nil
    continuation?.resume()
  }

  private func playbackAdvanced(
    from start: AppleAudioPlaybackCounterRecord,
    to end: AppleAudioPlaybackCounterRecord
  ) -> Bool {
    end.mediaTimeMilliseconds > start.mediaTimeMilliseconds
      && end.playedAudioBuffers > start.playedAudioBuffers
  }

  private func validateIdle(_ checkpoint: AppleAudioRecoveryCheckpoint) throws {
    guard
      checkpoint.native.brokerPhase == "ready",
      checkpoint.native.brokerEpoch > 0,
      checkpoint.native.brokerActiveOwnerCount == 0,
      checkpoint.native.brokerLiveLeaseCount == 0,
      checkpoint.native.liveOutputCount == 0
    else {
      let native = checkpoint.native
      throw AppleAudioQualificationFailure(
        "Idle construction checkpoint failed: phase=\(native.brokerPhase), "
          + "epoch=\(native.brokerEpoch), owners=\(native.brokerActiveOwnerCount), "
          + "leases=\(native.brokerLiveLeaseCount), outputs=\(native.liveOutputCount)"
      )
    }
  }

  private func waitForAudioProgress(_ player: Player, above value: UInt64) async throws {
    try await AppleAudioQualificationSupport.waitUntil(timeout: .seconds(40)) {
      player.state == .playing
        && (player.statistics?.playedAudioBuffers ?? 0) > value
        && (player.appleAudioRecoveryQualificationSnapshot?.liveOutputCount ?? 0) > 0
    }
  }

  private func brokerOwnershipFields(
    _ value: AppleAudioNativeRecoveryRecord
  ) -> [UInt64] {
    [
      UInt64(value.brokerActiveOwnerCount),
      UInt64(value.brokerLiveLeaseCount),
      value.brokerSuccessfulDeactivationCount,
      value.brokerFailedDeactivationCount
    ]
  }

  private func brokerDeactivationFields(
    _ value: AppleAudioNativeRecoveryRecord
  ) -> [UInt64] {
    [
      value.brokerSuccessfulDeactivationCount,
      value.brokerFailedDeactivationCount
    ]
  }

  private func brokerEpochFields(
    _ value: AppleAudioNativeRecoveryRecord
  ) -> [UInt64] {
    [value.brokerEpoch, value.brokerResetEpoch]
  }

  private func recordInterruption(_ notification: Notification) {
    guard
      let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
      let type = AVAudioSession.InterruptionType(rawValue: rawType)
    else { return }
    let reasonRawValue =
      (notification.userInfo?[AVAudioSessionInterruptionReasonKey] as? NSNumber)?
        .uintValue
        ?? AVAudioSession.InterruptionReason.default.rawValue
    let kind: String
    switch type {
    case .began:
      kind = "began"
    case .ended:
      kind = "ended"
    @unknown default:
      return
    }
    interruptionNotificationSequence.append(
      AppleAudioInterruptionNotificationRecord(
        kind: kind,
        systemUptime: ProcessInfo.processInfo.systemUptime,
        reasonRawValue: reasonRawValue
      )
    )
    switch type {
    case .began:
      interruptionBeganCount += 1
    case .ended:
      interruptionEndedCount += 1
    @unknown default:
      break
    }
  }

  private func fail(_ error: any Error) {
    errorMessage = String(describing: error)
    result = "failed"
    phase = "failed"
  }

  private func valueRow(_ title: String, value: String, identifier: String) -> some View {
    HStack {
      Text(title)
      Spacer()
      Text(value)
        .font(.caption.monospacedDigit())
        .accessibilityIdentifier(identifier)
    }
  }
}
