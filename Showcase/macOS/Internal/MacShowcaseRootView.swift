import SwiftUI

struct MacShowcaseRootView: View {
  @State private var selection: MacShowcase?

  init() {
    _selection = State(initialValue: MacShowcase.initialSelection)
  }

  var body: some View {
    NavigationSplitView {
      List(selection: $selection) {
        ForEach(MacShowcaseSection.allCases) { section in
          Section(section.title) {
            ForEach(section.showcases) { showcase in
              Label(showcase.title, systemImage: showcase.systemImage)
                .tag(showcase)
            }
          }
        }
      }
      .navigationTitle("SwiftVLC")
      .listStyle(.sidebar)
    } detail: {
      MacShowcaseDetail(showcase: selection ?? .simplePlayback)
        .navigationTitle((selection ?? .simplePlayback).title)
    }
  }
}

private struct MacShowcaseDetail: View {
  let showcase: MacShowcase

  var body: some View {
    switch showcase {
    case .videoPlayer:
      MacVideoPlayerApp()
    case .musicPlayer:
      MacMusicPlayerApp()
    case .simplePlayback:
      MacSimplePlaybackCase()
    case .playerState:
      MacPlayerStateCase()
    case .lifecycle:
      MacLifecycleCase()
    case .seeking:
      MacSeekingCase()
    case .relativeSeek:
      MacRelativeSeekCase()
    case .rate:
      MacRateCase()
    case .frameStep:
      MacFrameStepCase()
    case .thumbnailScrub:
      MacThumbnailScrubCase()
    case .volume:
      MacVolumeCase()
    case .audioTracks:
      MacAudioTracksCase()
    case .audioChannels:
      MacAudioChannelsCase()
    case .audioOutputs:
      MacAudioOutputsCase()
    case .audioDelay:
      MacAudioDelayCase()
    case .equalizer:
      MacEqualizerCase()
    case .roleAndCork:
      MacRoleAndCorkCase()
    case .aspectRatio:
      MacAspectRatioCase()
    case .videoAdjustments:
      MacVideoAdjustmentsCase()
    case .snapshot:
      MacSnapshotCase()
    case .viewpoint:
      MacViewpointCase()
    case .marquee:
      MacMarqueeCase()
    case .deinterlacing:
      MacDeinterlacingCase()
    case .subtitlesSelection:
      MacSubtitlesSelectionCase()
    case .subtitlesExternal:
      MacSubtitlesExternalCase()
    case .subtitlesDelay:
      MacSubtitlesDelayCase()
    case .subtitlesScale:
      MacSubtitlesScaleCase()
    case .abLoop:
      MacABLoopCase()
    case .chapters:
      MacChaptersCase()
    case .recording:
      MacRecordingCase()
    case .pip:
      MacPiPCase()
    case .streamingHLS:
      MacStreamingHLSCase()
    case .multiTrackSelection:
      MacMultiTrackSelectionCase()
    case .playlistQueue:
      MacPlaylistQueueCase()
    case .discoveryLAN:
      MacDiscoveryLANCase()
    case .discoveryRenderers:
      MacDiscoveryRenderersCase()
    case .metadata:
      MacMetadataCase()
    case .thumbnails:
      MacThumbnailsCase()
    case .events:
      MacEventsCase()
    case .multiConsumerEvents:
      MacMultiConsumerEventsCase()
    case .statistics:
      MacStatisticsCase()
    case .logs:
      MacLogsCase()
    }
  }
}

enum MacShowcaseSection: String, CaseIterable, Identifiable {
  case apps
  case foundation
  case transport
  case audio
  case video
  case subtitles
  case advanced
  case playlist
  case discovery
  case media
  case diagnostics

  var id: Self {
    self
  }

  var title: String {
    switch self {
    case .apps: "Apps"
    case .foundation: "Foundation"
    case .transport: "Transport"
    case .audio: "Audio"
    case .video: "Video"
    case .subtitles: "Subtitles"
    case .advanced: "Advanced"
    case .playlist: "Playlist"
    case .discovery: "Discovery"
    case .media: "Media"
    case .diagnostics: "Diagnostics"
    }
  }

