import Foundation

/// Identifiers used by XCUITest to locate SwiftUI controls.
///
/// Compiled into both the showcase app target (where each constant is applied
/// via `.accessibilityIdentifier(...)`) and the UI test target (where it is
/// used to query the resulting `XCUIElement`s). Renaming a constant here is a
/// compile-time break on both sides, not a runtime test failure.
enum AccessibilityID {
  enum Qualification {
    /// UI-test-only proof read from the candidate's signed Info.plist.
    static let candidateRuntimeBinding = "qualification.candidateRuntimeBinding"
  }

  enum Root {
    static let navigationStack = "root.nav"
    static func sectionLink(_ title: String) -> String {
      "root.link.\(title)"
    }
  }

  enum TestStream {
    static let settingsLink = "testStream.settings"
    static let urlField = "testStream.url"
    static let pasteButton = "testStream.paste"
    static let applyButton = "testStream.apply"
    static let clearButton = "testStream.clear"
    static let currentValue = "testStream.current"
    static let validationError = "testStream.validationError"
  }

  enum MusicPlayer {
    static let playPauseButton = "music.playPause"
    static let currentTime = "music.currentTime"
    static let stateLabel = "music.state"
    static let dismissButton = "music.dismiss"

    static func songButton(_ title: String) -> String {
      "music.song.\(title)"
    }
  }

  enum MacDeinterlace {
    static let statePicker = "macos.deinterlace.state.picker"
    static let stateAutoSegment = "macos.deinterlace.state.auto"
    static let stateOffSegment = "macos.deinterlace.state.off"
    static let stateOnSegment = "macos.deinterlace.state.on"
    static let modePicker = "macos.deinterlace.mode.picker"
    static let stateValue = "macos.deinterlace.state.value"
    static let modeValue = "macos.deinterlace.mode.value"
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
    static let seekBurstStatus = "seek.burst.status"
    static let seekBurstProgress = "seek.burst.progress"
    static let seekBurstSnapshot = "seek.burst.snapshot"
    static let seekBurstResult = "seek.burst.result"
    static let seekBurstError = "seek.burst.error"

    static func seekBurstButton(cadenceMilliseconds: Int) -> String {
      "seek.burst.run.\(cadenceMilliseconds)ms"
    }
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
    static let sameDirectionBurst = "relseek.sameDirectionBurst"
  }

  enum FrameStep {
    static let videoView = "framestep.videoView"
    static let playPauseButton = "framestep.playPause"
    static let pausableLabel = "framestep.pausable"
    static let timeLabel = "framestep.time"
    static let nextFrameButton = "framestep.nextFrame"
  }

  enum SeekFrameOracleValidation {
    static let videoView = "seekFrameOracle.videoView"
    static let stateLabel = "seekFrameOracle.state"
    static let resultLabel = "seekFrameOracle.result"
    static let errorLabel = "seekFrameOracle.error"
    static let prepareSparseButton = "seekFrameOracle.prepareSparse"
    static let preciseSeekButton = "seekFrameOracle.preciseSeek"
    static let fastSeekButton = "seekFrameOracle.fastSeek"
    static let overlapSeekButton = "seekFrameOracle.overlapSeek"
    static let prepareFramesButton = "seekFrameOracle.prepareFrames"
    static let stepOneButton = "seekFrameOracle.stepOne"
    static let burstButton = "seekFrameOracle.burst"
    static let resumeButton = "seekFrameOracle.resume"
    static let eofButton = "seekFrameOracle.eof"
    static let replacementButton = "seekFrameOracle.replacement"
  }

  enum LocalFileMatrixValidation {
    static let runButton = "localFileMatrix.run"
    static let videoView = "localFileMatrix.videoView"
    static let fixtureLabel = "localFileMatrix.fixture"
    static let stateLabel = "localFileMatrix.state"
    static let resultLabel = "localFileMatrix.result"
    static let errorLabel = "localFileMatrix.error"
  }

