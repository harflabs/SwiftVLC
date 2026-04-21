import Foundation

/// Identifiers used by XCUITest to locate SwiftUI controls.
///
/// Compiled into both the showcase app target (where each constant is applied
/// via `.accessibilityIdentifier(...)`) and the UI test target (where it is
/// used to query the resulting `XCUIElement`s). Renaming a constant here is a
/// compile-time break on both sides, not a runtime test failure.
enum AccessibilityID {
  enum Root {
    static let navigationStack = "root.nav"
    static func sectionLink(_ title: String) -> String {
      "root.link.\(title)"
    }
  }

  enum SimplePlayback {
    static let videoView = "sp.videoView"
    static let playPauseButton = "sp.playPause"
    static let currentTime = "sp.currentTime"
    static let duration = "sp.duration"
  }

  enum PlayerState {
    static let videoView = "ps.videoView"
    static let playPauseButton = "ps.playPause"
    static let stateLabel = "ps.state"
    static let seekableLabel = "ps.seekable"
    static let pausableLabel = "ps.pausable"
  }

  enum Seeking {
    static let videoView = "seek.videoView"
    static let playPauseButton = "seek.playPause"
  }

  /// Shared across every showcase that uses `SeekBar`, so consumers
  /// (tests for Seeking, RelativeSeek, ABLoop, Chapters, …) can query
  /// the same identifiers without each showcase redefining them.
  enum SeekBar {
    static let slider = "seekbar.slider"
    static let currentTime = "seekbar.currentTime"
    static let duration = "seekbar.duration"
  }

  enum Volume {
    static let videoView = "vol.videoView"
    static let playPauseButton = "vol.playPause"
    static let slider = "vol.slider"
    static let level = "vol.level"
    static let muteToggle = "vol.mute"
  }

  enum ABLoop {
    static let videoView = "abloop.videoView"
    static let playPauseButton = "abloop.playPause"
    static let stateLabel = "abloop.state"
    static let aLabel = "abloop.a"
    static let bLabel = "abloop.b"
    static let currentTimeLabel = "abloop.currentTime"
    static let markAButton = "abloop.markA"
    static let markBButton = "abloop.markB"
    static let resetButton = "abloop.reset"
  }

  enum RelativeSeek {
    static let videoView = "relseek.videoView"
    static let playPauseButton = "relseek.playPause"
    static let skipBack30 = "relseek.skipBack30"
    static let skipBack10 = "relseek.skipBack10"
    static let skipForward10 = "relseek.skipForward10"
    static let skipForward30 = "relseek.skipForward30"
  }

  enum FrameStep {
    static let videoView = "framestep.videoView"
    static let playPauseButton = "framestep.playPause"
    static let pausableLabel = "framestep.pausable"
    static let timeLabel = "framestep.time"
    static let nextFrameButton = "framestep.nextFrame"
  }

  enum Rate {
    static let videoView = "rate.videoView"
    static let playPauseButton = "rate.playPause"
    static let currentLabel = "rate.current"
    static let slider = "rate.slider"
  }

  enum Thumbnails {
    static let generateButton = "thumb.generate"
    static let offsetSlider = "thumb.offsetSlider"
    static let offsetLabel = "thumb.offsetLabel"
    static let thumbnailImage = "thumb.image"
    static let emptyPlaceholder = "thumb.empty"
    static let progressIndicator = "thumb.progress"
  }

  enum AudioTracks {
    static let videoView = "audiotracks.videoView"
    static let playPauseButton = "audiotracks.playPause"
    static let loadingLabel = "audiotracks.loading"
    static let trackPicker = "audiotracks.picker"
  }

  enum Snapshot {
    static let videoView = "snapshot.videoView"
    static let playPauseButton = "snapshot.playPause"
    static let takeSnapshotButton = "snapshot.take"
    static let snapshotImage = "snapshot.image"
  }

  enum PiP {
    static let videoView = "pip.videoView"
    static let playPauseButton = "pip.playPause"
    static let possibleLabel = "pip.possible"
    static let activeLabel = "pip.active"
    static let toggleButton = "pip.toggle"
    static let preparingLabel = "pip.preparing"
  }

  enum AudioOutputs {
    static let videoView = "audioout.videoView"
    static let playPauseButton = "audioout.playPause"
    static let outputEmptyLabel = "audioout.outputEmpty"
    static let outputPicker = "audioout.outputPicker"
    static let deviceEmptyLabel = "audioout.deviceEmpty"
    static let devicePicker = "audioout.devicePicker"
  }

  enum Lifecycle {
    static let videoView = "lifecycle.videoView"
    static let playPauseButton = "lifecycle.playPause"
    static let sourcePicker = "lifecycle.sourcePicker"
  }

  enum AspectRatio {
    static let videoView = "aspect.videoView"
    static let playPauseButton = "aspect.playPause"
    static let ratioPicker = "aspect.ratioPicker"
  }

  enum Deinterlacing {
    static let videoView = "deinterlace.videoView"
    static let playPauseButton = "deinterlace.playPause"
    static let statePicker = "deinterlace.statePicker"
    static let modePicker = "deinterlace.modePicker"
  }

  enum Equalizer {
    static let videoView = "eq.videoView"
    static let playPauseButton = "eq.playPause"
    static let presetPicker = "eq.presetPicker"
    static let preampSlider = "eq.preampSlider"
    static let preampGainLabel = "eq.preampGain"
  }

  enum AudioChannels {
    static let videoView = "channels.videoView"
    static let playPauseButton = "channels.playPause"
    static let stereoPicker = "channels.stereoPicker"
    static let mixPicker = "channels.mixPicker"
  }

  enum AudioDelay {
    static let videoView = "audiodelay.videoView"
    static let playPauseButton = "audiodelay.playPause"
    static let slider = "audiodelay.slider"
    static let offsetLabel = "audiodelay.offset"
  }

  enum Recording {
    static let videoView = "rec.videoView"
    static let playPauseButton = "rec.playPause"
    static let toggleButton = "rec.toggle"
    static let savedToLabel = "rec.savedTo"
  }

  enum Marquee {
    static let videoView = "marquee.videoView"
    static let playPauseButton = "marquee.playPause"
    static let enabledToggle = "marquee.enabled"
    static let textField = "marquee.text"
    static let opacityLabel = "marquee.opacityLabel"
    static let opacitySlider = "marquee.opacitySlider"
  }

  enum Adjustments {
    static let videoView = "adj.videoView"
    static let playPauseButton = "adj.playPause"
    static let enabledToggle = "adj.enabled"
    static let brightnessSlider = "adj.brightnessSlider"
  }

  enum Viewpoint {
    static let videoView = "viewpoint.videoView"
    static let playPauseButton = "viewpoint.playPause"
    static let yawSlider = "viewpoint.yawSlider"
    static let pitchSlider = "viewpoint.pitchSlider"
    static let fovSlider = "viewpoint.fovSlider"
  }

  enum SubtitlesSelection {
    static let videoView = "subsel.videoView"
    static let playPauseButton = "subsel.playPause"
    static let emptyLabel = "subsel.empty"
    static let picker = "subsel.picker"
  }

  enum SubtitlesExternal {
    static let videoView = "subext.videoView"
    static let playPauseButton = "subext.playPause"
    static let loadButton = "subext.load"
  }
}
