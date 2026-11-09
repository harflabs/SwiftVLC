#if os(macOS)
@testable import SwiftVLC
import AppKit
import CLibVLC
import CustomDump
import Foundation
import Testing

extension Logic {
  @Suite(.tags(.mainActor, .async))
  @MainActor struct VideoOutputRecoveryTests {
    @Test
    func `waits for deselection before restoring the expected track`() async {
      var selections: [String?] = ["video", nil, nil]
      var events: [String] = []

      await VideoOutputRecovery(
        expectedTrackID: "video",
        playbackIsCurrent: {
          events.append("current")
          return true
        },
        playbackState: {
          events.append("playing")
          return .playing
        },
        selectedTrackID: {
          let selection = selections.removeFirst()
          events.append("selected:\(selection ?? "none")")
          return selection
        },
        waitForDeselection: {
          events.append("wait")
        },
        reselectTrack: { trackID in
          events.append("reselect:\(trackID)")
        }
      ).run()

      expectNoDifference(
        events,
        [
          "current",
          "selected:video",
          "wait",
          "current",
          "selected:none",
          "current",
          "playing",
          "selected:none",
          "reselect:video"
        ]
      )
    }

    @Test
    func `aborts when the media or native player changes while waiting`() async {
      var isCurrent = true
      var selectedTrack: String? = "video"
      var reselectedTracks: [String] = []

      await VideoOutputRecovery(
        expectedTrackID: "video",
        playbackIsCurrent: { isCurrent },
        playbackState: { .playing },
        selectedTrackID: { selectedTrack },
        waitForDeselection: {
          selectedTrack = nil
          isCurrent = false
        },
        reselectTrack: { reselectedTracks.append($0) }
      ).run()

      expectNoDifference(reselectedTracks, [])
    }

    @Test(
      arguments: [
        PlayerState.idle,
        .stopped,
        .stopping,
        .error,
      ]
    )
    func `does not restore video for terminal playback states`(state: PlayerState) async {
      var reselectedTracks: [String] = []

      await VideoOutputRecovery(
        expectedTrackID: "video",
        playbackIsCurrent: { true },
        playbackState: { state },
        selectedTrackID: { nil },
        waitForDeselection: {},
        reselectTrack: { reselectedTracks.append($0) }
      ).run()

      expectNoDifference(reselectedTracks, [])
    }

    @Test
    func `does not overwrite a different track selected during recovery`() async {
      var selections: [String?] = [nil, "replacement"]
      var reselectedTracks: [String] = []

      await VideoOutputRecovery(
        expectedTrackID: "video",
        playbackIsCurrent: { true },
        playbackState: { .paused },
        selectedTrackID: { selections.removeFirst() },
        waitForDeselection: {},
        reselectTrack: { reselectedTracks.append($0) }
      ).run()

      expectNoDifference(reselectedTracks, [])
    }

    @Test
    func `bounded polling still makes a final restore attempt`() async {
      var pollCount = 0
      var reselectedTracks: [String] = []

      await VideoOutputRecovery(
        expectedTrackID: "video",
        maximumDeselectionPolls: 2,
        playbackIsCurrent: { true },
        playbackState: { .buffering },
        selectedTrackID: { "video" },
        waitForDeselection: { pollCount += 1 },
        reselectTrack: { reselectedTracks.append($0) }
      ).run()

      #expect(pollCount == 2)
      expectNoDifference(reselectedTracks, ["video"])
    }
  }
}

extension Integration {
  @Suite(.tags(.mainActor, .async))
  @MainActor struct VideoOutputRecoveryIntegrationTests {
    @Test
    func `player wrapper performs recovery through controlled native operations`() async throws {
      let player = Player(instance: TestInstance.shared)
      try player.load(Media(url: TestMedia.twosecURL))
      player._setStateForTesting(state: .playing)
      var selections: [String?] = ["video", "video", nil, nil]
      var events: [String] = []
      let native = VideoOutputRecoveryNativeOperations(
        selectedTrackID: { _ in
          let selection = selections.removeFirst()
          events.append("selected:\(selection ?? "none")")
          return selection
        },
        unselectVideoTrack: { _ in
          events.append("unselect")
        },
        reselectVideoTrack: { _, trackID in
          events.append("reselect:\(trackID)")
        },
        waitForDeselection: {
          events.append("wait")
        }
      )

      let recovery = try #require(
        player.reopenVideoOutput(using: native)
      )
      await recovery.value

      expectNoDifference(
        events,
        [
          "selected:video",
          "unselect",
          "selected:video",
          "wait",
          "selected:none",
          "selected:none",
          "reselect:video"
        ]
      )
    }

    @Test
    func `player wrapper stops before unselecting when no video track is selected`() throws {
      let player = Player(instance: TestInstance.shared)
      try player.load(Media(url: TestMedia.twosecURL))
      var events: [String] = []
      let native = VideoOutputRecoveryNativeOperations(
        selectedTrackID: { _ in
          events.append("selected:none")
          return nil
        },
        unselectVideoTrack: { _ in events.append("unselect") },
        reselectVideoTrack: { _, _ in events.append("reselect") },
        waitForDeselection: { events.append("wait") }
      )

      let recovery = player.reopenVideoOutput(using: native)

      if recovery != nil {
        Issue.record("Expected recovery not to start without a selected video track")
      }
      expectNoDifference(events, ["selected:none"])
    }

