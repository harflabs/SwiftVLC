import Foundation
import SwiftUI
import SwiftVLC

/// Candidate-side native clock/counter oracle for progressive HTTP seeking.
/// The host independently owns the HTTP transcript and XCTest owns pixels;
/// this surface never summarizes or claims network behavior.
struct ProgressiveHTTPRangeSeekValidationCase: View {
  private enum PendingResult {
    case range(
      start: ProgressiveHTTPRangeCounterSnapshot,
      landing: ProgressiveHTTPRangeCounterSnapshot,
      typed: ProgressiveHTTPRangeTypedSeek
    )
    case noRange(
      start: ProgressiveHTTPRangeCounterSnapshot,
      rejection: ProgressiveHTTPRangeTypedRejection
    )
  }

  @State private var player = Player()
  @State private var result = "preparing"
  @State private var errorMessage: String?
  @State private var isRunning = false
  @State private var isReady = false
  @State private var pending: PendingResult?

  private let baseURL = LaunchArguments.progressiveHTTPRangeBaseURLValue
  private let attemptToken = LaunchArguments.progressiveHTTPRangeAttemptTokenValue
  private let mode = LaunchArguments.progressiveHTTPRangeModeValue

  private var mediaURL: URL? {
    guard let baseURL, let attemptToken, let mode else { return nil }
    return ProgressiveHTTPRangeSeekContract.mediaPath(token: attemptToken, mode: mode)
      .split(separator: "/")
      .reduce(baseURL) { partial, component in
        partial.appendingPathComponent(String(component), isDirectory: false)
      }
  }

  var body: some View {
    _ = player.currentTime
    return Form {
      Section {
        VideoView(player)
          .aspectRatio(16 / 9, contentMode: .fit)
          .background(.black)
          .listRowInsets(EdgeInsets())
          .accessibilityIdentifier(
            AccessibilityID.ProgressiveHTTPRangeSeekValidation.videoView
          )
      }

      Section("Native progressive seek evidence") {
        valueRow(
          "Mode",
          value: mode?.rawValue ?? "missing",
          identifier: AccessibilityID.ProgressiveHTTPRangeSeekValidation.modeLabel
        )
        valueRow(
          "Player state",
          value: player.state.description,
          identifier: AccessibilityID.ProgressiveHTTPRangeSeekValidation.stateLabel
        )
        valueRow(
          "Qualification",
          value: result,
          identifier: AccessibilityID.ProgressiveHTTPRangeSeekValidation.resultLabel
        )
        if let errorMessage {
          Text(errorMessage)
            .foregroundStyle(.red)
            .accessibilityIdentifier(
              AccessibilityID.ProgressiveHTTPRangeSeekValidation.errorLabel
            )
        }
      }

      Section("Commands") {
        Button("Request strict seek") {
          Task { await requestSeek() }
        }
        .accessibilityIdentifier(
          AccessibilityID.ProgressiveHTTPRangeSeekValidation.commandButton
        )
        .disabled(!isReady || isRunning || pending != nil)

        Button("Finalize counter window") {
          Task { await finalize() }
        }
        .accessibilityIdentifier(
          AccessibilityID.ProgressiveHTTPRangeSeekValidation.finalizeButton
        )
        .disabled(isRunning || pending == nil)
      }
    }
    .showcaseFormStyle()
    .navigationTitle("Progressive HTTP seek")
    .task { await prepare() }
    .onDisappear { player.stop() }
  }

  private func valueRow(_ title: String, value: String, identifier: String) -> some View {
    HStack {
      Text(title)
      Spacer()
      Text(value)
        .monospacedDigit()
        .accessibilityIdentifier(identifier)
    }
  }

  @MainActor
  private func prepare() async {
    guard !isRunning, !isReady else { return }
    isRunning = true
    errorMessage = nil
    result = "preparing"
    defer { isRunning = false }
    do {
      guard LaunchArguments.isUITestMode else {
        throw ProgressiveHTTPRangeFailure("This surface is UI-test only")
      }
      guard let mediaURL, let mode, attemptToken != nil else {
        throw ProgressiveHTTPRangeFailure("Progressive HTTP launch contract is missing")
      }
      try player.play(url: mediaURL)
      try await waitUntil(timeout: .seconds(30)) {
        guard let statistics = player.statistics else { return false }
        return player.state == .playing
          && player.currentTime.progressiveMilliseconds >= 500
          && statistics.readBytes > 0
          && statistics.decodedVideo > 0
          && statistics.displayedPictures > 0
      }
      try await Task.sleep(for: .milliseconds(500))
      guard
        let duration = player.duration?.progressiveMilliseconds,
        duration >= ProgressiveHTTPRangeSeekContract.expectedDurationMilliseconds - 500,
        (mode == .range && player.isSeekable)
        || (mode == .noRange && !player.isSeekable)
      else {
        throw ProgressiveHTTPRangeFailure(
          "HTTP seek capability did not converge to the pinned endpoint contract"
        )
      }
      isReady = true
      result = "ready"
    } catch is CancellationError {
      result = "cancelled"
    } catch {
      player.stop()
      errorMessage = String(describing: error)
      result = "failed"
    }
  }

