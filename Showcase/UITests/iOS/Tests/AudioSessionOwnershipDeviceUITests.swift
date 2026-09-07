import AVFoundation
import XCTest

/// Physical, cross-process proof of lazy audio-session acquisition, exact
/// multi-owner release, final deactivation, and application-managed opt-out.
final class AudioSessionOwnershipDeviceUITests: ShowcaseIOSTestCase {
  private static let ownershipURLEnvironment =
    "SWIFTVLC_AUDIO_SESSION_OWNERSHIP_URL_BASE64"

  func test_libraryAndApplicationManagedOwnershipIsExact() throws {
    #if targetEnvironment(simulator)
    throw XCTSkip("Audio-session ownership qualification requires a physical iPhone")
    #else
    guard
      ProcessInfo.processInfo.environment[
        "SWIFTVLC_AUDIO_SESSION_OWNERSHIP_DEVICE"
      ] == "YES",
      let encodedOwnershipURL = ProcessInfo.processInfo.environment[
        Self.ownershipURLEnvironment
      ],
      let ownershipURLData = Data(base64Encoded: encodedOwnershipURL),
      let ownershipURLString = String(data: ownershipURLData, encoding: .utf8),
      let ownershipURL = URL(string: ownershipURLString),
      adaptiveAttemptToken(from: ownershipURL) != nil
    else {
      throw XCTSkip(
        "Enable the physical ownership lane with its per-attempt HLS URL"
      )
    }

    replaceLaunchArgument(
      LaunchArguments.audioSessionOwnershipURLBase64,
      with: encodedOwnershipURL
    )
    launch(route: .audioSessionOwnershipValidation)

    let phase = element(AccessibilityID.AudioSessionOwnershipValidation.phaseLabel)
    let interruptions = element(
      AccessibilityID.AudioSessionOwnershipValidation.interruptionCountsLabel
    )
    let run = app.buttons[AccessibilityID.AudioSessionOwnershipValidation.runButton]
    let continueFocusProbe = app.buttons[
      AccessibilityID.AudioSessionOwnershipValidation.continueFocusProbeButton
    ]
    let result = element(AccessibilityID.AudioSessionOwnershipValidation.resultLabel)
    let error = element(AccessibilityID.AudioSessionOwnershipValidation.errorLabel)

    try waitForPhaseOrFailure(
      phase,
      equals: "ready",
      error: error,
      timeout: 10
    )
    reveal(run)
    run.tap()

    let idleFocusProbe = try performExclusiveFocusProbe(
      phaseElement: phase,
      interruptionElement: interruptions,
      continueButton: continueFocusProbe,
      errorElement: error,
      expectedPhase: "idle-constructed-awaiting-focus-probe",
      expectedBeganBefore: 0,
      expectCandidateInterruption: false,
      tapContinue: true
    )
    let directReleaseFocusProbe = try performExclusiveFocusProbe(
      phaseElement: phase,
      interruptionElement: interruptions,
      continueButton: continueFocusProbe,
      errorElement: error,
      expectedPhase: "library-order1-released-awaiting-focus-probe",
      expectedBeganBefore: 0,
      expectCandidateInterruption: false,
      tapContinue: true
    )
    let inverseReleaseFocusProbe = try performExclusiveFocusProbe(
      phaseElement: phase,
      interruptionElement: interruptions,
      continueButton: continueFocusProbe,
      errorElement: error,
      expectedPhase: "library-order2-released-awaiting-focus-probe",
      expectedBeganBefore: 0,
      expectCandidateInterruption: false,
      tapContinue: true
    )
    let audioUnitManagedFocusProbe = try performExclusiveFocusProbe(
      phaseElement: phase,
      interruptionElement: interruptions,
      continueButton: continueFocusProbe,
      errorElement: error,
      expectedPhase: "application-audiounit-released-awaiting-focus-probe",
      expectedBeganBefore: 0,
      expectCandidateInterruption: true,
      tapContinue: true
    )
    let sampleBufferManagedFocusProbe = try performExclusiveFocusProbe(
      phaseElement: phase,
      interruptionElement: interruptions,
      continueButton: continueFocusProbe,
      errorElement: error,
      expectedPhase: "application-avsamplebuffer-released-awaiting-focus-probe",
      expectedBeganBefore: 1,
      expectCandidateInterruption: true,
      tapContinue: true
    )

    try waitForPhaseOrFailure(
      phase,
      equals: "complete-awaiting-host-release-focus-probe",
      error: error,
      timeout: 300
    )
    let hostReleaseFocusProbe = try performExclusiveFocusProbe(
      phaseElement: phase,
      interruptionElement: interruptions,
      continueButton: continueFocusProbe,
      errorElement: error,
      expectedPhase: "complete-awaiting-host-release-focus-probe",
      expectedBeganBefore: 2,
      expectCandidateInterruption: false,
      tapContinue: true
    )
    try waitForPhaseOrFailure(phase, equals: "complete", error: error, timeout: 10)
    let raw: AudioSessionOwnershipQualificationRawResult = try decodeResult(result.label)
    validate(raw)
    assertNoLibraryErrors()
    var payload = try jsonObject(raw)
    payload["idleConstruction"] = "pass"
    payload["multiOwnerRelease"] = "pass"
    payload["survivingOutputContinuity"] = "pass"
    payload["finalDeactivation"] = "pass"
    payload["applicationManagedNonMutation"] = "pass"
    payload["idleConstructionFocusProbe"] = idleFocusProbe
    payload["libraryReleaseFocusProbes"] = [
      focusProbe(
        directReleaseFocusProbe,
        adding: [
          "forcedModuleOrder": ["audiounit_ios", "avsamplebuffer"]
        ]
      ),
      focusProbe(
        inverseReleaseFocusProbe,
        adding: [
          "forcedModuleOrder": ["avsamplebuffer", "audiounit_ios"]
        ]
      )
    ]
    payload["applicationManagedReleaseFocusProbes"] = [
      focusProbe(
        audioUnitManagedFocusProbe,
        adding: ["forcedAudioOutputModule": "audiounit_ios"]
      ),
      focusProbe(
        sampleBufferManagedFocusProbe,
        adding: ["forcedAudioOutputModule": "avsamplebuffer"]
      )
    ]
    payload["hostReleaseFocusProbe"] = hostReleaseFocusProbe
    payload["libraryErrorCount"] = 0
    attachQualificationEvidence(payload, scenario: "audio-session-ownership")
    #endif
  }