  enum AudioOnlyPlaybackValidation {
    static let runButton = "audioOnlyPlayback.run"
    static let fixtureLabel = "audioOnlyPlayback.fixture"
    static let stateLabel = "audioOnlyPlayback.state"
    static let resultLabel = "audioOnlyPlayback.result"
    static let errorLabel = "audioOnlyPlayback.error"
  }

  enum ProgressiveHTTPRangeSeekValidation {
    static let videoView = "progressiveHTTPRange.videoView"
    static let modeLabel = "progressiveHTTPRange.mode"
    static let stateLabel = "progressiveHTTPRange.state"
    static let resultLabel = "progressiveHTTPRange.result"
    static let errorLabel = "progressiveHTTPRange.error"
    static let commandButton = "progressiveHTTPRange.command"
    static let finalizeButton = "progressiveHTTPRange.finalize"
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

  enum ThumbnailScrub {
    static let videoView = "thumbscrub.videoView"
    static let playPauseButton = "thumbscrub.playPause"
    static let slider = "thumbscrub.slider"
    static let previewOverlayImage = "thumbscrub.previewImage"
    static let previewLoadingPlaceholder = "thumbscrub.previewLoading"
    static let previewTimeBadge = "thumbscrub.previewBadge"
    static let previewTimeLabel = "thumbscrub.previewTime"
    static let currentTimeLabel = "thumbscrub.currentTime"
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

  enum PiPLiveValidation {
    static let videoView = "pipLive.videoView"
    static let stateLabel = "pipLive.state"
    static let durationLabel = "pipLive.duration"
    static let displayedPicturesLabel = "pipLive.displayedPictures"
    static let playedAudioBuffersLabel = "pipLive.playedAudioBuffers"
    static let backgroundAudioObservationLabel = "pipLive.backgroundAudioObservation"
    static let possibleLabel = "pipLive.possible"
    static let activeLabel = "pipLive.active"
    static let linearPlaybackLabel = "pipLive.linearPlayback"
    static let playbackRangeLabel = "pipLive.playbackRange"
    static let lifecycleEventsLabel = "pipLive.lifecycleEvents"
    static let toggleButton = "pipLive.toggle"
    static let captureDiagnosticsButton = "pipLive.captureDiagnostics"
    static let errorLabel = "pipLive.error"
  }

  enum PiPContinuityValidation {
    static let loadVODButton = "pipContinuity.loadVOD"
    static let loadLiveTSButton = "pipContinuity.loadLiveTS"
    static let stateLabel = "pipContinuity.state"
    static let generationLabel = "pipContinuity.generation"
    static let displayedPicturesLabel = "pipContinuity.displayedPictures"
    static let playedAudioBuffersLabel = "pipContinuity.playedAudioBuffers"
    static let possibleLabel = "pipContinuity.possible"
    static let activeLabel = "pipContinuity.active"
    static let playbackSnapshotLabel = "pipContinuity.playbackSnapshot"
    static let nativePlaybackSnapshotLabel = "pipContinuity.nativePlaybackSnapshot"
    static let continuityEventsLabel = "pipContinuity.continuityEvents"
    static let lifecycleEventsLabel = "pipContinuity.lifecycleEvents"
    static let replacementMeasurementLabel = "pipContinuity.replacementMeasurement"
    static let staleSuccessorMutationsLabel = "pipContinuity.staleSuccessorMutations"
  }

  enum PiPCapabilityValidation {
    static let videoView = "pipCapability.videoView"
    static let loadVODButton = "pipCapability.loadVOD"
    static let loadLiveButton = "pipCapability.loadLive"
    static let stateLabel = "pipCapability.state"
    static let generationLabel = "pipCapability.generation"
    static let currentTimeLabel = "pipCapability.currentTime"
    static let snapshotLabel = "pipCapability.snapshot"
    static let suppressionLabel = "pipCapability.suppression"
    static let possibleLabel = "pipCapability.possible"
    static let activeLabel = "pipCapability.active"
    static let lifecycleEventsLabel = "pipCapability.lifecycleEvents"
    static let skipResultLabel = "pipCapability.skipResult"
    static let toggleButton = "pipCapability.toggle"
    static let skipForwardButton = "pipCapability.skipForward"
    static let errorLabel = "pipCapability.error"
  }

