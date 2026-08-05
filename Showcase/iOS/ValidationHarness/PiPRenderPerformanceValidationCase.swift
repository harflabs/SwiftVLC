import Darwin
import Foundation
import SwiftUI
@_spi(Qualification) import SwiftVLC

/// Long-running, candidate-bound direct-PiP performance sampler. The UI test
/// drives the real SpringBoard window while this view records the renderer and
/// process state that cannot be observed reliably through accessibility.
struct PiPRenderPerformanceValidationCase: View {
  @State private var player = Player()
  @State private var loopingPlayer: MediaListPlayer?
  @State private var controller: PiPController?
  @State private var result = "not-run"
  @State private var progress = "0s"
  @State private var playbackError: String?
  @State private var isRunning = false

  private let profile = PiPPerformanceProfile(
    rawValue: LaunchArguments.pipPerformanceProfileValue ?? "1080p60"
  ) ?? .p1080
  private let durationSeconds = max(1, LaunchArguments.pipPerformanceDurationValue ?? 900)
  private let mediaURL = LaunchArguments.pipPerformanceURLValue

  var body: some View {
    _ = player.currentTime
    return Form {
      Section {
        DirectPiPValidationSurface(player: player, controller: $controller)
          .frame(height: 220)
          .listRowInsets(EdgeInsets())
          .accessibilityIdentifier(AccessibilityID.PiPRenderPerformanceValidation.videoView)
      }

      Section("Measured state") {
        valueRow("Playback", value: String(describing: player.state), identifier: AccessibilityID.PiPRenderPerformanceValidation.stateLabel)
        valueRow("PiP possible", value: controller?.isPossible == true ? "yes" : "no", identifier: AccessibilityID.PiPRenderPerformanceValidation.possibleLabel)
        valueRow("PiP active", value: controller?.isActive == true ? "yes" : "no", identifier: AccessibilityID.PiPRenderPerformanceValidation.activeLabel)
        valueRow("Elapsed", value: progress, identifier: AccessibilityID.PiPRenderPerformanceValidation.progressLabel)
        valueRow("Target", value: targetDescription, identifier: AccessibilityID.PiPRenderPerformanceValidation.targetLabel)
        valueRow("Qualification", value: result, identifier: AccessibilityID.PiPRenderPerformanceValidation.resultLabel)
      }

      Section("Direct PiP performance") {
        Button("Run \(profile.rawValue) performance row") { Task { await run() } }
          .accessibilityIdentifier(AccessibilityID.PiPRenderPerformanceValidation.runButton)
          .disabled(isRunning || mediaURL == nil || controller?.isPossible != true || player.state != .playing)
        if let playbackError {
          Text(playbackError)
            .foregroundStyle(.red)
            .accessibilityIdentifier(AccessibilityID.PiPRenderPerformanceValidation.errorLabel)
        }
      }
    }
    .showcaseFormStyle()
    .navigationTitle("PiP render performance")
    .task { startPlayback() }
    .onDisappear {
      controller?.stop()
      loopingPlayer?.stop()
    }
  }

  private var targetDescription: String {
    guard let snapshot = controller?.renderPerformanceQualificationSnapshot else { return "unknown" }
    return "\(snapshot.targetWidth ?? 0)x\(snapshot.targetHeight ?? 0)"
  }

  private func startPlayback() {
    do { try playFixture() } catch { playbackError = String(describing: error) }
  }

  private func playFixture() throws {
    if let loopingPlayer {
      try loopingPlayer.play(at: 0)
      return
    }
    guard let mediaURL else { throw PiPPerformanceFailure("Missing performance fixture URL") }
    let media = try Media(url: mediaURL)
    let list = MediaList()
    try list.append(media)
    let loopingPlayer = MediaListPlayer()
    loopingPlayer.mediaPlayer = player
    loopingPlayer.mediaList = list
    loopingPlayer.playbackMode = .loop
    self.loopingPlayer = loopingPlayer
    loopingPlayer.play()
  }

