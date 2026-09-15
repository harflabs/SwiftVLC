import Foundation
import SwiftUI
import SwiftVLC

/// Drives deterministic sparse-GOP and all-intra fixtures through the public
/// completion-reporting APIs. XCTest supplies the independent screenshot
/// oracle; this view supplies request identity, native terminal outcomes, and
/// the player timeline without inferring pixels from those values.
struct SeekFrameOracleValidationCase: View {
  @State private var player = Player()
  @State private var result = "not-run"
  @State private var error: String?
  @State private var isRunning = false
  @State private var actionOrdinal = 0

  private let baseURL = LaunchArguments.seekFrameOracleBaseURLValue

  private var sparseSeekURL: URL? {
    baseURL?.appending(path: "files/oracles/seek-sparse-gop.mp4")
  }

  private var allIntraURL: URL? {
    baseURL?.appending(path: "files/oracles/frame-all-intra.mp4")
  }

  var body: some View {
    Form {
      Section {
        VideoView(player)
          .aspectRatio(16 / 9, contentMode: .fit)
          .listRowInsets(EdgeInsets())
          .accessibilityIdentifier(AccessibilityID.SeekFrameOracleValidation.videoView)
      }

      Section("Measured state") {
        valueRow(
          "Playback",
          value: String(describing: player.state),
          identifier: AccessibilityID.SeekFrameOracleValidation.stateLabel
        )
        valueRow(
          "Result",
          value: result,
          identifier: AccessibilityID.SeekFrameOracleValidation.resultLabel
        )
        if let error {
          Text(error)
            .foregroundStyle(.red)
            .accessibilityIdentifier(AccessibilityID.SeekFrameOracleValidation.errorLabel)
        }
      }

      Section("Sparse-GOP seek oracle") {
        actionButton(
          "Prepare sparse-GOP fixture",
          identifier: AccessibilityID.SeekFrameOracleValidation.prepareSparseButton,
          action: prepareSparseFixture
        )
        actionButton(
          "Precise seek to 23.5s",
          identifier: AccessibilityID.SeekFrameOracleValidation.preciseSeekButton
        ) {
          try await runSeek(action: "precise-seek", targetMilliseconds: 23500, fast: false)
        }
        actionButton(
          "Fast seek to 40s keyframe",
          identifier: AccessibilityID.SeekFrameOracleValidation.fastSeekButton
        ) {
          try await runSeek(action: "fast-seek", targetMilliseconds: 40000, fast: true)
        }
        actionButton(
          "Run overlapping seek burst",
          identifier: AccessibilityID.SeekFrameOracleValidation.overlapSeekButton,
          action: runOverlappingSeeks
        )
      }

      Section("All-intra frame oracle") {
        actionButton(
          "Prepare all-intra fixture",
          identifier: AccessibilityID.SeekFrameOracleValidation.prepareFramesButton,
          action: prepareFrameFixture
        )
        actionButton(
          "Submit one exact frame",
          identifier: AccessibilityID.SeekFrameOracleValidation.stepOneButton,
          action: submitOneFrame
        )
        actionButton(
          "Submit 20-frame burst",
          identifier: AccessibilityID.SeekFrameOracleValidation.burstButton,
          action: submitFrameBurst
        )
        actionButton(
          "Resume and re-pause clock",
          identifier: AccessibilityID.SeekFrameOracleValidation.resumeButton,
          action: resumeClock
        )
        actionButton(
          "Step through EOF",
          identifier: AccessibilityID.SeekFrameOracleValidation.eofButton,
          action: stepThroughEOF
        )
        actionButton(
          "Replace with queued steps",
          identifier: AccessibilityID.SeekFrameOracleValidation.replacementButton,
          action: replaceWithQueuedSteps
        )
      }
    }
    .showcaseFormStyle()
    .navigationTitle("Seek + frame oracles")
    .onDisappear { player.stop() }
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

  private func actionButton(
    _ title: String,
    identifier: String,
    action: @escaping @MainActor () async throws -> [String: Any]
  ) -> some View {
    Button(title) {
      Task { await perform(title: title, action: action) }
    }
    .accessibilityIdentifier(identifier)
    .disabled(isRunning || baseURL == nil)
  }

  private func perform(
    title: String,
    action: @escaping @MainActor () async throws -> [String: Any]
  )
    async {
    guard !isRunning else { return }
    isRunning = true
    actionOrdinal += 1
    let ordinal = actionOrdinal
    error = nil
    result = "running:\(ordinal):\(title)"
    defer { isRunning = false }
    do {
      var evidence = try await action()
      evidence["ordinal"] = ordinal
      evidence["playbackState"] = String(describing: player.state)
      evidence["currentTimeMilliseconds"] = player.currentTime.milliseconds
      evidence["displayedPictures"] = player.statistics?.displayedPictures ?? 0
      result = try Self.encode(evidence, prefix: "pass")
    } catch {
      self.error = String(describing: error)
      let evidence: [String: Any] = [
        "ordinal": ordinal,
        "action": title,
        "failure": String(describing: error)
      ]
      result = (try? Self.encode(evidence, prefix: "failed")) ?? "failed:encoding"
    }
  }

  private func prepareSparseFixture() async throws -> [String: Any] {
    guard let sparseSeekURL else { throw OracleFailure("Sparse-GOP URL is missing") }
    try await playAndPause(sparseSeekURL)
    return [
      "action": "prepare-sparse",
      "durationMilliseconds": player.duration?.milliseconds ?? -1
    ]
  }

  private func runSeek(
    action: String,
    targetMilliseconds: Int64,
    fast: Bool
  )
    async throws -> [String: Any] {
    let picturesBefore = player.statistics?.displayedPictures ?? 0
    let request = try player.requestSeek(
      to: .milliseconds(targetMilliseconds),
      fast: fast
    )
    let outcome = await request.outcome
    guard outcome == .settled else {
      throw OracleFailure("\(action) ended as \(seekName(outcome))")
    }
    try await Task.sleep(for: .milliseconds(300))
    return [
      "action": action,
      "targetMilliseconds": targetMilliseconds,
      "fast": fast,
      "initialOutcome": seekName(request.initialOutcome),
      "terminalOutcome": seekName(outcome),
      "displayedPicturesBefore": picturesBefore,
      "displayedPicturesAfter": player.statistics?.displayedPictures ?? 0
    ]
  }

  private func runOverlappingSeeks() async throws -> [String: Any] {
    let targets: [Int64] = [12500, 42500, 22500, 52500]
    let picturesBefore = player.statistics?.displayedPictures ?? 0
    var requests: [SeekRequest] = []
    for target in targets {
      try requests.append(player.requestSeek(to: .milliseconds(target)))
    }
    var outcomes: [SeekOutcome] = []
    for request in requests {
      await outcomes.append(request.outcome)
    }
    guard outcomes.dropLast().allSatisfy({ $0 == .superseded }) else {
      throw OracleFailure("An older overlapping seek retained authority")
    }
    guard outcomes.last == .settled else {
      throw OracleFailure("Newest overlapping seek did not settle")
    }
    try await Task.sleep(for: .milliseconds(300))
    return [
      "action": "overlap-seek",
      "targetsMilliseconds": targets,
      "initialOutcomes": requests.map { seekName($0.initialOutcome) },
      "terminalOutcomes": outcomes.map(seekName),
      "authoritativeTargetMilliseconds": targets.last ?? -1,
      "displayedPicturesBefore": picturesBefore,
      "displayedPicturesAfter": player.statistics?.displayedPictures ?? 0
    ]
  }

  private func prepareFrameFixture() async throws -> [String: Any] {
    guard let allIntraURL else { throw OracleFailure("All-intra URL is missing") }
    player.stop()
    try player.play(url: allIntraURL)
    try await waitUntil("All-intra fixture did not start", timeout: .seconds(15)) {
      player.state == .playing && player.isSeekable && player.isPausable
    }
    let seek = try player.requestSeek(to: .seconds(1))
    guard await seek.outcome == .settled else {
      throw OracleFailure("All-intra fixture did not seek to its stable start")
    }
    player.pause()
    try await waitUntil("All-intra fixture did not pause", timeout: .seconds(5)) {
      player.state == .paused
    }
    try await Task.sleep(for: .milliseconds(300))
    return [
      "action": "prepare-frames",
      "seekOutcome": "settled",
      "durationMilliseconds": player.duration?.milliseconds ?? -1
    ]
  }

  private func submitOneFrame() async throws -> [String: Any] {
    let picturesBefore = player.statistics?.displayedPictures ?? 0
    let request = player.requestNextFrame()
    let outcome = await request.outcome
    let submitted = try submittedEvidence(outcome)
    return [
      "action": "frame-one",
      "initialOutcome": frameName(request.initialOutcome),
      "terminalOutcome": frameName(outcome),
      "submittedTimeMilliseconds": submitted.time.milliseconds,
      "submittedPosition": submitted.position?.rawValue ?? NSNull(),
      "displayedPicturesBefore": picturesBefore,
      "displayedPicturesAfter": player.statistics?.displayedPictures ?? 0
    ]
  }

  private func submitFrameBurst() async throws -> [String: Any] {
    let picturesBefore = player.statistics?.displayedPictures ?? 0
    let requests = (0..<20).map { _ in player.requestNextFrame() }
    var outcomes: [FrameStepOutcome] = []
    for request in requests {
      await outcomes.append(request.outcome)
    }
    let submitted = try outcomes.map(submittedEvidence)
    guard zip(submitted, submitted.dropFirst()).allSatisfy({ $0.1.time > $0.0.time }) else {
      throw OracleFailure("Frame burst terminal clocks were not strictly increasing")
    }
    return [
      "action": "frame-burst",
      "requestCount": requests.count,
      "initialOutcomes": requests.map { frameName($0.initialOutcome) },
      "terminalOutcomes": outcomes.map(frameName),
      "submittedTimesMilliseconds": submitted.map(\.time.milliseconds),
      "displayedPicturesBefore": picturesBefore,
      "displayedPicturesAfter": player.statistics?.displayedPictures ?? 0
    ]
  }

  private func resumeClock() async throws -> [String: Any] {
    let timeBefore = player.currentTime.milliseconds
    let picturesBefore = player.statistics?.displayedPictures ?? 0
    player.resume()
    try await waitUntil("Playback did not resume after frame stepping", timeout: .seconds(5)) {
      player.state == .playing
    }
    try await waitUntil("Clock did not advance after frame stepping", timeout: .seconds(5)) {
      player.currentTime.milliseconds >= timeBefore + 800
    }
    player.pause()
    try await waitUntil("Playback did not re-pause", timeout: .seconds(5)) {
      player.state == .paused
    }
    return [
      "action": "resume-clock",
      "timeBeforeMilliseconds": timeBefore,
      "timeAfterMilliseconds": player.currentTime.milliseconds,
      "displayedPicturesBefore": picturesBefore,
      "displayedPicturesAfter": player.statistics?.displayedPictures ?? 0
    ]
  }

  private func stepThroughEOF() async throws -> [String: Any] {
    let seek = try player.requestSeek(to: .milliseconds(11500))
    guard await seek.outcome == .settled else {
      throw OracleFailure("EOF setup seek did not settle")
    }
    var outcomes: [FrameStepOutcome] = []
    for _ in 0..<12 {
      let outcome = await player.requestNextFrame().outcome
      outcomes.append(outcome)
      if outcome == .noFrame {
        break
      }
    }
    guard outcomes.last == .noFrame else {
      throw OracleFailure("Frame stepping did not publish noFrame at EOF")
    }
    guard
      outcomes.dropLast().allSatisfy({
        if case .submitted = $0 {
          true
        } else {
          false
        }
      }) else {
      throw OracleFailure("EOF transition published an unexpected frame terminal")
    }
    let submittedTimes = try outcomes.dropLast().map {
      try submittedEvidence($0).time.milliseconds
    }
    return [
      "action": "frame-eof",
      "terminalOutcomes": outcomes.map(frameName),
      "submittedTimesMilliseconds": submittedTimes,
      "submittedCount": outcomes.count - 1,
      "noFrameCount": 1
    ]
  }

  private func replaceWithQueuedSteps() async throws -> [String: Any] {
    _ = try await prepareFrameFixture()
    let requests = (0..<12).map { _ in player.requestNextFrame() }
    guard let sparseSeekURL else { throw OracleFailure("Sparse-GOP URL is missing") }
    try player.play(url: sparseSeekURL)
    var outcomes: [FrameStepOutcome] = []
    for request in requests {
      await outcomes.append(request.outcome)
    }
    guard outcomes.allSatisfy({ $0 == .superseded }) else {
      throw OracleFailure("Replacement did not supersede every queued frame request")
    }
    return [
      "action": "frame-replacement",
      "requestCount": requests.count,
      "terminalOutcomes": outcomes.map(frameName),
      "supersededCount": outcomes.count
    ]
  }

  private func playAndPause(_ url: URL) async throws {
    player.stop()
    try player.play(url: url)
    try await waitUntil("Fixture did not start", timeout: .seconds(15)) {
      player.state == .playing && player.isSeekable && player.isPausable
    }
    player.pause()
    try await waitUntil("Fixture did not pause", timeout: .seconds(5)) {
      player.state == .paused
    }
    try await Task.sleep(for: .milliseconds(300))
  }

  private func waitUntil(
    _ failure: String,
    timeout: Duration,
    condition: @escaping @MainActor () -> Bool
  )
    async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
      try Task.checkCancellation()
      if condition() {
        return
      }
      try await Task.sleep(for: .milliseconds(50))
    }
    throw OracleFailure(failure)
  }

  private func submittedEvidence(
    _ outcome: FrameStepOutcome
  )
    throws -> (time: Duration, position: PlaybackPosition?) {
    guard case .submitted(let time, let position) = outcome else {
      throw OracleFailure("Frame request ended as \(frameName(outcome))")
    }
    return (time, position)
  }

  private func seekName(_ outcome: SeekOutcome) -> String {
    switch outcome {
    case .pending: "pending"
    case .rejected: "rejected"
    case .settled: "settled"
    case .inaccurate: "inaccurate"
    case .timedOut: "timedOut"
    case .superseded: "superseded"
    }
  }

  private func frameName(_ outcome: FrameStepOutcome) -> String {
    switch outcome {
    case .pending: "pending"
    case .submitted: "submitted"
    case .noFrame: "noFrame"
    case .failed(let code): "failed(\(code))"
    case .invalidEvidence: "invalidEvidence"
    case .timedOut: "timedOut"
    case .superseded: "superseded"
    case .rejected: "rejected"
    }
  }

  private static func encode(_ payload: [String: Any], prefix: String) throws -> String {
    guard JSONSerialization.isValidJSONObject(payload) else {
      throw OracleFailure("Evidence is not valid JSON")
    }
    let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    return "\(prefix):\(data.base64EncodedString())"
  }
}

private struct OracleFailure: Error, CustomStringConvertible {
  let description: String

  init(_ description: String) {
    self.description = description
  }
}