    @Test
    func `abandoned output is reopened once the drawable is in a window`() async throws {
      let player = Player(instance: TestInstance.shared)
      try player.load(Media(url: TestMedia.twosecURL))
      let output = RecordingVideoOutput()
      let view = NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 64))
      player.setDrawable(view)
      player._setStateForTesting(state: .playing)

      // Not hostable yet: the check stays armed instead of being consumed.
      #expect(player.recoverAbandonedVideoOutputIfNeeded(using: output.operations) == nil)
      #expect(player.abandonedVideoOutputCheckPending)

      let window = NSWindow(
        contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: true
      )
      window.contentView?.addSubview(view)
      let recovery = try #require(player.recoverAbandonedVideoOutputIfNeeded(using: output.operations))
      await recovery.value
      expectNoDifference(output.events, ["unselect", "reselect:video"])

      // One check per arming: a later time update does not reopen again.
      #expect(player.recoverAbandonedVideoOutputIfNeeded(using: output.operations) == nil)

      // A live output consumes a new arming without touching the track.
      player.activeVideoOutputs = 1
      player.setDrawable(view)
      #expect(player.recoverAbandonedVideoOutputIfNeeded(using: output.operations) == nil)
      #expect(!player.abandonedVideoOutputCheckPending)
      expectNoDifference(output.events, ["unselect", "reselect:video"])
    }

    @Test
    func `abandoned output check waits for playback`() throws {
      let player = Player(instance: TestInstance.shared)
      try player.load(Media(url: TestMedia.twosecURL))
      let output = RecordingVideoOutput()
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 64, height: 64),
        styleMask: .borderless, backing: .buffered, defer: true
      )
      let view = NSView(frame: window.contentLayoutRect)
      window.contentView?.addSubview(view)
      player.setDrawable(view)
      player._setStateForTesting(state: .paused)

      #expect(player.recoverAbandonedVideoOutputIfNeeded(using: output.operations) == nil)
      #expect(player.abandonedVideoOutputCheckPending)
      expectNoDifference(output.events, [])
    }

    @Test
    func `live player wrapper exits safely without an active video output`() throws {
      let player = Player(instance: TestInstance.shared)
      try player.load(Media(url: TestMedia.twosecURL))

      let recovery = player.reopenVideoOutput()

      if recovery != nil {
        Issue.record("Expected recovery not to start without an active video output")
      }
    }

    @Test
    func `live native recovery operations are safe for an inactive player`() async {
      let player = Player(instance: TestInstance.shared)
      let native = VideoOutputRecoveryNativeOperations.live

      #expect(native.selectedTrackID(player.pointer) == nil)
      native.unselectVideoTrack(player.pointer)
      native.reselectVideoTrack(player.pointer, "video")
      await native.waitForDeselection()
    }

    @Test
    func `native track adapter adopts and returns a parsed track identifier`() async throws {
      let media = try Media(url: TestMedia.testMP4URL)
      _ = try await media.parse()
      let trackList = try #require(
        libvlc_media_get_tracklist(media.pointer, libvlc_track_video)
      )
      defer { libvlc_media_tracklist_delete(trackList) }
      try #require(libvlc_media_tracklist_count(trackList) > 0)
      let track = try #require(libvlc_media_tracklist_at(trackList, 0))
      let id = try #require(track.pointee.psz_id)
      let expectedID = String(cString: id)
      let ownedTrack = try #require(libvlc_media_track_hold(track))

      #expect(nativeTrackID(adopting: ownedTrack) == expectedID)
    }
  }
}

extension Integration {
  /// Playback started before any view could host video: libVLC fails to open
  /// a display, unloads every video decoder and keeps playing audio only.
  @Suite(.tags(.mainActor, .async, .media))
  @MainActor struct AbandonedVideoOutputPlaybackTests {
    @Test(
      .enabled(
        if: ProcessInfo.processInfo.environment["SWIFTVLC_NATIVE_SEEK_TESTS"] == "1"
          && TestCondition.canPlayMedia,
        "Requires the rebuilt release XCFramework and a window server"
      ),
      .timeLimit(.minutes(1))
    )
    func `video output opens when the view arrives after playback started`() async throws {
      let fixtureURL = try #require(Bundle.module.url(
        forResource: "paused-seek", withExtension: "mp4", subdirectory: "Fixtures"
      ))
      let instance = try VLCInstance(
        arguments: VLCInstance.defaultArguments + ["--aout=dummy", "--quiet"]
      )
      let player = Player(instance: instance)
      defer { player.stop() }
      try player.play(url: fixtureURL)
      #expect(try await poll(timeout: .seconds(5)) {
        player.state == .playing && player.currentTime > .milliseconds(500)
      })
      try #require(
        player.activeVideoOutputs == 0,
        "precondition: libVLC must have abandoned the output without a drawable"
      )

      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 160, height: 90),
        styleMask: .borderless, backing: .buffered, defer: false
      )
      let surface = VideoSurface(frame: window.contentLayoutRect)
      window.contentView?.addSubview(surface)
      surface.attach(to: player)

      #expect(try await poll(timeout: .seconds(3)) { player.activeVideoOutputs > 0 })
      surface.detach()
    }
  }
}

/// A video track whose output libVLC has abandoned, observed through the
/// native operations the recovery uses.
@MainActor
private final class RecordingVideoOutput {
  var selectedTrackID: String? = "video"
  var events: [String] = []

  var operations: VideoOutputRecoveryNativeOperations {
    VideoOutputRecoveryNativeOperations(
      selectedTrackID: { [unowned self] _ in selectedTrackID },
      unselectVideoTrack: { [unowned self] _ in
        events.append("unselect")
        selectedTrackID = nil
      },
      reselectVideoTrack: { [unowned self] _, trackID in
        events.append("reselect:\(trackID)")
        selectedTrackID = trackID
      },
      waitForDeselection: {}
    )
  }
}
#endif