  @MainActor
  private func requestSeek() async {
    guard !isRunning, isReady, pending == nil, let mode, let attemptToken else { return }
    isRunning = true
    errorMessage = nil
    result = "commanding"
    defer { isRunning = false }
    do {
      let start = try snapshot()
      switch mode {
      case .range:
        try await markCommand(token: attemptToken, mode: mode)
        let request = try player.requestSeek(
          to: .milliseconds(ProgressiveHTTPRangeSeekContract.targetMilliseconds),
          fast: false
        )
        let terminal = await request.outcome
        guard request.initialOutcome == .pending, terminal == .settled else {
          throw ProgressiveHTTPRangeFailure(
            "Range seek did not publish pending then settled"
          )
        }
        try await waitUntil(timeout: .seconds(20)) {
          let clock = player.currentTime.progressiveMilliseconds
          let pictures = player.statistics?.displayedPictures ?? 0
          return clock >= ProgressiveHTTPRangeSeekContract.targetMilliseconds
            - ProgressiveHTTPRangeSeekContract.seekToleranceMilliseconds
            && pictures > start.displayedPictures
        }
        let landing = try snapshot()
        let typed = ProgressiveHTTPRangeTypedSeek(
          commandAttemptToken: attemptToken,
          playbackGeneration: start.playbackGeneration,
          targetMilliseconds: ProgressiveHTTPRangeSeekContract.targetMilliseconds,
          fast: false,
          initialOutcome: seekName(request.initialOutcome),
          terminalOutcome: seekName(terminal)
        )
        pending = .range(start: start, landing: landing, typed: typed)
        result = try encoded(typed, prefix: "landed")

      case .noRange:
        guard !start.isSeekable else {
          throw ProgressiveHTTPRangeFailure("No-Range source became seekable")
        }
        let rejection: ProgressiveHTTPRangeTypedRejection
        try await markCommand(token: attemptToken, mode: mode)
        do {
          _ = try player.requestSeek(
            to: .milliseconds(ProgressiveHTTPRangeSeekContract.targetMilliseconds),
            fast: false
          )
          throw ProgressiveHTTPRangeFailure("No-Range strict seek was accepted")
        } catch let error as VLCError {
          guard
            case .invalidState(let message) = error,
            message == "current media is not seekable"
          else {
            throw ProgressiveHTTPRangeFailure(
              "No-Range strict seek produced the wrong typed error: \(error)"
            )
          }
          rejection = ProgressiveHTTPRangeTypedRejection(
            commandAttemptToken: attemptToken,
            playbackGeneration: start.playbackGeneration,
            errorDomain: "SwiftVLC.VLCError",
            errorCase: "invalidState",
            message: message,
            commandDispatched: false
          )
        }
        pending = .noRange(start: start, rejection: rejection)
        result = try encoded(rejection, prefix: "rejected")
      }
    } catch is CancellationError {
      result = "cancelled"
    } catch {
      errorMessage = String(describing: error)
      result = "failed"
    }
  }

  @MainActor
  private func finalize() async {
    guard !isRunning, let pending, let attemptToken, let mediaURL else { return }
    isRunning = true
    errorMessage = nil
    defer { isRunning = false }
    do {
      switch pending {
      case .range(let start, let landing, let typed):
        let end = try snapshot()
        guard
          landing.currentTimeMilliseconds
          >= ProgressiveHTTPRangeSeekContract.targetMilliseconds
          - ProgressiveHTTPRangeSeekContract.seekToleranceMilliseconds,
          landing.currentTimeMilliseconds
          <= ProgressiveHTTPRangeSeekContract.targetMilliseconds
          + ProgressiveHTTPRangeSeekContract.seekToleranceMilliseconds,
          landing.decodedVideo >= start.decodedVideo,
          landing.displayedPictures > start.displayedPictures,
          end.currentTimeMilliseconds > landing.currentTimeMilliseconds,
          end.displayedPictures > landing.displayedPictures,
          end.systemUptimeSeconds > landing.systemUptimeSeconds
        else {
          throw ProgressiveHTTPRangeFailure(
            "Range seek native clock/output did not remain healthy through pixel capture"
          )
        }
        let raw = ProgressiveHTTPRangeSuccess(
          mode: ProgressiveHTTPRangeSeekContract.Mode.range.rawValue,
          attemptToken: attemptToken,
          sourcePath: mediaURL.path,
          targetMilliseconds: ProgressiveHTTPRangeSeekContract.targetMilliseconds,
          landingBoundaryMilliseconds:
          ProgressiveHTTPRangeSeekContract.landingBoundaryMilliseconds,
          typedSeek: typed,
          start: start,
          landing: landing,
          end: end
        )
        result = try encoded(raw, prefix: "pass")

      case .noRange(let start, let rejection):
        try await waitUntil(timeout: .seconds(2)) {
          ProcessInfo.processInfo.systemUptime - start.systemUptimeSeconds >= 1
        }
        let end = try snapshot()
        guard
          !start.isSeekable,
          !end.isSeekable,
          end.currentTimeMilliseconds - start.currentTimeMilliseconds >= 700,
          end.currentTimeMilliseconds
          < ProgressiveHTTPRangeSeekContract.landingBoundaryMilliseconds,
          end.decodedVideo >= start.decodedVideo,
          end.displayedPictures - start.displayedPictures >= 3,
          end.systemUptimeSeconds - start.systemUptimeSeconds >= 0.7
        else {
          throw ProgressiveHTTPRangeFailure(
            "No-Range typed rejection did not preserve continuing playback"
          )
        }
        let raw = ProgressiveHTTPNoRangeSuccess(
          mode: ProgressiveHTTPRangeSeekContract.Mode.noRange.rawValue,
          attemptToken: attemptToken,
          sourcePath: mediaURL.path,
          targetMilliseconds: ProgressiveHTTPRangeSeekContract.targetMilliseconds,
          seekableAtCommand: start.isSeekable,
          typedRejection: rejection,
          start: start,
          end: end
        )
        result = try encoded(raw, prefix: "pass")
      }
      self.pending = nil
    } catch {
      errorMessage = String(describing: error)
      result = "failed"
    }
  }

