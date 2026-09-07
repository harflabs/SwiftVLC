import CryptoKit
import Foundation
import SwiftUI
import SwiftVLC

struct LocalFileMatrixValidationCase: View {
  var body: some View {
    LocalPlaybackQualificationValidationCase(expectedKind: .video)
  }
}

struct AudioOnlyPlaybackValidationCase: View {
  var body: some View {
    LocalPlaybackQualificationValidationCase(expectedKind: .audio)
  }
}

private struct LocalPlaybackQualificationValidationCase: View {
  @State private var player = Player()
  @State private var result = "not-run"
  @State private var errorMessage: String?
  @State private var isRunning = false
  @State private var runTask: Task<Void, Never>?

  let expectedKind: LocalPlaybackQualificationKind

  private var fixture: LocalPlaybackFixtureContract? {
    LocalPlaybackFixtureContract.fixture(id: LaunchArguments.localPlaybackFixtureIDValue)
  }

  var body: some View {
    _ = player.currentTime
    return Form {
      if expectedKind == .video {
        Section {
          VideoView(player)
            .frame(height: 230)
            .background(.black)
            .listRowInsets(EdgeInsets())
            .accessibilityIdentifier(AccessibilityID.LocalFileMatrixValidation.videoView)
        }
      }

      Section("Native playback evidence") {
        Button("Run fixture") {
          runTask = Task { await run() }
        }
        .disabled(isRunning)
        .accessibilityIdentifier(
          expectedKind == .video
            ? AccessibilityID.LocalFileMatrixValidation.runButton
            : AccessibilityID.AudioOnlyPlaybackValidation.runButton
        )
        valueRow(
          "Fixture",
          value: fixture?.id ?? "missing",
          identifier: fixtureIdentifier
        )
        valueRow(
          "Player state",
          value: player.state.description,
          identifier: stateIdentifier
        )
        valueRow("Qualification", value: result, identifier: resultIdentifier)
        if let errorMessage {
          Text(errorMessage)
            .foregroundStyle(.red)
            .accessibilityIdentifier(errorIdentifier)
        }
      }
    }
    .showcaseFormStyle()
    .navigationTitle(expectedKind == .video ? "Local file matrix" : "Audio-only matrix")
    .onDisappear {
      runTask?.cancel()
      player.stop()
    }
  }

  private var fixtureIdentifier: String {
    expectedKind == .video
      ? AccessibilityID.LocalFileMatrixValidation.fixtureLabel
      : AccessibilityID.AudioOnlyPlaybackValidation.fixtureLabel
  }

  private var stateIdentifier: String {
    expectedKind == .video
      ? AccessibilityID.LocalFileMatrixValidation.stateLabel
      : AccessibilityID.AudioOnlyPlaybackValidation.stateLabel
  }

  private var resultIdentifier: String {
    expectedKind == .video
      ? AccessibilityID.LocalFileMatrixValidation.resultLabel
      : AccessibilityID.AudioOnlyPlaybackValidation.resultLabel
  }

