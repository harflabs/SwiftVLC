@testable import SwiftVLC
import CLibVLC
import Testing

/// Covers `mapEvent` — the switch-heavy C-event → Swift-PlayerEvent
/// translator. Most branches don't fire in headless tests because
/// real decoder/output events never reach the event thread. We
/// synthesize `libvlc_event_t` values directly and assert the mapped
/// Swift variant.
///
/// This is the one file that exercises all 30+ libVLC event cases,
/// so a future libVLC enum reshuffle surfaces as named test failures
/// rather than silent `nil` returns.
@Suite(.tags(.logic))
struct MapEventTests {
  // MARK: - Helpers

  private func event(type rawType: UInt32, configure: (inout libvlc_event_t) -> Void = { _ in }) -> libvlc_event_t {
    var e = libvlc_event_t()
    e.type = Int32(rawType)
    configure(&e)
    return e
  }

  // MARK: - State transitions

  @Test
  func `NothingSpecial maps to stateChanged(.idle)`() {
    let mapped = mapEvent(event(type: libvlc_MediaPlayerNothingSpecial.rawValue))
    guard case .stateChanged(let s) = mapped else {
      Issue.record("Expected .stateChanged, got \(String(describing: mapped))")
      return
    }
    #expect(s == .idle)
  }

  @Test
  func `Opening maps to stateChanged(.opening)`() {
    let mapped = mapEvent(event(type: libvlc_MediaPlayerOpening.rawValue))
    guard case .stateChanged(.opening) = mapped else {
      Issue.record("Expected .stateChanged(.opening), got \(String(describing: mapped))")
      return
    }
  }

  @Test
  func `Playing maps to stateChanged(.playing)`() {
    let mapped = mapEvent(event(type: libvlc_MediaPlayerPlaying.rawValue))
    guard case .stateChanged(.playing) = mapped else {
      Issue.record("Expected .stateChanged(.playing), got \(String(describing: mapped))")
      return
    }
  }

  @Test
  func `Paused maps to stateChanged(.paused)`() {
    let mapped = mapEvent(event(type: libvlc_MediaPlayerPaused.rawValue))
    guard case .stateChanged(.paused) = mapped else {
      Issue.record("Expected .stateChanged(.paused), got \(String(describing: mapped))")
      return
    }
  }

  @Test
  func `Stopped maps to stateChanged(.stopped)`() {
    let mapped = mapEvent(event(type: libvlc_MediaPlayerStopped.rawValue))
    guard case .stateChanged(.stopped) = mapped else {
      Issue.record("Expected .stateChanged(.stopped)")
      return
    }
  }

  @Test
  func `Stopping maps to stateChanged(.stopping)`() {
    let mapped = mapEvent(event(type: libvlc_MediaPlayerStopping.rawValue))
    guard case .stateChanged(.stopping) = mapped else {
      Issue.record("Expected .stateChanged(.stopping)")
      return
    }
  }

  @Test
  func `EncounteredError maps to encounteredError`() {
    let mapped = mapEvent(event(type: libvlc_MediaPlayerEncounteredError.rawValue))
    guard case .encounteredError = mapped else {
      Issue.record("Expected .encounteredError")
      return
    }
  }

  @Test
  func `MediaChanged maps to mediaChanged`() {
    let mapped = mapEvent(event(type: libvlc_MediaPlayerMediaChanged.rawValue))
    guard case .mediaChanged = mapped else {
      Issue.record("Expected .mediaChanged")
      return
    }
  }

  // MARK: - Time / position / length

  @Test
  func `TimeChanged maps with milliseconds payload`() {
    let e = event(type: libvlc_MediaPlayerTimeChanged.rawValue) { e in
      e.u.media_player_time_changed.new_time = 42000
    }
    guard case .timeChanged(let d) = mapEvent(e) else {
      Issue.record("Expected .timeChanged")
      return
    }
    #expect(d == .milliseconds(42000))
  }

  @Test
  func `PositionChanged maps with fractional payload`() {
    let e = event(type: libvlc_MediaPlayerPositionChanged.rawValue) { e in
      e.u.media_player_position_changed.new_position = 0.75
    }
    guard case .positionChanged(let p) = mapEvent(e) else {
      Issue.record("Expected .positionChanged")
      return
    }
    #expect(abs(p - 0.75) < 0.001)
  }