  enum PiPDeferredPauseValidation {
    static let videoView = "pipDeferredPause.videoView"
    static let stateLabel = "pipDeferredPause.state"
    static let intentLabel = "pipDeferredPause.intent"
    static let possibleLabel = "pipDeferredPause.possible"
    static let activeLabel = "pipDeferredPause.active"
    static let resultLabel = "pipDeferredPause.result"
    static let toggleButton = "pipDeferredPause.toggle"
    static let runButton = "pipDeferredPause.run"
    static let errorLabel = "pipDeferredPause.error"
  }

  enum PiPDelayedStartFailureValidation {
    static let videoView = "pipDelayedStartFailure.videoView"
    static let stateLabel = "pipDelayedStartFailure.state"
    static let possibleLabel = "pipDelayedStartFailure.possible"
    static let resultLabel = "pipDelayedStartFailure.result"
    static let runButton = "pipDelayedStartFailure.run"
    static let errorLabel = "pipDelayedStartFailure.error"
  }

  enum PiPVODControlsValidation {
    static let videoView = "pipVODControls.videoView"
    static let stateLabel = "pipVODControls.state"
    static let possibleLabel = "pipVODControls.possible"
    static let activeLabel = "pipVODControls.active"
    static let resultLabel = "pipVODControls.result"
    static let runButton = "pipVODControls.run"
    static let stopButton = "pipVODControls.stop"
    static let errorLabel = "pipVODControls.error"
  }

  enum PiPLongStallValidation {
    static let videoView = "pipLongStall.videoView"
    static let stateLabel = "pipLongStall.state"
    static let possibleLabel = "pipLongStall.possible"
    static let activeLabel = "pipLongStall.active"
    static let healthLabel = "pipLongStall.health"
    static let resultLabel = "pipLongStall.result"
    static let runButton = "pipLongStall.run"
    static let triggerButton = "pipLongStall.trigger"
    static let stopButton = "pipLongStall.stop"
    static let errorLabel = "pipLongStall.error"
  }

  enum PiPDismissalValidation {
    static let videoView = "pipDismissal.videoView"
    static let stateLabel = "pipDismissal.state"
    static let possibleLabel = "pipDismissal.possible"
    static let activeLabel = "pipDismissal.active"
    static let lifecycleEventsLabel = "pipDismissal.lifecycleEvents"
    static let restoreCountLabel = "pipDismissal.restoreCount"
    static let startButton = "pipDismissal.start"
    static let errorLabel = "pipDismissal.error"
  }

  enum PiPInterruptionValidation {
    static let videoView = "pipInterruption.videoView"
    static let stateLabel = "pipInterruption.state"
    static let possibleLabel = "pipInterruption.possible"
    static let activeLabel = "pipInterruption.active"
    static let lifecycleEventsLabel = "pipInterruption.lifecycleEvents"
    static let interruptionCountsLabel = "pipInterruption.interruptionCounts"
    static let routeLossCountLabel = "pipInterruption.routeLossCount"
    static let playedAudioBuffersLabel = "pipInterruption.playedAudioBuffers"
    static let startButton = "pipInterruption.start"
    static let injectRouteLossButton = "pipInterruption.injectRouteLoss"
    static let resumeButton = "pipInterruption.resume"
    static let stopButton = "pipInterruption.stop"
    static let errorLabel = "pipInterruption.error"
  }

