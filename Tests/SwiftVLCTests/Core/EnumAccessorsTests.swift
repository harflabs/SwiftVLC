@testable import SwiftVLC
import Testing

/// Verifies the per-case accessor extensions on `PlayerEvent`,
/// `PlayerState`, `VLCError`, `DialogEvent`, and `RendererEvent`.
///
/// Each accessor returns the case's associated value (or `Void` for
/// cases without one) when `self` matches, and `nil` otherwise. This
/// gives callers ergonomic `events.compactMap(\.timeChanged)` and
/// `error.parseTimeout != nil` syntax without a third-party
/// dependency.
extension Logic {
  struct EnumAccessorsTests {
    // MARK: - PlayerEvent

    @Test func `PlayerEvent timeChanged accessor extracts associated Duration`() {
      let event: PlayerEvent = .timeChanged(.seconds(42))
      #expect(event.timeChanged == .seconds(42))
      #expect(event.stateChanged == nil)
      #expect(event.tracksChanged == nil)
    }

    @Test func `PlayerEvent stateChanged accessor extracts associated PlayerState`() {
      let event: PlayerEvent = .stateChanged(.playing)
      #expect(event.stateChanged == .playing)
      #expect(event.timeChanged == nil)
    }

    @Test func `PlayerEvent void cases return Void on match, nil otherwise`() {
      let tracks: PlayerEvent = .tracksChanged
      #expect(tracks.tracksChanged != nil)
      #expect(tracks.mediaChanged == nil)

      let media: PlayerEvent = .mediaChanged
      #expect(media.mediaChanged != nil)
      #expect(media.tracksChanged == nil)
    }

    @Test func `PlayerEvent recordingChanged accessor extracts tuple`() {
      let event: PlayerEvent = .recordingChanged(isRecording: true, filePath: "/tmp/x.mp4")
      let extracted = event.recordingChanged
      #expect(extracted?.isRecording == true)
      #expect(extracted?.filePath == "/tmp/x.mp4")
    }

    @Test func `PlayerEvent programSelected accessor extracts tuple`() {
      let event: PlayerEvent = .programSelected(unselectedId: 1, selectedId: 2)
      let extracted = event.programSelected
      #expect(extracted?.unselectedId == 1)
      #expect(extracted?.selectedId == 2)
    }

    @Test func `PlayerEvent compactMap pattern works on a sequence`() {
      let events: [PlayerEvent] = [
        .stateChanged(.opening),
        .timeChanged(.seconds(1)),
        .stateChanged(.playing),
        .timeChanged(.seconds(2)),
        .tracksChanged,
        .timeChanged(.seconds(3))
      ]
      let times = events.compactMap(\.timeChanged)
      #expect(times == [.seconds(1), .seconds(2), .seconds(3)])

      let states = events.compactMap(\.stateChanged)
      #expect(states == [.opening, .playing])
    }

    // MARK: - PlayerState

    @Test func `PlayerState isPlaying boolean accessor`() {
      #expect(PlayerState.playing.isPlaying)
      #expect(!PlayerState.paused.isPlaying)
      #expect(!PlayerState.playing.isPaused)
      #expect(PlayerState.paused.isPaused)
    }

    @Test func `PlayerState all eight isX accessors are mutually exclusive`() {
      let cases: [(PlayerState, [Bool])] = [
        (.idle, [true, false, false, false, false, false, false, false]),
        (.opening, [false, true, false, false, false, false, false, false]),
        (.buffering, [false, false, true, false, false, false, false, false]),
        (.playing, [false, false, false, true, false, false, false, false]),
        (.paused, [false, false, false, false, true, false, false, false]),
        (.stopped, [false, false, false, false, false, true, false, false]),
        (.stopping, [false, false, false, false, false, false, true, false]),
        (.error, [false, false, false, false, false, false, false, true])
      ]
      for (state, expected) in cases {
        let actual = [
          state.isIdle, state.isOpening, state.isBuffering, state.isPlaying,
          state.isPaused, state.isStopped, state.isStopping, state.isError
        ]
        #expect(actual == expected, "wrong booleans for \(state)")
      }
    }

    // MARK: - VLCError

    @Test func `VLCError parseTimeout accessor for case without associated value`() {
      let error: VLCError = .parseTimeout
      #expect(error.parseTimeout != nil)
      #expect(error.playbackFailed == nil)
    }

    @Test func `VLCError mediaCreationFailed accessor extracts source string`() {
      let error: VLCError = .mediaCreationFailed(source: "https://example.com/x.mp4")
      #expect(error.mediaCreationFailed == "https://example.com/x.mp4")
      #expect(error.parseTimeout == nil)
    }

    @Test func `VLCError filter pattern works`() {
      let errors: [VLCError] = [
        .parseTimeout,
        .playbackFailed(reason: "network"),
        .parseFailed(reason: "format"),
        .parseTimeout,
        .operationFailed("seek")
      ]
      let timeoutCount = errors.count(where: { $0.parseTimeout != nil })
      #expect(timeoutCount == 2)

      let playbackReasons = errors.compactMap(\.playbackFailed)
      #expect(playbackReasons == ["network"])
    }

    // MARK: - DialogEvent

    @Test func `DialogEvent error accessor extracts title and message`() {
      let event: DialogEvent = .error(title: "Bad", message: "thing happened")
      let extracted = event.error
      #expect(extracted?.title == "Bad")
      #expect(extracted?.message == "thing happened")

      #expect(event.login == nil)
      #expect(event.question == nil)
    }
  }
}