  @Test
  func `LengthChanged maps with milliseconds payload`() {
    let e = event(type: libvlc_MediaPlayerLengthChanged.rawValue) { e in
      e.u.media_player_length_changed.new_length = 180_000
    }
    guard case .lengthChanged(let d) = mapEvent(e) else {
      Issue.record("Expected .lengthChanged")
      return
    }
    #expect(d == .milliseconds(180_000))
  }

  @Test
  func `SeekableChanged maps to Bool`() {
    let e = event(type: libvlc_MediaPlayerSeekableChanged.rawValue) { e in
      e.u.media_player_seekable_changed.new_seekable = 1
    }
    guard case .seekableChanged(true) = mapEvent(e) else {
      Issue.record("Expected .seekableChanged(true)")
      return
    }
  }

  @Test
  func `PausableChanged maps to Bool`() {
    let e = event(type: libvlc_MediaPlayerPausableChanged.rawValue) { e in
      e.u.media_player_pausable_changed.new_pausable = 0
    }
    guard case .pausableChanged(false) = mapEvent(e) else {
      Issue.record("Expected .pausableChanged(false)")
      return
    }
  }

  // MARK: - ES events collapse to tracksChanged

  @Test
  func `ESAdded maps to tracksChanged`() {
    let e = event(type: libvlc_MediaPlayerESAdded.rawValue)
    guard case .tracksChanged = mapEvent(e) else {
      Issue.record("Expected .tracksChanged")
      return
    }
  }

  @Test
  func `ESDeleted maps to tracksChanged`() {
    let e = event(type: libvlc_MediaPlayerESDeleted.rawValue)
    guard case .tracksChanged = mapEvent(e) else {
      Issue.record("Expected .tracksChanged")
      return
    }
  }

  @Test
  func `ESSelected maps to tracksChanged`() {
    let e = event(type: libvlc_MediaPlayerESSelected.rawValue)
    guard case .tracksChanged = mapEvent(e) else {
      Issue.record("Expected .tracksChanged")
      return
    }
  }

  @Test
  func `ESUpdated maps to tracksChanged`() {
    let e = event(type: libvlc_MediaPlayerESUpdated.rawValue)
    guard case .tracksChanged = mapEvent(e) else {
      Issue.record("Expected .tracksChanged")
      return
    }
  }

  // MARK: - Audio / video outputs

  @Test
  func `Vout maps to voutChanged`() {
    let e = event(type: libvlc_MediaPlayerVout.rawValue) { e in
      e.u.media_player_vout.new_count = 2
    }
    guard case .voutChanged(let count) = mapEvent(e) else {
      Issue.record("Expected .voutChanged")
      return
    }
    #expect(count == 2)
  }

  @Test
  func `Muted maps to muted`() {
    guard case .muted = mapEvent(event(type: libvlc_MediaPlayerMuted.rawValue)) else {
      Issue.record("Expected .muted")
      return
    }
  }

  @Test
  func `Unmuted maps to unmuted`() {
    guard case .unmuted = mapEvent(event(type: libvlc_MediaPlayerUnmuted.rawValue)) else {
      Issue.record("Expected .unmuted")
      return
    }
  }

  @Test
  func `Corked maps to corked`() {
    guard case .corked = mapEvent(event(type: libvlc_MediaPlayerCorked.rawValue)) else {
      Issue.record("Expected .corked")
      return
    }
  }

  @Test
  func `Uncorked maps to uncorked`() {
    guard case .uncorked = mapEvent(event(type: libvlc_MediaPlayerUncorked.rawValue)) else {
      Issue.record("Expected .uncorked")
      return
    }
  }

  @Test
  func `AudioVolume maps to volumeChanged`() {
    let e = event(type: libvlc_MediaPlayerAudioVolume.rawValue) { e in
      e.u.media_player_audio_volume.volume = 0.8
    }
    guard case .volumeChanged(let v) = mapEvent(e) else {
      Issue.record("Expected .volumeChanged")
      return
    }
    #expect(abs(v - 0.8) < 0.001)
  }

  // MARK: - Media stopping

  @Test
  func `MediaStopping maps to mediaStopping`() {
    guard case .mediaStopping = mapEvent(event(type: libvlc_MediaPlayerMediaStopping.rawValue)) else {
      Issue.record("Expected .mediaStopping")
      return
    }
  }