  private func run() async {
    guard let controller else { return }
    isRunning = true
    playbackError = nil
    result = "running"
    defer { isRunning = false }
    do {
      try await waitUntil("Performance fixture did not start", timeout: .seconds(30)) {
        player.state == .playing
      }
      guard controller.start() == .accepted else {
        throw PiPPerformanceFailure("Direct PiP start was not accepted")
      }
      try await waitUntil("Direct PiP did not become active", timeout: .seconds(30)) {
        controller.isActive
      }
      try await waitUntil("Performance fixture geometry did not resolve", timeout: .seconds(30)) {
        guard let snapshot = controller.renderPerformanceQualificationSnapshot else {
          return false
        }
        return snapshot.sourceWidth == profile.width && snapshot.sourceHeight == profile.height
      }

      controller.resetRenderPerformanceQualificationMeasurements()
      let started = ProcessInfo.processInfo.systemUptime
      var samples: [PiPPerformanceSample] = []
      var resizeTargets: [String] = []
      var replacementCount = 0
      var nextReplacement = 120
      var deliveredPictures: UInt64 = 0
      var lostPictures: UInt64 = 0
      var previousStatistics = player.statistics

      while Int(ProcessInfo.processInfo.systemUptime - started) < durationSeconds {
        try Task.checkCancellation()
        let elapsed = Int(ProcessInfo.processInfo.systemUptime - started)
        progress = "\(elapsed)s / \(durationSeconds)s"
        guard let renderer = controller.renderPerformanceQualificationSnapshot else {
          throw PiPPerformanceFailure("Direct renderer telemetry became unavailable")
        }
        let target = "\(renderer.targetWidth ?? 0)x\(renderer.targetHeight ?? 0)"
        if resizeTargets.last != target {
          resizeTargets.append(target)
        }
        samples.append(Self.sample(elapsed: elapsed, renderer: renderer))

        if let current = player.statistics {
          if let previousStatistics {
            deliveredPictures &+= Self.counterDelta(current.displayedPictures, previousStatistics.displayedPictures)
            lostPictures &+= Self.counterDelta(current.lostPictures, previousStatistics.lostPictures)
          } else {
            deliveredPictures &+= current.displayedPictures
            lostPictures &+= current.lostPictures
          }
          previousStatistics = current
        }

        if elapsed >= nextReplacement {
          try playFixture()
          replacementCount += 1
          nextReplacement += 120
          previousStatistics = nil
          try await waitUntil("Replacement playback did not recover", timeout: .seconds(30)) {
            player.state == .playing && controller.isActive
          }
        }
        try await Task.sleep(for: .seconds(5))
      }

      guard let finalRenderer = controller.renderPerformanceQualificationSnapshot else {
        throw PiPPerformanceFailure("Missing final renderer telemetry")
      }
      samples.append(Self.sample(elapsed: durationSeconds, renderer: finalRenderer))
      let analysis = try analyze(
        samples: samples,
        targets: resizeTargets,
        replacements: replacementCount,
        displayedPictures: deliveredPictures,
        lostPictures: lostPictures
      )
      let evidence = PiPPerformanceEvidence(
        profile: profile.rawValue,
        durationSeconds: durationSeconds,
        metrics: analysis.metrics,
        samples: samples,
        resizeCycles: max(0, resizeTargets.count - 1),
        resizeTargets: resizeTargets,
        replacementCount: replacementCount,
        inlineQuality: "preserved",
        effectiveWorkOutcome: "reduced",
        boundedMemory: true,
        boundedWork: true,
        hostTraceRequirements: [
          "gpu": "Game Performance trace",
          "energy": "Power Profiler trace",
          "conversionCost": "Time Profiler signpost interval PixelBufferRenderer.outputPixelBuffer"
        ]
      )
      result = try "pass:\(JSONEncoder().encode(evidence).base64EncodedString())"
      progress = "\(durationSeconds)s / \(durationSeconds)s"
    } catch is CancellationError {
      result = "cancelled"
    } catch {
      controller.stop()
      loopingPlayer?.stop()
      playbackError = String(describing: error)
      result = "failed"
    }
  }

