#if os(macOS)
@testable import SwiftVLC
import CLibVLC
import CustomDump
import Testing

extension Logic {
  @Suite(.tags(.mainActor, .async))
  @MainActor struct MacVideoOutputRecoveryTests {
    @Test
    func `waits for deselection before restoring the expected track`() async {
      var selections: [String?] = ["video", nil, nil]
      var events: [String] = []

      await MacVideoOutputRecovery(
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

      await MacVideoOutputRecovery(
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

      await MacVideoOutputRecovery(
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

      await MacVideoOutputRecovery(
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

      await MacVideoOutputRecovery(
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
  @MainActor struct MacVideoOutputRecoveryIntegrationTests {
    @Test
    func `player wrapper performs recovery through controlled native operations`() async throws {
      let player = Player(instance: TestInstance.shared)
      try player.load(Media(url: TestMedia.twosecURL))
      player._setStateForTesting(state: .playing)
      var selections: [String?] = ["video", "video", nil, nil]
      var events: [String] = []
      let native = MacVideoOutputRecoveryNativeOperations(
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
        player.reopenVideoOutputAfterDrawableWindowMove(using: native)
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
      let native = MacVideoOutputRecoveryNativeOperations(
        selectedTrackID: { _ in
          events.append("selected:none")
          return nil
        },
        unselectVideoTrack: { _ in events.append("unselect") },
        reselectVideoTrack: { _, _ in events.append("reselect") },
        waitForDeselection: { events.append("wait") }
      )

      let recovery = player.reopenVideoOutputAfterDrawableWindowMove(using: native)

      if recovery != nil {
        Issue.record("Expected recovery not to start without a selected video track")
      }
      expectNoDifference(events, ["selected:none"])
    }

    @Test
    func `live player wrapper exits safely without an active video output`() throws {
      let player = Player(instance: TestInstance.shared)
      try player.load(Media(url: TestMedia.twosecURL))

      let recovery = player.reopenVideoOutputAfterDrawableWindowMove()

      if recovery != nil {
        Issue.record("Expected recovery not to start without an active video output")
      }
    }

    @Test
    func `live native recovery operations are safe for an inactive player`() async {
      let player = Player(instance: TestInstance.shared)
      let native = MacVideoOutputRecoveryNativeOperations.live

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
#endif