  private func validate(_ raw: AudioSessionOwnershipQualificationRawResult) {
    XCTAssertEqual(raw.formatVersion, 4)
    XCTAssertEqual(
      raw.libraryManagedForcedModules,
      ["audiounit_ios", "avsamplebuffer"]
    )
    XCTAssertEqual(
      raw.applicationManagedForcedModules,
      ["audiounit_ios", "avsamplebuffer"]
    )
    XCTAssertEqual(
      raw.idleSessionBeforePlayerConstruction,
      raw.idleSessionAfterPlayerConstruction
    )
    validateSessionRecord(raw.idleSessionBeforePlayerConstruction)
    XCTAssertEqual(raw.idleBrokerBeforePlayerConstruction.brokerActiveOwnerCount, 0)
    XCTAssertEqual(raw.idleBrokerAfterPlayerConstruction.brokerActiveOwnerCount, 0)
    XCTAssertEqual(raw.idleBrokerBeforePlayerConstruction.brokerLiveLeaseCount, 0)
    XCTAssertEqual(raw.idleBrokerAfterPlayerConstruction.brokerLiveLeaseCount, 0)
    XCTAssertEqual(
      brokerOwnershipFields(raw.idleBrokerBeforePlayerConstruction),
      brokerOwnershipFields(raw.idleBrokerAfterPlayerConstruction)
    )

    let expectedOrders = [
      ["audiounit_ios", "avsamplebuffer"],
      ["avsamplebuffer", "audiounit_ios"]
    ]
    XCTAssertEqual(raw.libraryManagedCycles.map(\.forcedModuleOrder), expectedOrders)
    XCTAssertEqual(raw.libraryManagedCycles.count, expectedOrders.count)
    var deactivationBaseline = raw.idleBrokerAfterPlayerConstruction
    for cycle in raw.libraryManagedCycles {
      validateLibraryManagedCycle(cycle, baseline: deactivationBaseline)
      deactivationBaseline = cycle.afterFinalOutputRelease.native
    }

    XCTAssertEqual(
      raw.applicationManagedCycles.map(\.forcedAudioOutputModule),
      ["audiounit_ios", "avsamplebuffer"]
    )
    XCTAssertEqual(raw.applicationManagedCycles.count, 2)
    XCTAssertEqual(raw.interruptionNotificationSequence.filter { $0.kind == "began" }.count, 2)
    XCTAssertLessThanOrEqual(raw.interruptionNotificationSequence.filter { $0.kind == "ended" }.count, 2)
    XCTAssertTrue(raw.interruptionNotificationSequence.allSatisfy {
      $0.systemUptime <= raw.notificationCaptureSystemUptime
    })
    XCTAssertTrue(
      raw.interruptionNotificationSequence.allSatisfy {
        $0.reasonRawValue == AVAudioSession.InterruptionReason.default.rawValue
      }
    )
    XCTAssertTrue(
      zip(
        raw.interruptionNotificationSequence,
        raw.interruptionNotificationSequence.dropFirst()
      ).allSatisfy { $0.systemUptime <= $1.systemUptime }
    )
    guard let applicationSession = raw.applicationManagedCycles.first?.sessionBeforePlayback
    else {
      XCTFail("Application-managed ownership records are missing")
      return
    }
    validateApplicationManagedSession(applicationSession)
    for cycle in raw.applicationManagedCycles {
      XCTAssertEqual(cycle.sessionBeforePlayback, applicationSession)
      XCTAssertEqual(cycle.sessionDuringPlayback, applicationSession)
      XCTAssertEqual(cycle.sessionAfterPlayback, applicationSession)
      XCTAssertEqual(
        brokerOwnershipFields(cycle.brokerBeforePlayback),
        brokerOwnershipFields(deactivationBaseline)
      )
      XCTAssertEqual(
        brokerOwnershipFields(cycle.brokerDuringPlayback),
        brokerOwnershipFields(deactivationBaseline)
      )
      XCTAssertEqual(
        brokerOwnershipFields(cycle.brokerAfterPlayback),
        brokerOwnershipFields(deactivationBaseline)
      )
      XCTAssertGreaterThan(cycle.brokerDuringPlayback.liveOutputCount, 0)
      assertPlaybackAdvanced(from: cycle.playbackStart, to: cycle.playbackEnd)
      let recovery = cycle.hostRecovery
      XCTAssertEqual(recovery.sessionAfterReactivation, applicationSession)
      XCTAssertEqual(recovery.sessionAfterShutdown, applicationSession)
      XCTAssertLessThanOrEqual(recovery.reactivationBeganSystemUptime, recovery.reactivationCompletedSystemUptime)
      XCTAssertLessThanOrEqual(recovery.reactivationCompletedSystemUptime, recovery.playbackStart.systemUptime)
      XCTAssertLessThan(recovery.playbackStart.systemUptime, recovery.playbackEnd.systemUptime)
      for checkpoint in [recovery.playbackStart, recovery.playbackEnd] {
        XCTAssertEqual(checkpoint.playerState, "playing")
        XCTAssertTrue(checkpoint.playbackRequestedActive)
        XCTAssertGreaterThan(checkpoint.native.liveOutputCount, 0)
        XCTAssertEqual(brokerOwnershipFields(checkpoint.native), brokerOwnershipFields(deactivationBaseline))
      }
      XCTAssertEqual(brokerOwnershipFields(recovery.brokerAfterShutdown), brokerOwnershipFields(deactivationBaseline))
      assertPlaybackAdvanced(from: recovery.playbackStart.playback, to: recovery.playbackEnd.playback)
    }

    let brokerSnapshots =
      [
        raw.idleBrokerBeforePlayerConstruction,
        raw.idleBrokerAfterPlayerConstruction
      ]
      + raw.libraryManagedCycles.flatMap {
        [
          $0.firstOutputActive.native,
          $0.bothOutputsActive.native,
          $0.afterFirstOutputRelease.native,
          $0.afterFinalOutputRelease.native
        ]
      }
      + raw.applicationManagedCycles.flatMap {
        [
          $0.brokerBeforePlayback,
          $0.brokerDuringPlayback,
          $0.brokerAfterPlayback,
          $0.hostRecovery.playbackStart.native,
          $0.hostRecovery.playbackEnd.native,
          $0.hostRecovery.brokerAfterShutdown
        ]
      }
    XCTAssertTrue(brokerSnapshots.allSatisfy { $0.brokerPhase == "ready" })
    XCTAssertTrue(
      brokerSnapshots.allSatisfy {
        [$0.brokerEpoch, $0.brokerResetEpoch]
          == [
            raw.idleBrokerBeforePlayerConstruction.brokerEpoch,
            raw.idleBrokerBeforePlayerConstruction.brokerResetEpoch
          ]
      }
    )
  }