  enum MediaServicesResetValidation {
    static let videoView = "mediaServicesReset.videoView"
    static let phaseLabel = "mediaServicesReset.phase"
    static let audioStateLabel = "mediaServicesReset.audioState"
    static let videoStateLabel = "mediaServicesReset.videoState"
    static let pictureInPictureActiveLabel = "mediaServicesReset.pipActive"
    static let notificationCountsLabel = "mediaServicesReset.notifications"
    static let startPictureInPictureButton = "mediaServicesReset.startPiP"
    static let armButton = "mediaServicesReset.arm"
    static let resumeButton = "mediaServicesReset.resume"
    static let resultLabel = "mediaServicesReset.result"
    static let errorLabel = "mediaServicesReset.error"
  }

  enum AudioSessionOwnershipValidation {
    static let phaseLabel = "audioSessionOwnership.phase"
    static let interruptionCountsLabel = "audioSessionOwnership.interruptions"
    static let runButton = "audioSessionOwnership.run"
    static let continueFocusProbeButton = "audioSessionOwnership.continueFocusProbe"
    static let resultLabel = "audioSessionOwnership.result"
    static let errorLabel = "audioSessionOwnership.error"
  }

  enum PiPNativeLifecycleValidation {
    static let videoView = "pipNativeLifecycle.videoView"
    static let stateLabel = "pipNativeLifecycle.state"
    static let possibleLabel = "pipNativeLifecycle.possible"
    static let activeLabel = "pipNativeLifecycle.active"
    static let lifecycleEventsLabel = "pipNativeLifecycle.lifecycleEvents"
    static let resultLabel = "pipNativeLifecycle.result"
    static let runButton = "pipNativeLifecycle.run"
    static let errorLabel = "pipNativeLifecycle.error"
  }

  enum NativeRendererRecoveryValidation {
    static let videoView = "nativeRendererRecovery.videoView"
    static let stateLabel = "nativeRendererRecovery.state"
    static let possibleLabel = "nativeRendererRecovery.possible"
    static let activeLabel = "nativeRendererRecovery.active"
    static let phaseLabel = "nativeRendererRecovery.phase"
    static let resultLabel = "nativeRendererRecovery.result"
    static let prepareButton = "nativeRendererRecovery.prepare"
    static let armButton = "nativeRendererRecovery.arm"
    static let evaluateButton = "nativeRendererRecovery.evaluate"
    static let resumeButton = "nativeRendererRecovery.resume"
    static let errorLabel = "nativeRendererRecovery.error"
  }

  enum TerminalOutcomesValidation {
    static let videoView = "terminalOutcomes.videoView"
    static let stateLabel = "terminalOutcomes.state"
    static let actionLabel = "terminalOutcomes.action"
    static let resultLabel = "terminalOutcomes.result"
    static let runButton = "terminalOutcomes.run"
    static let errorLabel = "terminalOutcomes.error"
  }

  enum AdaptiveHLSSoakValidation {
    static let videoView = "adaptiveHLSSoak.videoView"
    static let stateLabel = "adaptiveHLSSoak.state"
    static let progressLabel = "adaptiveHLSSoak.progress"
    static let phaseLabel = "adaptiveHLSSoak.phase"
    static let resultLabel = "adaptiveHLSSoak.result"
    static let runButton = "adaptiveHLSSoak.run"
    static let errorLabel = "adaptiveHLSSoak.error"
  }

  enum PiPRenderPerformanceValidation {
    static let videoView = "pipRenderPerformance.videoView"
    static let stateLabel = "pipRenderPerformance.state"
    static let possibleLabel = "pipRenderPerformance.possible"
    static let activeLabel = "pipRenderPerformance.active"
    static let progressLabel = "pipRenderPerformance.progress"
    static let targetLabel = "pipRenderPerformance.target"
    static let resultLabel = "pipRenderPerformance.result"
    static let runButton = "pipRenderPerformance.run"
    static let errorLabel = "pipRenderPerformance.error"
  }

