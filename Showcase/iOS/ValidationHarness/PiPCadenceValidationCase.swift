import Foundation
import SwiftUI
@_spi(Qualification) import SwiftVLC

/// Candidate-bound cadence matrix. SpringBoard resize gestures are supplied
/// by the UI test while the app owns media/rate/pause/replacement transitions
/// and samples the exact direct-renderer timing state.
struct PiPCadenceValidationCase: View {
  @State private var player = Player()
  @State private var controller: PiPController?
  @State private var result = "not-run"
  @State private var progress = "0s"
  @State private var activeProfile = "idle"
  @State private var playbackError: String?
  @State private var isRunning = false

  private let durationSeconds = max(1, LaunchArguments.pipCadenceDurationValue ?? 600)
  private let baseURL = LaunchArguments.pipCadenceBaseURLValue

  var body: some View {
    _ = player.currentTime
    return Form {
      Section {
        DirectPiPValidationSurface(player: player, controller: $controller)
          .frame(height: 220)
          .listRowInsets(EdgeInsets())
          .accessibilityIdentifier(AccessibilityID.PiPCadenceValidation.videoView)
      }
      Section("Measured state") {
        valueRow("Playback", value: String(describing: player.state), identifier: AccessibilityID.PiPCadenceValidation.stateLabel)
        valueRow("PiP possible", value: controller?.isPossible == true ? "yes" : "no", identifier: AccessibilityID.PiPCadenceValidation.possibleLabel)
        valueRow("PiP active", value: controller?.isActive == true ? "yes" : "no", identifier: AccessibilityID.PiPCadenceValidation.activeLabel)
        valueRow("Elapsed", value: progress, identifier: AccessibilityID.PiPCadenceValidation.progressLabel)
        valueRow("Cadence", value: activeProfile, identifier: AccessibilityID.PiPCadenceValidation.profileLabel)
        valueRow("Qualification", value: result, identifier: AccessibilityID.PiPCadenceValidation.resultLabel)
      }
      Section("Cadence matrix") {
        Button("Run ten-minute cadence matrix") { Task { await run() } }
          .accessibilityIdentifier(AccessibilityID.PiPCadenceValidation.runButton)
          .disabled(isRunning || baseURL == nil || controller == nil)
        if let playbackError {
          Text(playbackError)
            .foregroundStyle(.red)
            .accessibilityIdentifier(AccessibilityID.PiPCadenceValidation.errorLabel)
        }
      }
    }
    .showcaseFormStyle()
    .navigationTitle("Direct PiP cadence")
    .onDisappear {
      controller?.stop()
      player.stop()
    }
  }