  private func validateLibraryManagedCycle(
    _ cycle: AppleAudioLibraryManagedOwnershipCycleRecord,
    baseline: AppleAudioNativeRecoveryRecord
  ) {
    let first = cycle.firstOutputActive
    let both = cycle.bothOutputsActive
    let afterFirst = cycle.afterFirstOutputRelease
    let afterFinal = cycle.afterFinalOutputRelease
    XCTAssertLessThanOrEqual(first.systemUptime, both.systemUptime)
    XCTAssertLessThanOrEqual(both.systemUptime, afterFirst.systemUptime)
    XCTAssertLessThanOrEqual(afterFirst.systemUptime, afterFinal.systemUptime)
    for checkpoint in [first, both, afterFirst] {
      XCTAssertEqual(checkpoint.playerState, "playing")
      XCTAssertTrue(checkpoint.playbackRequestedActive)
      XCTAssertGreaterThan(checkpoint.native.liveOutputCount, 0)
    }
    XCTAssertEqual(afterFinal.playerState, "idle")
    XCTAssertFalse(afterFinal.playbackRequestedActive)
    XCTAssertEqual(first.native.brokerActiveOwnerCount, 1)
    XCTAssertEqual(both.native.brokerActiveOwnerCount, 2)
    XCTAssertEqual(afterFirst.native.brokerActiveOwnerCount, 1)
    XCTAssertEqual(afterFinal.native.brokerActiveOwnerCount, 0)
    for checkpoint in [first, both, afterFirst, afterFinal] {
      XCTAssertEqual(checkpoint.native.brokerLiveLeaseCount, 0)
    }
    for checkpoint in [first, both, afterFirst] {
      XCTAssertEqual(
        brokerDeactivationFields(checkpoint.native),
        brokerDeactivationFields(baseline)
      )
    }
    XCTAssertEqual(
      afterFinal.native.brokerSuccessfulDeactivationCount,
      baseline.brokerSuccessfulDeactivationCount + 1
    )
    XCTAssertEqual(
      afterFinal.native.brokerFailedDeactivationCount,
      baseline.brokerFailedDeactivationCount
    )
    assertPlaybackAdvanced(
      from: cycle.firstOutputPlaybackStart,
      to: cycle.firstOutputPlaybackEnd
    )
    assertPlaybackAdvanced(
      from: cycle.secondOutputPlaybackStart,
      to: cycle.secondOutputPlaybackEnd
    )
  }