  private func analyze(
    samples: [PiPPerformanceSample],
    targets: [String],
    replacements: Int,
    displayedPictures: UInt64,
    lostPictures: UInt64
  )
    throws -> PiPPerformanceAnalysis {
    guard samples.count >= 10 else { throw PiPPerformanceFailure("Insufficient performance samples") }
    guard replacements >= max(1, durationSeconds / 180) else {
      throw PiPPerformanceFailure("Insufficient same-player replacements")
    }
    let validTargets = samples.filter { $0.targetWidth > 0 && $0.targetHeight > 0 }
    let distinctValidTargets = Set(validTargets.map { "\($0.targetWidth)x\($0.targetHeight)" })
    guard targets.count >= 3, distinctValidTargets.count >= 2 else {
      throw PiPPerformanceFailure("The real PiP window produced no repeated render-size changes")
    }
    guard samples.allSatisfy({ $0.sourceWidth == profile.width && $0.sourceHeight == profile.height }) else {
      throw PiPPerformanceFailure("Inline source geometry changed during PiP")
    }
    let sourcePixels = profile.width * profile.height
    guard validTargets.contains(where: { $0.targetWidth * $0.targetHeight < sourcePixels }) else {
      throw PiPPerformanceFailure("PiP resize did not reduce conversion work")
    }
    guard
      samples.allSatisfy({
        $0.presentationCopyFailures == 0
          && $0.displayConsumeFailures == 0
          && $0.renderPoolAllocationFailureCount == 0
          && $0.lastRenderPoolAllocationStatus == nil
      }) else {
      throw PiPPerformanceFailure("Renderer reported a bounded-pool or presentation failure")
    }
    guard samples.allSatisfy({ $0.residentBytes > 0 }) else {
      throw PiPPerformanceFailure("Mach RSS sampling failed")
    }
    let thermalStates = Set(samples.map(\.thermalState))
    guard !thermalStates.contains("unknown"), !thermalStates.contains("critical") else {
      throw PiPPerformanceFailure("Device thermal state was unavailable or critical")
    }
    let rss = samples.map(\.residentBytes)
    guard let firstRSS = rss.first, let finalRSS = rss.last else {
      throw PiPPerformanceFailure("Missing RSS samples")
    }
    let rssGrowth = finalRSS > firstRSS ? finalRSS - firstRSS : 0
    let peakRSS = rss.max() ?? firstRSS
    let peakRSSGrowth = peakRSS > firstRSS ? peakRSS - firstRSS : 0
    guard rssGrowth <= 160 * 1_048_576 else {
      throw PiPPerformanceFailure("RSS grew by more than 160 MiB")
    }
    guard peakRSSGrowth <= 256 * 1_048_576 else {
      throw PiPPerformanceFailure("Transient RSS growth exceeded 256 MiB")
    }
    let convertedFrames = (samples.last?.presentationCopyFrames ?? 0)
      - (samples.first?.presentationCopyFrames ?? 0)
    let deliveredFrames = Self.counterDelta(
      samples.last?.deliveredFrameCount ?? 0,
      samples.first?.deliveredFrameCount ?? 0
    )
    let droppedFrames = Self.counterDelta(
      samples.last?.droppedFrameCount ?? 0,
      samples.first?.droppedFrameCount ?? 0
    )
    let measuredConversions = samples.last?.measuredConversionCount ?? 0
    let measuredConversionNanoseconds = samples.last?.measuredConversionNanoseconds ?? 0
    let maximumMeasuredConversionNanoseconds = samples.last?.maximumMeasuredConversionNanoseconds ?? 0
    guard
      measuredConversions > 0,
      measuredConversionNanoseconds > 0,
      maximumMeasuredConversionNanoseconds > 0
    else {
      throw PiPPerformanceFailure("Direct conversion timing did not advance")
    }
    let rendererFrameAttempts = deliveredFrames + droppedFrames
    let rendererDropRate = rendererFrameAttempts > 0
      ? Double(droppedFrames) / Double(rendererFrameAttempts)
      : 1
    let libVLCFrameAttempts = displayedPictures + lostPictures
    let libVLCDropRate = libVLCFrameAttempts > 0
      ? Double(lostPictures) / Double(libVLCFrameAttempts)
      : 1
    let presentationRate = Double(deliveredFrames) / Double(durationSeconds)
    guard rendererDropRate <= 0.05, libVLCDropRate <= 0.05, presentationRate >= 54 else {
      throw PiPPerformanceFailure("60 fps delivery fell outside the release budget")
    }
    guard (samples.last?.decodedContentChanges ?? 0) > (samples.first?.decodedContentChanges ?? 0) else {
      throw PiPPerformanceFailure("Decoded content stopped changing")
    }

    let cpuStart = samples.first?.cpuSeconds ?? 0
    let cpuEnd = samples.last?.cpuSeconds ?? cpuStart
    guard cpuEnd > cpuStart else {
      throw PiPPerformanceFailure("Mach CPU sampling did not advance")
    }
    let cpuSeconds = max(0, cpuEnd - cpuStart)
    return PiPPerformanceAnalysis(
      metrics: PiPPerformanceMetrics(
        cpu: PiPScalarMetric(value: cpuSeconds, unit: "cpu-seconds", source: "Mach task thread times"),
        gpu: PiPTraceMetric(status: "required-host-augmentation", source: "Instruments Game Performance"),
        rss: PiPRSSMetric(
          baselineBytes: firstRSS,
          peakBytes: peakRSS,
          finalBytes: finalRSS,
          growthBytes: rssGrowth,
          limitBytes: 160 * 1_048_576,
          peakGrowthBytes: peakRSSGrowth,
          peakLimitBytes: 256 * 1_048_576
        ),
        energy: PiPTraceMetric(status: "required-host-augmentation", source: "Instruments Power Profiler"),
        thermal: PiPThermalMetric(states: Array(thermalStates).sorted()),
        conversionCost: PiPConversionMetric(
          sourcePixels: sourcePixels,
          minimumTargetPixels: validTargets.map { $0.targetWidth * $0.targetHeight }.min() ?? sourcePixels,
          convertedFrames: convertedFrames,
          measuredConversions: measuredConversions,
          totalMilliseconds: Double(measuredConversionNanoseconds) / 1_000_000,
          averageMilliseconds: Double(measuredConversionNanoseconds) / Double(measuredConversions) / 1_000_000,
          maximumMilliseconds: Double(maximumMeasuredConversionNanoseconds) / 1_000_000,
          signpost: "PixelBufferRenderer.outputPixelBuffer",
          hostTraceStatus: "required-host-augmentation"
        ),
        frameDrops: PiPFrameDropMetric(
          displayedPictures: displayedPictures,
          lostPictures: lostPictures,
          libVLCDropRate: libVLCDropRate,
          rendererDeliveredFrames: deliveredFrames,
          rendererDroppedFrames: droppedFrames,
          rendererDropRate: rendererDropRate
        ),
        presentationRate: PiPScalarMetric(
          value: presentationRate,
          unit: "frames-per-second",
          source: "AVSampleBufferDisplayLayer delivery telemetry"
        )
      )
    )
  }