  enum PiPCadenceValidation {
    static let videoView = "pipCadence.videoView"
    static let stateLabel = "pipCadence.state"
    static let possibleLabel = "pipCadence.possible"
    static let activeLabel = "pipCadence.active"
    static let progressLabel = "pipCadence.progress"
    static let profileLabel = "pipCadence.profile"
    static let resultLabel = "pipCadence.result"
    static let runButton = "pipCadence.run"
    static let errorLabel = "pipCadence.error"
  }

  /// Opt-in, report-only physical probe. Its identifiers are deliberately
  /// separate from candidate-bound cadence qualification so its output cannot
  /// be mistaken for release credit.
  enum PiPCadenceSemanticsProbe {
    static let videoView = "pipCadenceProbe.videoView"
    static let stateLabel = "pipCadenceProbe.state"
    static let possibleLabel = "pipCadenceProbe.possible"
    static let activeLabel = "pipCadenceProbe.active"
    static let progressLabel = "pipCadenceProbe.progress"
    static let profileLabel = "pipCadenceProbe.profile"
    static let resultLabel = "pipCadenceProbe.result"
    static let runButton = "pipCadenceProbe.run"
    static let errorLabel = "pipCadenceProbe.error"
  }

  enum NativeSubtitleMatrixValidation {
    static let videoView = "nativeSubtitleMatrix.videoView"
    static let stateLabel = "nativeSubtitleMatrix.state"
    static let possibleLabel = "nativeSubtitleMatrix.possible"
    static let activeLabel = "nativeSubtitleMatrix.active"
    static let progressLabel = "nativeSubtitleMatrix.progress"
    static let profileLabel = "nativeSubtitleMatrix.profile"
    static let resultLabel = "nativeSubtitleMatrix.result"
    static let runButton = "nativeSubtitleMatrix.run"
    static let errorLabel = "nativeSubtitleMatrix.error"
  }

  enum TimebaseSoakValidation {
    static let videoView = "timebaseSoak.videoView"
    static let possibleLabel = "timebaseSoak.possible"
    static let activeLabel = "timebaseSoak.active"
    static let phaseLabel = "timebaseSoak.phase"
    static let progressLabel = "timebaseSoak.progress"
    static let interruptionLabel = "timebaseSoak.interruptions"
    static let resultLabel = "timebaseSoak.result"
    static let runButton = "timebaseSoak.run"
    static let errorLabel = "timebaseSoak.error"
  }

  enum MatrixHValidation {
    static let stateLabel = "validation.matrixH.state"
    static let currentTimeLabel = "validation.matrixH.currentTime"
    static let displayedPicturesLabel = "validation.matrixH.displayedPictures"
    static let activeLabel = "validation.matrixH.active"
    static let unexpectedStopCountLabel = "validation.matrixH.unexpectedStops"
    static let forwardResultLabel = "validation.matrixH.forwardResult"
    static let backwardResultLabel = "validation.matrixH.backwardResult"
    static let absoluteResultLabel = "validation.matrixH.absoluteResult"
    static let seekBackwardButton = "validation.matrixH.seekBackward"
    static let seekForwardButton = "validation.matrixH.seekForward"
    static let seekAbsoluteButton = "validation.matrixH.seekAbsolute"
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
    static let fontSizeSlider = "marquee.fontSizeSlider"
    static let xSlider = "marquee.xSlider"
    static let ySlider = "marquee.ySlider"
    static let timeoutSlider = "marquee.timeoutSlider"
    static let colorPicker = "marquee.colorPicker"
    static let anchorPicker = "marquee.anchorPicker"
    static let resetButton = "marquee.resetButton"
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

  enum Chapters {
    static let videoView = "chapters.videoView"
    static let playPauseButton = "chapters.playPause"
    static let emptyLabel = "chapters.empty"
    static let picker = "chapters.picker"
    static let previousButton = "chapters.previous"
    static let nextButton = "chapters.next"
  }