  var showcases: [MacShowcase] {
    switch self {
    case .apps:
      [.videoPlayer, .musicPlayer]
    case .foundation:
      [.simplePlayback, .playerState, .lifecycle]
    case .transport:
      [.seeking, .relativeSeek, .rate, .frameStep, .thumbnailScrub]
    case .audio:
      [.volume, .audioTracks, .audioChannels, .audioOutputs, .audioDelay, .equalizer, .roleAndCork]
    case .video:
      [.aspectRatio, .videoAdjustments, .snapshot, .viewpoint, .marquee, .deinterlacing]
    case .subtitles:
      [.subtitlesSelection, .subtitlesExternal, .subtitlesDelay, .subtitlesScale]
    case .advanced:
      [.abLoop, .chapters, .recording, .pip, .streamingHLS, .multiTrackSelection]
    case .playlist:
      [.playlistQueue]
    case .discovery:
      [.discoveryLAN, .discoveryRenderers]
    case .media:
      [.metadata, .thumbnails]
    case .diagnostics:
      [.events, .multiConsumerEvents, .statistics, .logs]
    }
  }
}

enum MacShowcase: String, Identifiable {
  case videoPlayer
  case musicPlayer
  case simplePlayback
  case playerState
  case lifecycle
  case seeking
  case relativeSeek
  case rate
  case frameStep
  case thumbnailScrub
  case volume
  case audioTracks
  case audioChannels
  case audioOutputs
  case audioDelay
  case equalizer
  case roleAndCork
  case aspectRatio
  case videoAdjustments
  case snapshot
  case viewpoint
  case marquee
  case deinterlacing
  case subtitlesSelection
  case subtitlesExternal
  case subtitlesDelay
  case subtitlesScale
  case abLoop
  case chapters
  case recording
  case pip
  case streamingHLS
  case multiTrackSelection
  case playlistQueue
  case discoveryLAN
  case discoveryRenderers
  case metadata
  case thumbnails
  case events
  case multiConsumerEvents
  case statistics
  case logs

  var id: Self {
    self
  }

  static var initialSelection: Self {
    UITestRoute.current.flatMap(Self.init(route:)) ?? .simplePlayback
  }

  var title: String {
    switch self {
    case .videoPlayer: "Video Player"
    case .musicPlayer: "Music Player"
    case .simplePlayback: "Simple Playback"
    case .playerState: "Player State"
    case .lifecycle: "Lifecycle"
    case .seeking: "Seeking"
    case .relativeSeek: "Relative Seek"
    case .rate: "Playback Rate"
    case .frameStep: "Frame Step"
    case .thumbnailScrub: "Thumbnail Scrubbing"
    case .volume: "Volume"
    case .audioTracks: "Audio Tracks"
    case .audioChannels: "Audio Channels"
    case .audioOutputs: "Audio Outputs"
    case .audioDelay: "Audio Delay"
    case .equalizer: "Equalizer"
    case .roleAndCork: "Role & Corking"
    case .aspectRatio: "Aspect Ratio"
    case .videoAdjustments: "Adjustments"
    case .snapshot: "Snapshot"
    case .viewpoint: "360 Viewpoint"
    case .marquee: "Marquee"
    case .deinterlacing: "Deinterlacing"
    case .subtitlesSelection: "Selection"
    case .subtitlesExternal: "External File"
    case .subtitlesDelay: "Subtitle Delay"
    case .subtitlesScale: "Subtitle Scale"
    case .abLoop: "A-B Loop"
    case .chapters: "Chapters"
    case .recording: "Recording"
    case .pip: "Picture in Picture"
    case .streamingHLS: "HLS Streaming"
    case .multiTrackSelection: "Track Selection"
    case .playlistQueue: "Queue"
    case .discoveryLAN: "LAN"
    case .discoveryRenderers: "Renderers"
    case .metadata: "Metadata"
    case .thumbnails: "Thumbnails"
    case .events: "Events"
    case .multiConsumerEvents: "Multi-consumer Events"
    case .statistics: "Statistics"
    case .logs: "Logs"
    }
  }