  private func validateApplicationManagedSession(
    _ session: AppleAudioSessionConfigurationRecord
  ) {
    validateSessionRecord(session)
    XCTAssertEqual(session.category, AVAudioSession.Category.playback.rawValue)
    XCTAssertEqual(session.mode, AVAudioSession.Mode.spokenAudio.rawValue)
    XCTAssertEqual(session.categoryOptionsRawValue, 0)
    XCTAssertEqual(
      session.routeSharingPolicyRawValue,
      AVAudioSession.RouteSharingPolicy.longFormAudio.rawValue
    )
  }

  private func validateSessionRecord(_ session: AppleAudioSessionConfigurationRecord) {
    XCTAssertTrue(session.preferredSampleRate.isFinite)
    XCTAssertGreaterThanOrEqual(session.preferredSampleRate, 0)
    XCTAssertTrue(session.preferredIOBufferDuration.isFinite)
    XCTAssertGreaterThanOrEqual(session.preferredIOBufferDuration, 0)
    XCTAssertGreaterThanOrEqual(session.preferredInputNumberOfChannels, 0)
    XCTAssertGreaterThanOrEqual(session.preferredOutputNumberOfChannels, 0)
  }

  private func assertPlaybackAdvanced(
    from start: AppleAudioPlaybackCounterRecord,
    to end: AppleAudioPlaybackCounterRecord
  ) {
    XCTAssertGreaterThan(end.mediaTimeMilliseconds, start.mediaTimeMilliseconds)
    XCTAssertGreaterThan(end.playedAudioBuffers, start.playedAudioBuffers)
  }