  private func run() async {
    guard let controller, baseURL != nil else { return }
    isRunning = true
    playbackError = nil
    result = "running"
    defer { isRunning = false }
    do {
      let started = ProcessInfo.processInfo.systemUptime
      // Leave enough time for initial starts, replacements, and cadence convergence.
      let phaseSeconds = max(20, (durationSeconds - 45) / CadenceProfile.allCases.count)
      var metrics: [CadencePresentationMetric] = []
      var samples: [CadenceSample] = []
      var fabricatedDurationCount = 0
      var monotonicityViolations = 0
      var rateChanges = 0
      var pauseResumeCycles = 0
      var replacements = 0
      var resizeTargets: [String] = []
      var lastPTSByGeneration: [UInt64: Double] = [:]

      for (index, profile) in CadenceProfile.allCases.enumerated() {
        guard Int(ProcessInfo.processInfo.systemUptime - started) < durationSeconds else { break }
        activeProfile = profile.evidenceName
        if index > 0 {
          replacements += 1
        }
        try play(profile)
        try await waitUntil("\(profile.evidenceName) did not start", timeout: .seconds(30)) {
          player.state == .playing && profile.matches(player.videoTracks)
        }
        if index == 0 {
          guard controller.start() == .accepted else {
            throw CadenceFailure("Direct PiP start was not accepted")
          }
          try await waitUntil("Direct PiP did not become active", timeout: .seconds(30)) {
            controller.isActive
          }
        } else {
          try await waitUntil("PiP did not survive cadence replacement", timeout: .seconds(30)) {
            controller.isActive
          }
        }
        try await waitUntil("Renderer published fabricated duration metadata", timeout: .seconds(15)) {
          Self.rendererPublishesNoFabricatedDuration(controller: controller)
        }

        let phaseStarted = ProcessInfo.processInfo.systemUptime
        let before = controller.timebaseDiagnosticSnapshot()
        var paused = false
        var half = false
        var normalAfterHalf = false
        var doubled = false
        var finalNormal = false
        while
          Int(ProcessInfo.processInfo.systemUptime - phaseStarted) < phaseSeconds,
          Int(ProcessInfo.processInfo.systemUptime - started) < durationSeconds {
          try Task.checkCancellation()
          let phaseElapsed = Int(ProcessInfo.processInfo.systemUptime - phaseStarted)
          let totalElapsed = Int(ProcessInfo.processInfo.systemUptime - started)
          progress = "\(totalElapsed)s / \(durationSeconds)s"

          if phaseElapsed >= 10, !paused {
            player.pause()
            try await waitUntil("Cadence pause did not settle", timeout: .seconds(10)) {
              !player.isActive
            }
            try await Task.sleep(for: .seconds(2))
            player.resume()
            try await waitUntil("Cadence resume did not settle", timeout: .seconds(10)) {
              player.isActive
            }
            pauseResumeCycles += 1
            paused = true
          }
          if phaseElapsed >= 22, !half {
            try player.setPlaybackRate(.half)
            rateChanges += 1
            half = true
          }
          if phaseElapsed >= 32, !normalAfterHalf {
            try player.setPlaybackRate(.normal)
            rateChanges += 1
            normalAfterHalf = true
          }
          if phaseElapsed >= 42, !doubled {
            try player.setPlaybackRate(.double)
            rateChanges += 1
            doubled = true
          }
          if phaseElapsed >= 52, !finalNormal {
            try player.setPlaybackRate(.normal)
            rateChanges += 1
            finalNormal = true
          }

          let snapshot = controller.timebaseDiagnosticSnapshot()
          if !Self.rendererPublishesNoFabricatedDuration(snapshot: snapshot) {
            fabricatedDurationCount += 1
          }
          if let pts = snapshot.lastDeliveredSampleTimeSeconds {
            if let prior = lastPTSByGeneration[snapshot.playbackGeneration], pts + 0.001 < prior {
              monotonicityViolations += 1
            }
            lastPTSByGeneration[snapshot.playbackGeneration] = pts
          }
          var renderTarget: String?
          if let renderer = controller.renderPerformanceQualificationSnapshot {
            let target = "\(renderer.targetWidth ?? 0)x\(renderer.targetHeight ?? 0)"
            renderTarget = target
            if resizeTargets.last != target {
              resizeTargets.append(target)
            }
          }
          // Keep evidence small enough to survive the XCUI accessibility transport.
          // Counters are still sampled every second for the aggregate metrics above.
          if phaseElapsed.isMultiple(of: 5) {
            samples.append(
              CadenceSample(
                profile: profile.evidenceName,
                elapsedSeconds: totalElapsed,
                snapshot: snapshot,
                renderTarget: renderTarget
              )
            )
          }
          try await Task.sleep(for: .seconds(1))
        }
        try player.setPlaybackRate(.normal)
        let after = controller.timebaseDiagnosticSnapshot()
        let metric = CadencePresentationMetric(profile: profile, before: before, after: after)
        guard metric.deliveredFrames > 0 else {
          throw CadenceFailure("\(profile.evidenceName) delivered no frames")
        }
        guard metric.presentationCopyFailures == 0, metric.displayConsumeFailures == 0 else {
          throw CadenceFailure("\(profile.evidenceName) reported a renderer failure")
        }
        guard metric.dropRate <= 0.10 else {
          throw CadenceFailure("\(profile.evidenceName) exceeded the 10% drop budget")
        }
        metrics.append(metric)
      }

      guard metrics.count == CadenceProfile.allCases.count else {
        throw CadenceFailure("Cadence matrix ended before every source ran")
      }
      guard fabricatedDurationCount == 0 else {
        throw CadenceFailure("Renderer published fabricated duration metadata")
      }
      guard monotonicityViolations == 0 else {
        throw CadenceFailure("Presented time moved backward within a playback generation")
      }
      let validTargets = Set(resizeTargets.filter { $0 != "0x0" })
      guard validTargets.count >= 2 else {
        throw CadenceFailure("Real PiP resize did not produce distinct render targets")
      }
      guard
        rateChanges >= CadenceProfile.allCases.count * 4,
        pauseResumeCycles >= CadenceProfile.allCases.count
      else {
        throw CadenceFailure("Rate or pause/resume transitions were incomplete")
      }

      let elapsedBeforeMinimum = Int(ProcessInfo.processInfo.systemUptime - started)
      if elapsedBeforeMinimum < durationSeconds {
        try await Task.sleep(for: .seconds(durationSeconds - elapsedBeforeMinimum))
      }
      guard controller.isActive else {
        throw CadenceFailure("Direct PiP stopped before the minimum duration")
      }
      let completedDuration = Int(ProcessInfo.processInfo.systemUptime - started)

      let evidence = CadenceEvidence(
        durationSeconds: completedDuration,
        rates: [23.976, 24, 25, 29.97, 30, 50, 59.94, 60],
        vfr: true,
        presentationMetrics: metrics,
        transitionResults: CadenceTransitionResults(
          rateChanges: rateChanges,
          pauseResumeCycles: pauseResumeCycles,
          replacements: replacements,
          resizeCycles: max(0, resizeTargets.count - 1),
          resizeTargets: resizeTargets,
          monotonicityViolations: monotonicityViolations
        ),
        fabricatedDurationCount: fabricatedDurationCount,
        samples: samples
      )
      result = try "pass:\(JSONEncoder().encode(evidence).base64EncodedString())"
      progress = "\(completedDuration)s / \(durationSeconds)s"
      activeProfile = "complete"
    } catch is CancellationError {
      result = "cancelled"
    } catch {
      controller.stop()
      playbackError = String(describing: error)
      result = "failed"
    }
  }