  var systemImage: String {
    switch self {
    case .videoPlayer: "play.display"
    case .musicPlayer: "music.note.list"
    case .simplePlayback: "play.rectangle"
    case .playerState: "waveform.path.ecg"
    case .lifecycle: "arrow.clockwise.circle"
    case .seeking: "slider.horizontal.3"
    case .relativeSeek: "goforward"
    case .rate: "speedometer"
    case .frameStep: "forward.frame"
    case .thumbnailScrub: "film.stack"
    case .volume: "speaker.wave.2"
    case .audioTracks: "waveform"
    case .audioChannels: "hifispeaker.2"
    case .audioOutputs: "airplayaudio"
    case .audioDelay: "metronome"
    case .equalizer: "slider.vertical.3"
    case .roleAndCork: "speaker.badge.exclamationmark"
    case .aspectRatio: "aspectratio"
    case .videoAdjustments: "dial.high"
    case .snapshot: "camera"
    case .viewpoint: "viewfinder"
    case .marquee: "text.bubble"
    case .deinterlacing: "line.3.horizontal.decrease"
    case .subtitlesSelection: "captions.bubble"
    case .subtitlesExternal: "doc.badge.plus"
    case .subtitlesDelay: "captions.bubble.fill"
    case .subtitlesScale: "textformat.size"
    case .abLoop: "repeat"
    case .chapters: "list.number"
    case .recording: "record.circle"
    case .pip: "pip"
    case .streamingHLS: "antenna.radiowaves.left.and.right"
    case .multiTrackSelection: "rectangle.stack"
    case .playlistQueue: "list.bullet.rectangle"
    case .discoveryLAN: "network"
    case .discoveryRenderers: "airplayvideo"
    case .metadata: "tag"
    case .thumbnails: "photo.on.rectangle"
    case .events: "dot.radiowaves.left.and.right"
    case .multiConsumerEvents: "arrow.triangle.branch"
    case .statistics: "chart.bar"
    case .logs: "list.clipboard"
    }
  }
}

extension MacShowcase {
  init?(route: UITestRoute) {
    switch route {
    case .videoPlayer: self = .videoPlayer
    case .musicPlayer: self = .musicPlayer
    case .simplePlayback: self = .simplePlayback
    case .playerState: self = .playerState
    case .lifecycle: self = .lifecycle
    case .seeking: self = .seeking
    case .relativeSeek: self = .relativeSeek
    case .rate: self = .rate
    case .frameStep: self = .frameStep
    case .thumbnailScrub: self = .thumbnailScrub
    case .volume: self = .volume
    case .audioTracks: self = .audioTracks
    case .audioChannels: self = .audioChannels
    case .audioOutputs: self = .audioOutputs
    case .audioDelay: self = .audioDelay
    case .equalizer: self = .equalizer
    case .roleAndCork: self = .roleAndCork
    case .aspectRatio: self = .aspectRatio
    case .adjustments: self = .videoAdjustments
    case .snapshot: self = .snapshot
    case .viewpoint: self = .viewpoint
    case .marquee: self = .marquee
    case .deinterlacing: self = .deinterlacing
    case .subtitlesSelection: self = .subtitlesSelection
    case .subtitlesExternal: self = .subtitlesExternal
    case .subtitlesDelay: self = .subtitlesDelay
    case .subtitlesScale: self = .subtitlesScale
    case .abLoop: self = .abLoop
    case .chapters: self = .chapters
    case .recording: self = .recording
    case .pip: self = .pip
    case .streamingHLS: self = .streamingHLS
    case .multiTrackSelection: self = .multiTrackSelection
    case .playlistQueue: self = .playlistQueue
    case .discoveryLAN: self = .discoveryLAN
    case .discoveryRenderers: self = .discoveryRenderers
    case .metadata: self = .metadata
    case .thumbnails: self = .thumbnails
    case .events: self = .events
    case .multiConsumer: self = .multiConsumerEvents
    case .statistics: self = .statistics
    case .logs: self = .logs
    }
  }
}