  private func performExclusiveFocusProbe(
    phaseElement: XCUIElement,
    interruptionElement: XCUIElement,
    continueButton: XCUIElement,
    errorElement: XCUIElement,
    expectedPhase: String,
    expectedBeganBefore: Int,
    expectCandidateInterruption: Bool,
    tapContinue: Bool
  )
    throws -> [String: Any] {
    try waitForPhaseOrFailure(
      phaseElement,
      equals: expectedPhase,
      error: errorElement,
      timeout: 90
    )
    let before = try captureInterruptionCounts()
    let observationBeforeProbeSystemUptime = before.systemUptime
    guard before.began == expectedBeganBefore, before.ended <= before.began else {
      throw OwnershipUITestFailure(
        "Unexpected interruption count before \(expectedPhase): \(before.began):\(before.ended)"
      )
    }

    guard
      let focusProbeRunnerBundleIdentifier = Bundle.main.bundleIdentifier,
      !focusProbeRunnerBundleIdentifier.isEmpty
    else {
      throw OwnershipUITestFailure(
        "The focus-probe runner has no bundle identifier"
      )
    }
    guard app.state == .runningForeground else {
      throw OwnershipUITestFailure(
        "Candidate was not foreground before focus probe: \(stateName(app.state))"
      )
    }
    let probeApplication = XCUIApplication(
      bundleIdentifier: focusProbeRunnerBundleIdentifier
    )
    probeApplication.activate()
    guard probeApplication.state == .runningForeground else {
      throw OwnershipUITestFailure(
        "XCTest focus probe did not become foreground: "
          + stateName(probeApplication.state)
      )
    }
    let backgroundDeadline = Date().addingTimeInterval(2)
    while app.state == .runningForeground, Date() < backgroundDeadline {
      RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    let candidateStateDuringActivation = stateName(app.state)
    guard
      app.state == .runningBackground
      || app.state == .runningBackgroundSuspended
    else {
      throw OwnershipUITestFailure(
        "Candidate did not leave the foreground for the external focus probe: "
          + candidateStateDuringActivation
      )
    }

    let session = AVAudioSession.sharedInstance()
    try session.setCategory(.playback, mode: .default, options: [])
    let activationBeganSystemUptime = ProcessInfo.processInfo.systemUptime
    try session.setActive(true)
    let activationCompletedSystemUptime = ProcessInfo.processInfo.systemUptime
    var runnerSessionActive = true
    var candidateReactivated = false
    defer {
      if runnerSessionActive {
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
      }
      if !candidateReactivated {
        app.activate()
      }
    }

    // Do not inspect the background candidate through Accessibility: its AX
    // snapshot may be unavailable or stale. The app retains interruption
    // notification uptimes, which host policy correlates with this runner's
    // activation/deactivation window after the app is foreground again.
    RunLoop.current.run(until: Date().addingTimeInterval(1))
    let deactivationBeganSystemUptime = ProcessInfo.processInfo.systemUptime
    try session.setActive(false, options: .notifyOthersOnDeactivation)
    let deactivationCompletedSystemUptime = ProcessInfo.processInfo.systemUptime
    runnerSessionActive = false
    app.activate()
    candidateReactivated = true
    guard app.state == .runningForeground else {
      throw OwnershipUITestFailure(
        "Candidate did not return to foreground after focus probe: "
          + stateName(app.state)
      )
    }
    let expectedBeganAfter = before.began + (expectCandidateInterruption ? 1 : 0)
    if expectCandidateInterruption {
      try waitForInterruptionBeganCount(
        interruptionElement,
        equals: expectedBeganAfter,
        phase: phaseElement,
        error: errorElement,
        timeout: 10
      )
    }
    // Allow notifications to settle, but never require an optional ended event.
    RunLoop.current.run(until: Date().addingTimeInterval(2))
    let observedAfter = try captureInterruptionCounts()
    guard
      observedAfter.began == expectedBeganAfter,
      observedAfter.ended >= before.ended,
      observedAfter.ended <= observedAfter.began else {
      throw OwnershipUITestFailure("Unexpected interruption counts during \(expectedPhase)")
    }
    guard
      app.exists,
      app.state == .runningForeground,
      phaseElement.label == expectedPhase,
      !errorElement.exists
    else {
      throw OwnershipUITestFailure(
        "Candidate became unhealthy during \(expectedPhase): state="
          + stateName(app.state)
          + ", phase=\(phaseElement.label), error="
          + (errorElement.exists ? errorElement.label : "none")
      )
    }
    let observationSystemUptime = observedAfter.systemUptime

    if tapContinue {
      reveal(continueButton)
      guard continueButton.isEnabled else {
        throw OwnershipUITestFailure("Focus probe continuation is disabled during \(expectedPhase)")
      }
      continueButton.tap()
    }
    return [
      "phase": expectedPhase,
      "source": "foreground-XCTest-runner-audio-session",
      "activationSucceeded": true,
      "probeApplicationBundleIdentifier": focusProbeRunnerBundleIdentifier,
      "probeApplicationStateAtActivation": "runningForeground",
      "candidateApplicationStateBeforeProbe": "runningForeground",
      "candidateApplicationStateDuringActivation": candidateStateDuringActivation,
      "candidateApplicationStateAfterProbe": "runningForeground",
      "observationBeforeProbeSystemUptime": observationBeforeProbeSystemUptime,
      "activationBeganSystemUptime": activationBeganSystemUptime,
      "activationCompletedSystemUptime": activationCompletedSystemUptime,
      "deactivationBeganSystemUptime": deactivationBeganSystemUptime,
      "deactivationCompletedSystemUptime": deactivationCompletedSystemUptime,
      "observationSystemUptime": observationSystemUptime,
      "candidateInterruptionBeganBefore": before.began,
      "candidateInterruptionEndedBefore": before.ended,
      "candidateInterruptionBeganAfterProbe": observedAfter.began,
      "candidateInterruptionEndedAfterProbe": observedAfter.ended,
      "candidateInterruptionBeganDelta": observedAfter.began - before.began,
      "candidateInterruptionEndedDelta": observedAfter.ended - before.ended,
      "outcome": expectCandidateInterruption
        ? "candidate-session-active-after-output-teardown"
        : "candidate-session-released"
    ]
  }

  private func stateName(_ state: XCUIApplication.State) -> String {
    switch state {
    case .unknown: "unknown"
    case .notRunning: "notRunning"
    case .runningBackgroundSuspended: "runningBackgroundSuspended"
    case .runningBackground: "runningBackground"
    case .runningForeground: "runningForeground"
    @unknown default: "future"
    }
  }

  private func waitForPhaseOrFailure(
    _ phase: XCUIElement,
    equals expected: String,
    error: XCUIElement,
    timeout: TimeInterval
  )
    throws {
    let predicate = NSPredicate { _, _ in
      !self.app.exists
        || phase.label == expected
        || ["failed", "cancelled"].contains(phase.label)
    }
    let expectation = XCTNSPredicateExpectation(predicate: predicate, object: phase)
    guard XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed else {
      throw OwnershipUITestFailure(
        "Timed out waiting for \(expected); current phase is \(phase.label)"
      )
    }
    guard app.exists, phase.label == expected else {
      throw OwnershipUITestFailure(
        "Ownership surface terminated as \(phase.label): "
          + (error.exists ? error.label : "the candidate app terminated")
      )
    }
  }

  private func waitForInterruptionBeganCount(
    _ interruptions: XCUIElement,
    equals expected: Int,
    phase: XCUIElement,
    error: XCUIElement,
    timeout: TimeInterval
  )
    throws {
    let predicate = NSPredicate { _, _ in
      !self.app.exists
        || (try? self.interruptionCounts(from: interruptions).began) == expected
        || ["failed", "cancelled"].contains(phase.label)
    }
    let expectation = XCTNSPredicateExpectation(predicate: predicate, object: interruptions)
    guard XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed else {
      throw OwnershipUITestFailure(
        "Timed out waiting for interruption began count \(expected); found \(interruptions.label)"
      )
    }
    guard app.exists, (try? interruptionCounts(from: interruptions).began) == expected else {
      throw OwnershipUITestFailure(
        "Ownership surface failed while waiting for interruptions: "
          + (error.exists ? error.label : phase.label)
      )
    }
  }

  private func captureInterruptionCounts() throws -> AppleAudioInterruptionCounterSnapshot {
    let button = app.buttons[AccessibilityID.AudioSessionOwnershipValidation.captureInterruptionsButton]
    reveal(button)
    let label = app.descendants(matching: .any)[
      AccessibilityID.AudioSessionOwnershipValidation.interruptionSnapshotLabel
    ]
    let previous = label.label
    let beganAt = ProcessInfo.processInfo.systemUptime
    button.tap()
    let updated = expectation(
      for: NSPredicate { _, _ in label.exists && label.label != previous },
      evaluatedWith: NSObject()
    )
    guard
      XCTWaiter.wait(for: [updated], timeout: 5) == .completed,
      let data = Data(base64Encoded: label.label) else {
      throw OwnershipUITestFailure("Candidate did not capture fresh interruption counters")
    }
    let snapshot = try JSONDecoder().decode(AppleAudioInterruptionCounterSnapshot.self, from: data)
    guard
      !snapshot.id.isEmpty, snapshot.began >= 0, snapshot.ended >= 0,
      snapshot.systemUptime >= beganAt,
      snapshot.systemUptime <= ProcessInfo.processInfo.systemUptime else {
      throw OwnershipUITestFailure("Candidate interruption counter snapshot is stale or invalid")
    }
    return snapshot
  }

  private func interruptionCounts(from element: XCUIElement) throws -> InterruptionCounts {
    let components = element.label.split(separator: ":", omittingEmptySubsequences: false)
    guard
      components.count == 2,
      let began = Int(components[0]),
      let ended = Int(components[1]),
      began >= 0,
      ended >= 0
    else {
      throw OwnershipUITestFailure(
        "Malformed interruption counter label: \(element.label)"
      )
    }
    return InterruptionCounts(began: began, ended: ended)
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

  private func focusProbe(
    _ record: [String: Any],
    adding fields: [String: Any]
  ) -> [String: Any] {
    record.merging(fields) { _, replacement in replacement }
  }

  private func decodeResult<T: Decodable>(_ label: String) throws -> T {
    let prefix = "pass:"
    guard label.hasPrefix(prefix) else {
      throw OwnershipUITestFailure("Malformed result label: \(label)")
    }
    guard let data = Data(base64Encoded: String(label.dropFirst(prefix.count))) else {
      throw OwnershipUITestFailure("Ownership result is not valid base64")
    }
    return try JSONDecoder().decode(T.self, from: data)
  }

  private func jsonObject(_ value: some Encodable) throws -> [String: Any] {
    let data = try JSONEncoder().encode(value)
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      throw OwnershipUITestFailure("Ownership result is not a JSON object")
    }
    return object
  }

  private func adaptiveAttemptToken(from url: URL) -> String? {
    let components = url.pathComponents.filter { $0 != "/" }
    guard
      components.count >= 4,
      components[0] == "adaptive",
      components[2] == "timebase-vod-ts",
      components[3] == "master.m3u8",
      !components[1].isEmpty,
      components[1].allSatisfy({
        $0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-"
      })
    else { return nil }
    return components[1]
  }

  private func element(_ identifier: String) -> XCUIElement {
    app.descendants(matching: .any)[identifier]
  }

  private func reveal(_ element: XCUIElement) {
    for _ in 0..<6 where !element.isHittable {
      app.swipeUp()
    }
    for _ in 0..<12 where !element.isHittable {
      app.swipeDown()
    }
    XCTAssertTrue(element.isHittable)
  }

  private func replaceLaunchArgument(_ name: String, with value: String) {
    while let index = app.launchArguments.firstIndex(of: name) {
      app.launchArguments.remove(at: index)
      if index < app.launchArguments.endIndex {
        app.launchArguments.remove(at: index)
      }
    }
    app.launchArguments += [name, value]
  }
}

private struct InterruptionCounts: Equatable {
  let began: Int
  let ended: Int

  var label: String {
    "\(began):\(ended)"
  }
}

private struct OwnershipUITestFailure: Error, CustomStringConvertible {
  let description: String

  init(_ description: String) {
    self.description = description
  }
}