  private func play(_ profile: CadenceProfile) throws {
    guard let url = baseURL?.appending(path: "files/cadence/\(profile.fileName).mp4") else {
      throw CadenceFailure("Missing cadence origin")
    }
    let media = try Media(url: url)
    try player.play(media)
  }

  private static func rendererPublishesNoFabricatedDuration(
    controller: PiPController
  ) -> Bool {
    rendererPublishesNoFabricatedDuration(snapshot: controller.timebaseDiagnosticSnapshot())
  }

  private static func rendererPublishesNoFabricatedDuration(
    snapshot: PiPTimebaseDiagnosticSnapshot
  ) -> Bool {
    // libVLC exposes a nominal/average track ratio but the vmem callback does
    // not expose the duration of the individual decoded frame. The safe value
    // for CFR, VFR, and unknown inputs is therefore always `.invalid`; PTS
    // remains authoritative for scheduling.
    snapshot.frameDurationValue == nil && snapshot.frameDurationTimescale == nil
  }

  private func waitUntil(_ failure: String, timeout: Duration, condition: @escaping @MainActor () -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition() {
      try Task.checkCancellation()
      guard clock.now < deadline else { throw CadenceFailure(failure) }
      try await Task.sleep(for: .milliseconds(100))
    }
  }

  private func valueRow(_ title: String, value: String, identifier: String) -> some View {
    HStack { Text(title); Spacer(); Text(value).foregroundStyle(.secondary).accessibilityIdentifier(identifier) }
  }
}

private enum CadenceProfile: CaseIterable {
  case fps23976, fps24, fps25, fps2997, fps30, fps50, fps5994, fps60, vfr

  var fileName: String {
    switch self {
    case .fps23976: "23_976"
    case .fps24: "24"
    case .fps25: "25"
    case .fps2997: "29_97"
    case .fps30: "30"
    case .fps50: "50"
    case .fps5994: "59_94"
    case .fps60: "60"
    case .vfr: "vfr"
    }
  }

  var evidenceName: String {
    self == .vfr ? "vfr-24-60" : fileName.replacingOccurrences(of: "_", with: ".")
  }

  var expectedRatio: (numerator: UInt32, denominator: UInt32)? {
    switch self {
    case .fps23976: (24000, 1001)
    case .fps24: (24, 1)
    case .fps25: (25, 1)
    case .fps2997: (30000, 1001)
    case .fps30: (30, 1)
    case .fps50: (50, 1)
    case .fps5994: (60000, 1001)
    case .fps60: (60, 1)
    case .vfr: nil
    }
  }