  private var errorIdentifier: String {
    expectedKind == .video
      ? AccessibilityID.LocalFileMatrixValidation.errorLabel
      : AccessibilityID.AudioOnlyPlaybackValidation.errorLabel
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

  private func run() async {
    guard !isRunning else { return }
    isRunning = true
    result = "running"
    errorMessage = nil
    defer { isRunning = false }
    do {
      guard LaunchArguments.isUITestMode else {
        throw LocalPlaybackQualificationFailure("This surface is UI-test only")
      }
      guard
        let fixture,
        fixture.kind == expectedKind,
        let baseURL = LaunchArguments.localPlaybackBaseURLValue
      else {
        throw LocalPlaybackQualificationFailure("Missing or mismatched fixture contract")
      }

      let remoteURL = fixture.relativePath.split(separator: "/").reduce(
        baseURL.appendingPathComponent("files", isDirectory: true)
      ) { partial, component in
        partial.appendingPathComponent(String(component), isDirectory: false)
      }
      let (data, response) = try await URLSession.shared.data(from: remoteURL)
      guard
        let response = response as? HTTPURLResponse,
        response.statusCode == 200,
        !data.isEmpty
      else {
        throw LocalPlaybackQualificationFailure("Fixture download did not return bytes")
      }

      let directory = try localFixtureDirectory()
      let localURL = directory.appendingPathComponent(
        fixture.relativePath.replacingOccurrences(of: "/", with: "-"),
        isDirectory: false
      )
      try data.write(to: localURL, options: .atomic)
      guard localURL.isFileURL, try Data(contentsOf: localURL) == data else {
        throw LocalPlaybackQualificationFailure("Persisted local fixture differs from download")
      }

      let generationBefore = player.generation.description
      try player.play(url: localURL)
      var states = [player.state.description]
      try await waitUntil(timeout: .seconds(30)) {
        appendState(&states)
        return player.state == .playing
          && player.currentTime.milliseconds > 0
          && player.statistics != nil
      }
      let generationAfter = player.generation.description
      let measurementStartSystemUptime = ProcessInfo.processInfo.systemUptime
      // Publish this only after the app-owned native counter window has opened.
      // The UI test waits for it before taking its independent pixel captures,
      // so host validation can prove both oracles observed the same playback.
      result = "measuring"
      let started = ContinuousClock.now
      let start = try snapshot()
      try await Task.sleep(for: .milliseconds(5000))
      appendState(&states)
      let end = try snapshot()
      let elapsed = started.duration(to: .now).milliseconds
      let measurementEndSystemUptime = ProcessInfo.processInfo.systemUptime

      try validateProgress(start: start, end: end)
      guard
        generationBefore != generationAfter,
        !states.contains("error"),
        states.contains("playing"),
        let duration = player.duration?.milliseconds,
        duration >= 10000
      else {
        throw LocalPlaybackQualificationFailure("Native playback identity/state was not healthy")
      }

      let raw = LocalPlaybackRawResult(
        fixture: fixture,
        sourceScheme: localURL.scheme ?? "",
        localFileName: localURL.lastPathComponent,
        downloadedSHA256: SHA256.hash(data: data)
          .map { String(format: "%02x", $0) }
          .joined(),
        downloadedBytes: data.count,
        generationBefore: generationBefore,
        generationAfter: generationAfter,
        stateSequence: states,
        durationMilliseconds: duration,
        measurementDurationMilliseconds: elapsed,
        measurementStartSystemUptime: measurementStartSystemUptime,
        measurementEndSystemUptime: measurementEndSystemUptime,
        start: start,
        end: end
      )
      result = try "pass:\(JSONEncoder().encode(raw).base64EncodedString())"
    } catch is CancellationError {
      result = "cancelled"
    } catch {
      player.stop()
      errorMessage = String(describing: error)
      result = "failed"
    }
  }

  private func localFixtureDirectory() throws -> URL {
    let root = try FileManager.default.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
    let directory = root.appendingPathComponent("QualificationLocalPlayback", isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    return directory
  }

  private func snapshot() throws -> LocalPlaybackCounterSnapshot {
    guard let statistics = player.statistics else {
      throw LocalPlaybackQualificationFailure("Native media statistics are unavailable")
    }
    return LocalPlaybackCounterSnapshot(
      timeMilliseconds: player.currentTime.milliseconds,
      readBytes: statistics.readBytes,
      demuxReadBytes: statistics.demuxReadBytes,
      decodedVideo: statistics.decodedVideo,
      decodedAudio: statistics.decodedAudio,
      displayedPictures: statistics.displayedPictures,
      lostPictures: statistics.lostPictures,
      playedAudioBuffers: statistics.playedAudioBuffers,
      lostAudioBuffers: statistics.lostAudioBuffers
    )
  }

  private func validateProgress(
    start: LocalPlaybackCounterSnapshot,
    end: LocalPlaybackCounterSnapshot
  )
    throws {
    guard
      end.timeMilliseconds - start.timeMilliseconds >= 2000,
      end.readBytes > 0,
      end.demuxReadBytes > 0,
      end.readBytes >= start.readBytes,
      end.demuxReadBytes >= start.demuxReadBytes
    else {
      throw LocalPlaybackQualificationFailure("Native input clock/demux did not advance")
    }
    switch expectedKind {
    case .video:
      guard
        end.playedAudioBuffers >= start.playedAudioBuffers,
        end.lostAudioBuffers >= start.lostAudioBuffers
      else {
        throw LocalPlaybackQualificationFailure("Video audio counters moved backward")
      }
      let played = end.playedAudioBuffers - start.playedAudioBuffers
      let lostAudio = end.lostAudioBuffers - start.lostAudioBuffers
      guard
        end.decodedVideo > 0,
        end.decodedVideo >= start.decodedVideo,
        end.displayedPictures >= start.displayedPictures,
        end.displayedPictures - start.displayedPictures >= 10,
        end.decodedAudio > 0,
        end.decodedAudio >= start.decodedAudio,
        played >= 5,
        lostAudio <= max(1, played / 20)
      else {
        throw LocalPlaybackQualificationFailure("Video/audio decoder output did not advance")
      }
    case .audio:
      guard
        end.decodedAudio >= start.decodedAudio,
        end.playedAudioBuffers >= start.playedAudioBuffers,
        end.lostAudioBuffers >= start.lostAudioBuffers,
        start.decodedVideo == 0,
        end.decodedVideo == 0,
        start.displayedPictures == 0,
        end.displayedPictures == 0,
        start.lostPictures == 0,
        end.lostPictures == 0
      else {
        throw LocalPlaybackQualificationFailure("Audio counters moved backward")
      }
      let played = end.playedAudioBuffers - start.playedAudioBuffers
      let lost = end.lostAudioBuffers - start.lostAudioBuffers
      guard
        end.decodedAudio > 0,
        end.decodedAudio >= start.decodedAudio,
        played >= 5,
        lost <= max(1, played / 20)
      else {
        throw LocalPlaybackQualificationFailure("Audio decoder/output did not advance cleanly")
      }
    }
  }

  private func appendState(_ states: inout [String]) {
    let state = player.state.description
    if states.last != state {
      states.append(state)
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
    throw LocalPlaybackQualificationFailure("Playback did not reach the measurement state")
  }
}

private struct LocalPlaybackQualificationFailure: Error, CustomStringConvertible {
  let description: String

  init(_ description: String) {
    self.description = description
  }
}

extension Duration {
  fileprivate var milliseconds: Int64 {
    let components = components
    return components.seconds * 1000
      + Int64(components.attoseconds / 1_000_000_000_000_000)
  }
}