  private static func counterDelta(_ current: UInt64, _ previous: UInt64) -> UInt64 {
    current >= previous ? current - previous : current
  }

  private static func sample(elapsed: Int, renderer: PiPRenderPerformanceSnapshot) -> PiPPerformanceSample {
    var basic = mach_task_basic_info()
    var basicCount = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let basicStatus = withUnsafeMutablePointer(to: &basic) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(basicCount)) {
        task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &basicCount)
      }
    }
    var times = task_thread_times_info()
    var timesCount = mach_msg_type_number_t(MemoryLayout<task_thread_times_info>.size / MemoryLayout<natural_t>.size)
    let timesStatus = withUnsafeMutablePointer(to: &times) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(timesCount)) {
        task_info(mach_task_self_, task_flavor_t(TASK_THREAD_TIMES_INFO), $0, &timesCount)
      }
    }
    let cpu = timesStatus == KERN_SUCCESS
      ? Double(times.user_time.seconds + times.system_time.seconds)
      + Double(times.user_time.microseconds + times.system_time.microseconds) / 1_000_000
      : 0
    return PiPPerformanceSample(
      elapsedSeconds: elapsed,
      residentBytes: basicStatus == KERN_SUCCESS ? basic.resident_size : 0,
      cpuSeconds: cpu,
      thermalState: ProcessInfo.processInfo.thermalState.qualificationName,
      sourceWidth: renderer.sourceWidth,
      sourceHeight: renderer.sourceHeight,
      targetWidth: renderer.targetWidth ?? 0,
      targetHeight: renderer.targetHeight ?? 0,
      presentationCopyFrames: renderer.presentationCopyFrames,
      presentationCopyFailures: renderer.presentationCopyFailures,
      measuredConversionCount: renderer.measuredConversionCount,
      measuredConversionNanoseconds: renderer.measuredConversionNanoseconds,
      maximumMeasuredConversionNanoseconds: renderer.maximumMeasuredConversionNanoseconds,
      decodedContentChanges: renderer.decodedContentChanges,
      displayConsumeFailures: renderer.displayConsumeFailures,
      renderPoolAllocationFailureCount: renderer.renderPoolAllocationFailureCount,
      lastRenderPoolAllocationStatus: renderer.lastRenderPoolAllocationStatus,
      deliveredFrameCount: renderer.deliveredFrameCount,
      droppedFrameCount: renderer.droppedFrameCount
    )
  }

  private func waitUntil(_ failure: String, timeout: Duration, condition: @escaping @MainActor () -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition() {
      try Task.checkCancellation()
      guard clock.now < deadline else { throw PiPPerformanceFailure(failure) }
      try await Task.sleep(for: .milliseconds(100))
    }
  }

  private func valueRow(_ title: String, value: String, identifier: String) -> some View {
    HStack { Text(title); Spacer(); Text(value).foregroundStyle(.secondary).accessibilityIdentifier(identifier) }
  }
}