  func matches(_ tracks: [Track]) -> Bool {
    guard let ratio = (tracks.first(where: \.isSelected) ?? tracks.first)?.frameRateRatio else {
      return self == .vfr && !tracks.isEmpty
    }
    guard let expectedRatio else { return true }
    return ratio.numerator == expectedRatio.numerator && ratio.denominator == expectedRatio.denominator
  }
}

private struct CadencePresentationMetric: Encodable {
  let profile: String
  let deliveredFrames: UInt64
  let droppedFrames: UInt64
  let dropRate: Double
  let elapsedSeconds: Double
  let presentationRate: Double
  let backpressureEvents: UInt64
  let presentationCopyFailures: UInt64
  let displayConsumeFailures: UInt64
  let observedDurationValue: Int64?
  let observedDurationTimescale: Int32?

  init(profile: CadenceProfile, before: PiPTimebaseDiagnosticSnapshot, after: PiPTimebaseDiagnosticSnapshot) {
    self.profile = profile.evidenceName
    deliveredFrames = Self.delta(after.deliveredFrameCount, before.deliveredFrameCount)
    droppedFrames = Self.delta(after.droppedFrameCount, before.droppedFrameCount)
    let total = deliveredFrames + droppedFrames
    dropRate = total > 0 ? Double(droppedFrames) / Double(total) : 1
    elapsedSeconds = max(0, after.systemUptime - before.systemUptime)
    presentationRate = elapsedSeconds > 0 ? Double(deliveredFrames) / elapsedSeconds : 0
    backpressureEvents = Self.delta(after.vmemPoolUnavailableCount, before.vmemPoolUnavailableCount)
    presentationCopyFailures = Self.delta(after.presentationCopyFailureCount, before.presentationCopyFailureCount)
    displayConsumeFailures = Self.delta(after.vmemDisplayConsumeFailureCount, before.vmemDisplayConsumeFailureCount)
    observedDurationValue = after.frameDurationValue
    observedDurationTimescale = after.frameDurationTimescale
  }

  private static func delta(_ after: UInt64, _ before: UInt64) -> UInt64 {
    after >= before ? after - before : after
  }
}

private struct CadenceSample: Encodable {
  let profile: String
  let elapsedSeconds: Int
  let playbackGeneration: UInt64
  let requestedRate: Float
  let lastPTSSeconds: Double?
  let durationValue: Int64?
  let durationTimescale: Int32?
  let deliveredFrames: UInt64
  let droppedFrames: UInt64
  let backpressureEvents: UInt64
  let renderTarget: String?

  init(
    profile: String,
    elapsedSeconds: Int,
    snapshot: PiPTimebaseDiagnosticSnapshot,
    renderTarget: String?
  ) {
    self.profile = profile
    self.elapsedSeconds = elapsedSeconds
    playbackGeneration = snapshot.playbackGeneration
    requestedRate = snapshot.requestedRate
    lastPTSSeconds = snapshot.lastDeliveredSampleTimeSeconds
    durationValue = snapshot.frameDurationValue
    durationTimescale = snapshot.frameDurationTimescale
    deliveredFrames = snapshot.deliveredFrameCount
    droppedFrames = snapshot.droppedFrameCount
    backpressureEvents = snapshot.vmemPoolUnavailableCount
    self.renderTarget = renderTarget
  }
}

private struct CadenceTransitionResults: Encodable {
  let rateChanges: Int
  let pauseResumeCycles: Int
  let replacements: Int
  let resizeCycles: Int
  let resizeTargets: [String]
  let monotonicityViolations: Int
}

private struct CadenceEvidence: Encodable {
  let durationSeconds: Int
  let rates: [Double]
  let vfr: Bool
  let presentationMetrics: [CadencePresentationMetric]
  let transitionResults: CadenceTransitionResults
  let fabricatedDurationCount: Int
  let samples: [CadenceSample]
}

private struct CadenceFailure: Error, CustomStringConvertible {
  let description: String
  init(_ description: String) {
    self.description = description
  }
}