  private func snapshot() throws -> ProgressiveHTTPRangeCounterSnapshot {
    guard let statistics = player.statistics else {
      throw ProgressiveHTTPRangeFailure("Native media statistics are unavailable")
    }
    return ProgressiveHTTPRangeCounterSnapshot(
      systemUptimeSeconds: ProcessInfo.processInfo.systemUptime,
      playbackGeneration: player.generation.description,
      state: player.state.description,
      currentTimeMilliseconds: player.currentTime.progressiveMilliseconds,
      durationMilliseconds: player.duration?.progressiveMilliseconds ?? -1,
      isSeekable: player.isSeekable,
      readBytes: statistics.readBytes,
      demuxReadBytes: statistics.demuxReadBytes,
      decodedVideo: statistics.decodedVideo,
      displayedPictures: statistics.displayedPictures,
      lostPictures: statistics.lostPictures
    )
  }

  @MainActor
  private func markCommand(
    token: String,
    mode: ProgressiveHTTPRangeSeekContract.Mode
  )
    async throws {
    guard let baseURL else {
      throw ProgressiveHTTPRangeFailure("Progressive command marker has no base URL")
    }
    let url = ProgressiveHTTPRangeSeekContract.commandPath(token: token, mode: mode)
      .split(separator: "/")
      .reduce(baseURL) { partial, component in
        partial.appendingPathComponent(String(component), isDirectory: false)
      }
    var request = URLRequest(
      url: url,
      cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
      timeoutInterval: 5
    )
    request.setValue(
      ProgressiveHTTPRangeSeekContract.commandOrigin,
      forHTTPHeaderField: ProgressiveHTTPRangeSeekContract.commandOriginHeader
    )
    let (data, response) = try await URLSession.shared.data(for: request)
    guard
      let response = response as? HTTPURLResponse,
      response.statusCode == 200,
      let marker = try? JSONDecoder().decode(
        ProgressiveHTTPRangeCommandMarkerAcknowledgment.self,
        from: data
      ),
      marker.kind == "command-marker",
      marker.sequence > 0,
      marker.token == token,
      marker.mode == mode.rawValue,
      marker.phase == "post-command",
      marker.origin == ProgressiveHTTPRangeSeekContract.commandOrigin,
      marker.precommandRequestCount > 0,
      marker.precommandTransferredBytes > 0,
      !marker.markedAtUTC.isEmpty
    else {
      throw ProgressiveHTTPRangeFailure("Progressive command marker was not acknowledged")
    }
  }

  private func waitUntil(
    timeout: Duration,
    condition: @escaping @MainActor () -> Bool
  )
    async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
      if condition() {
        return
      }
      try await Task.sleep(for: .milliseconds(100))
    }
    throw ProgressiveHTTPRangeFailure("Timed out waiting for native playback evidence")
  }

  private func encoded(_ value: some Encodable, prefix: String) throws -> String {
    try "\(prefix):\(JSONEncoder().encode(value).base64EncodedString())"
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
}

private struct ProgressiveHTTPRangeFailure: Error, CustomStringConvertible {
  let description: String

  init(_ description: String) {
    self.description = description
  }
}

extension Duration {
  fileprivate var progressiveMilliseconds: Int64 {
    let components = components
    return components.seconds * 1000
      + Int64(components.attoseconds / 1_000_000_000_000_000)
  }
}