  enum SubtitlesDelay {
    static let videoView = "subdelay.videoView"
    static let playPauseButton = "subdelay.playPause"
    static let slider = "subdelay.slider"
  }

  enum SubtitlesScale {
    static let videoView = "subscale.videoView"
    static let playPauseButton = "subscale.playPause"
    static let slider = "subscale.slider"
  }

  enum StreamingHLS {
    static let videoView = "hls.videoView"
    static let playPauseButton = "hls.playPause"
  }

  enum PlaylistQueue {
    static let videoView = "queue.videoView"
    static let playPauseButton = "queue.playPause"
    static let modePicker = "queue.modePicker"
    static let previousButton = "queue.previous"
    static let nextButton = "queue.next"
  }

  enum DiscoveryLAN {
    static let emptyServices = "lan.emptyServices"
    static let servicePicker = "lan.servicePicker"
    static let emptyDiscovered = "lan.emptyDiscovered"
  }

  enum DiscoveryRenderers {
    static let emptyServices = "rend.emptyServices"
    static let servicePicker = "rend.servicePicker"
  }

  enum Metadata {
    static let videoView = "meta.videoView"
    static let playPauseButton = "meta.playPause"
  }

  enum Events {
    static let videoView = "events.videoView"
    static let playPauseButton = "events.playPause"
  }

  enum Statistics {
    static let videoView = "stats.videoView"
    static let playPauseButton = "stats.playPause"
    static let waitingLabel = "stats.waiting"
    static let readBytes = "stats.readBytes"
    static let inputBitrate = "stats.inputBitrate"
    static let demuxReadBytes = "stats.demuxReadBytes"
    static let demuxBitrate = "stats.demuxBitrate"
    static let demuxCorrupted = "stats.demuxCorrupted"
    static let demuxDiscontinuity = "stats.demuxDiscontinuity"
    static let decodedVideo = "stats.decodedVideo"
    static let displayedPictures = "stats.displayedPictures"
    static let latePictures = "stats.latePictures"
    static let lostPictures = "stats.lostPictures"
    static let decodedAudio = "stats.decodedAudio"
    static let playedAudioBuffers = "stats.playedAudioBuffers"
    static let lostAudioBuffers = "stats.lostAudioBuffers"
  }

  enum Logs {
    static let videoView = "logs.videoView"
    static let playPauseButton = "logs.playPause"
    static let levelPicker = "logs.levelPicker"
  }

  enum RoleAndCork {
    static let videoView = "rolecork.videoView"
    static let playPauseButton = "rolecork.playPause"
    static let rolePicker = "rolecork.rolePicker"
    static let statusLabel = "rolecork.status"
    static let corkedCountLabel = "rolecork.corkedCount"
    static let uncorkedCountLabel = "rolecork.uncorkedCount"
  }

  enum MultiTrackSelection {
    static let videoView = "multitrack.videoView"
    static let playPauseButton = "multitrack.playPause"
    static let audioTracksLoadingLabel = "multitrack.audioLoading"
    static let subtitleTracksEmptyLabel = "multitrack.subtitleEmpty"
    static let videoTracksLoadingLabel = "multitrack.videoLoading"
    static let programsEmptyLabel = "multitrack.programsEmpty"
    static let audioTrackPicker = "multitrack.audioPicker"
    static let subtitleTrackPicker = "multitrack.subtitlePicker"
  }

  enum MultiConsumer {
    static let videoView = "multiconsumer.videoView"
    static let playPauseButton = "multiconsumer.playPause"
    static let lifecycleWaitingLabel = "multiconsumer.lifecycleWaiting"
    static let trackWaitingLabel = "multiconsumer.trackWaiting"
    static let lifecycleLogEntry = "multiconsumer.lifecycleEntry"
    static let trackLogEntry = "multiconsumer.trackEntry"
  }
}