private enum PiPPerformanceProfile: String {
  case p1080 = "1080p60"
  case p4k = "4k60"
  var width: Int {
    self == .p1080 ? 1920 : 3840
  }

  var height: Int {
    self == .p1080 ? 1080 : 2160
  }
}

private struct PiPPerformanceSample: Encodable {
  let elapsedSeconds: Int
  let residentBytes: UInt64
  let cpuSeconds: Double
  let thermalState: String
  let sourceWidth: Int
  let sourceHeight: Int
  let targetWidth: Int
  let targetHeight: Int
  let presentationCopyFrames: UInt64
  let presentationCopyFailures: UInt64
  let measuredConversionCount: UInt64
  let measuredConversionNanoseconds: UInt64
  let maximumMeasuredConversionNanoseconds: UInt64
  let decodedContentChanges: UInt64
  let displayConsumeFailures: UInt64
  let renderPoolAllocationFailureCount: UInt64
  let lastRenderPoolAllocationStatus: Int32?
  let deliveredFrameCount: UInt64
  let droppedFrameCount: UInt64
}

private struct PiPPerformanceEvidence: Encodable {
  let profile: String
  let durationSeconds: Int
  let metrics: PiPPerformanceMetrics
  let samples: [PiPPerformanceSample]
  let resizeCycles: Int
  let resizeTargets: [String]
  let replacementCount: Int
  let inlineQuality: String
  let effectiveWorkOutcome: String
  let boundedMemory: Bool
  let boundedWork: Bool
  let hostTraceRequirements: [String: String]
}

private struct PiPPerformanceAnalysis { let metrics: PiPPerformanceMetrics }
private struct PiPPerformanceMetrics: Encodable {
  let cpu: PiPScalarMetric
  let gpu: PiPTraceMetric
  let rss: PiPRSSMetric
  let energy: PiPTraceMetric
  let thermal: PiPThermalMetric
  let conversionCost: PiPConversionMetric
  let frameDrops: PiPFrameDropMetric
  let presentationRate: PiPScalarMetric
}

private struct PiPScalarMetric: Encodable { let value: Double; let unit: String; let source: String }
private struct PiPTraceMetric: Encodable { let status: String; let source: String }
private struct PiPRSSMetric: Encodable {
  let baselineBytes: UInt64
  let peakBytes: UInt64
  let finalBytes: UInt64
  let growthBytes: UInt64
  let limitBytes: UInt64
  let peakGrowthBytes: UInt64
  let peakLimitBytes: UInt64
}

private struct PiPThermalMetric: Encodable { let states: [String] }
private struct PiPConversionMetric: Encodable {
  let sourcePixels: Int
  let minimumTargetPixels: Int
  let convertedFrames: UInt64
  let measuredConversions: UInt64
  let totalMilliseconds: Double
  let averageMilliseconds: Double
  let maximumMilliseconds: Double
  let signpost: String
  let hostTraceStatus: String
}

private struct PiPFrameDropMetric: Encodable {
  let displayedPictures: UInt64
  let lostPictures: UInt64
  let libVLCDropRate: Double
  let rendererDeliveredFrames: UInt64
  let rendererDroppedFrames: UInt64
  let rendererDropRate: Double
}

private struct PiPPerformanceFailure: Error, CustomStringConvertible { let description: String; init(_ description: String) {
  self.description = description
} }

extension ProcessInfo.ThermalState {
  fileprivate var qualificationName: String {
    switch self {
    case .nominal: "nominal"
    case .fair: "fair"
    case .serious: "serious"
    case .critical: "critical"
    @unknown default: "unknown"
    }
  }
}