  // MARK: - Chapters

  @Test
  func `ChapterChanged maps with chapter index`() {
    let e = event(type: libvlc_MediaPlayerChapterChanged.rawValue) { e in
      e.u.media_player_chapter_changed.new_chapter = 5
    }
    guard case .chapterChanged(let c) = mapEvent(e) else {
      Issue.record("Expected .chapterChanged")
      return
    }
    #expect(c == 5)
  }

  // MARK: - Title list / selection

  @Test
  func `TitleListChanged maps to titleListChanged`() {
    guard case .titleListChanged = mapEvent(event(type: libvlc_MediaPlayerTitleListChanged.rawValue)) else {
      Issue.record("Expected .titleListChanged")
      return
    }
  }

  @Test
  func `TitleSelectionChanged maps with index`() {
    let e = event(type: libvlc_MediaPlayerTitleSelectionChanged.rawValue) { e in
      e.u.media_player_title_selection_changed.index = 3
    }
    guard case .titleSelectionChanged(let i) = mapEvent(e) else {
      Issue.record("Expected .titleSelectionChanged")
      return
    }
    #expect(i == 3)
  }

  // MARK: - Programs

  @Test
  func `ProgramAdded maps with id`() {
    let e = event(type: libvlc_MediaPlayerProgramAdded.rawValue) { e in
      e.u.media_player_program_changed.i_id = 7
    }
    guard case .programAdded(let id) = mapEvent(e) else {
      Issue.record("Expected .programAdded")
      return
    }
    #expect(id == 7)
  }

  @Test
  func `ProgramDeleted maps with id`() {
    let e = event(type: libvlc_MediaPlayerProgramDeleted.rawValue) { e in
      e.u.media_player_program_changed.i_id = 8
    }
    guard case .programDeleted(let id) = mapEvent(e) else {
      Issue.record("Expected .programDeleted")
      return
    }
    #expect(id == 8)
  }

  @Test
  func `ProgramUpdated maps with id`() {
    let e = event(type: libvlc_MediaPlayerProgramUpdated.rawValue) { e in
      e.u.media_player_program_changed.i_id = 9
    }
    guard case .programUpdated(let id) = mapEvent(e) else {
      Issue.record("Expected .programUpdated")
      return
    }
    #expect(id == 9)
  }

  @Test
  func `ProgramSelected maps with both ids`() {
    let e = event(type: libvlc_MediaPlayerProgramSelected.rawValue) { e in
      e.u.media_player_program_selection_changed.i_unselected_id = 1
      e.u.media_player_program_selection_changed.i_selected_id = 2
    }
    guard case .programSelected(let unsel, let sel) = mapEvent(e) else {
      Issue.record("Expected .programSelected")
      return
    }
    #expect(unsel == 1)
    #expect(sel == 2)
  }

  // MARK: - Buffering

  @Test
  func `Buffering maps to bufferingProgress with normalized value`() {
    let e = event(type: libvlc_MediaPlayerBuffering.rawValue) { e in
      e.u.media_player_buffering.new_cache = 50
    }
    guard case .bufferingProgress(let p) = mapEvent(e) else {
      Issue.record("Expected .bufferingProgress")
      return
    }
    #expect(abs(p - 0.5) < 0.001, "libVLC emits 0–100; wrapper must normalize to 0–1")
  }

  // MARK: - AudioDevice / Recording / Snapshot

  @Test
  func `AudioDevice with nil device maps to audioDeviceChanged(nil)`() {
    let e = event(type: libvlc_MediaPlayerAudioDevice.rawValue) { e in
      e.u.media_player_audio_device.device = nil
    }
    guard case .audioDeviceChanged(let device) = mapEvent(e) else {
      Issue.record("Expected .audioDeviceChanged")
      return
    }
    #expect(device == nil)
  }

  // MARK: - Unknown / default

  @Test
  func `Unknown event type maps to nil`() {
    // A large raw value outside the libvlc_event_e range forces the
    // `default` branch. Covers `return nil`.
    let mapped = mapEvent(event(type: 99999))
    if mapped != nil {
      Issue.record("Expected nil, got \(String(describing: mapped))")
    }
  }
}
