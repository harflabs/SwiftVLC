import SwiftUI

struct TVShowcaseRootView: View {
  private let cardColumns = Array(
    repeating: GridItem(.fixed(390), spacing: 36),
    count: 4
  )

  var body: some View {
    NavigationStack {
      if let route = UITestRoute.current.flatMap(TVShowcase.init(route:)) {
        TVShowcaseDetail(showcase: route)
          .navigationTitle(route.title)
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: 38) {
            hero

            ForEach(TVShowcaseSection.allCases) { section in
              VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 4) {
                  Text(section.title)
                    .font(.system(size: 42, weight: .bold, design: .rounded))
                  Text(section.subtitle)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }

                LazyVGrid(columns: cardColumns, alignment: .leading, spacing: 36) {
                  ForEach(section.showcases) { showcase in
                    NavigationLink {
                      TVShowcaseDetail(showcase: showcase)
                        .navigationTitle(showcase.title)
                    } label: {
                      TVShowcaseCard(showcase: showcase)
                    }
                    .buttonStyle(.card)
                  }
                }
                .focusSection()
              }
            }
          }
          .frame(maxWidth: 1760, alignment: .leading)
        }
        .safeAreaPadding(.horizontal, 80)
        .safeAreaPadding(.vertical, 48)
        .background(Color.black)
        .toolbar(.hidden, for: .navigationBar)
      }
    }
  }

  private var hero: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("SwiftVLC")
        .font(.system(size: 46, weight: .bold, design: .rounded))
      Text("Remote-first playback controls and SwiftVLC APIs for the big screen.")
        .font(.system(size: 26, weight: .medium))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 980, alignment: .leading)
    }
  }
}

struct TVShowcaseDetail: View {
  let showcase: TVShowcase

  var body: some View {
    switch showcase {
    case .videoPlayer:
      TVVideoPlayerApp()
    case .musicPlayer:
      TVMusicPlayerApp()
    case .simplePlayback:
      TVSimplePlaybackCase()
    case .playerState:
      TVPlayerStateCase()
    case .lifecycle:
      TVLifecycleCase()
    case .seeking:
      TVSeekingCase()
    case .relativeSeek:
      TVRelativeSeekCase()
    case .rate:
      TVRateCase()
    case .frameStep:
      TVFrameStepCase()
    case .thumbnailScrub:
      TVThumbnailScrubCase()
    case .volume:
      TVVolumeCase()
    case .audioTracks:
      TVAudioTracksCase()
    case .audioChannels:
      TVAudioChannelsCase()
    case .audioDelay:
      TVAudioDelayCase()
    case .equalizer:
      TVEqualizerCase()
    case .aspectRatio:
      TVAspectRatioCase()
    case .videoAdjustments:
      TVVideoAdjustmentsCase()
    case .viewpoint:
      TVViewpointCase()
    case .marquee:
      TVMarqueeCase()
    case .deinterlacing:
      TVDeinterlacingCase()
    case .subtitlesSelection:
      TVSubtitlesSelectionCase()
    case .subtitlesExternal:
      TVSubtitlesExternalCase()
    case .subtitlesDelay:
      TVSubtitlesDelayCase()
    case .subtitlesScale:
      TVSubtitlesScaleCase()
    case .abLoop:
      TVABLoopCase()
    case .chapters:
      TVChaptersCase()
    case .streamingHLS:
      TVStreamingHLSCase()
    case .multiTrackSelection:
      TVMultiTrackSelectionCase()
    case .playlistQueue:
      TVPlaylistQueueCase()
    case .discoveryLAN:
      TVDiscoveryLANCase()
    case .metadata:
      TVMetadataCase()
    case .thumbnails:
      TVThumbnailsCase()
    case .events:
      TVEventsCase()
    case .statistics:
      TVStatisticsCase()
    case .logs:
      TVLogsCase()
    }
  }
}

enum TVShowcaseSection: String, CaseIterable, Identifiable {
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

  var subtitle: String {
    switch self {
    case .apps:
      "End-to-end players built for the remote."
    case .foundation:
      "Playback, state, and lifecycle basics."
    case .transport:
      "Seeking and timing patterns for the Siri Remote."
    case .audio:
      "Track, volume, and processing controls."
    case .video:
      "Legible video presentation controls."
    case .subtitles:
      "Caption selection, timing, and scale."
    case .advanced:
      "Specialized playback workflows for TV."
    case .playlist:
      "Queue playback with MediaListPlayer."
    case .discovery:
      "Local network media discovery."
    case .media:
      "Metadata and thumbnail APIs."
    case .diagnostics:
      "Events, statistics, and logs."
    }
  }

  var showcases: [TVShowcase] {
    switch self {
    case .apps:
      [.videoPlayer, .musicPlayer]
    case .foundation:
      [.simplePlayback, .playerState, .lifecycle]
    case .transport:
      [.seeking, .relativeSeek, .rate, .frameStep, .thumbnailScrub]
    case .audio:
      [.volume, .audioTracks, .audioChannels, .audioDelay, .equalizer]
    case .video:
      [.aspectRatio, .videoAdjustments, .viewpoint, .marquee, .deinterlacing]
    case .subtitles:
      [.subtitlesSelection, .subtitlesExternal, .subtitlesDelay, .subtitlesScale]
    case .advanced:
      [.abLoop, .chapters, .streamingHLS, .multiTrackSelection]
    case .playlist:
      [.playlistQueue]
    case .discovery:
      [.discoveryLAN]
    case .media:
      [.metadata, .thumbnails]
    case .diagnostics:
      [.events, .statistics, .logs]
    }
  }
}

enum TVShowcase: String, Identifiable {
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
  case audioDelay
  case equalizer
  case aspectRatio
  case videoAdjustments
  case viewpoint
  case marquee
  case deinterlacing
  case subtitlesSelection
  case subtitlesExternal
  case subtitlesDelay
  case subtitlesScale
  case abLoop
  case chapters
  case streamingHLS
  case multiTrackSelection
  case playlistQueue
  case discoveryLAN
  case metadata
  case thumbnails
  case events
  case statistics
  case logs

  var id: Self {
    self
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
    case .audioDelay: "Audio Delay"
    case .equalizer: "Equalizer"
    case .aspectRatio: "Aspect Ratio"
    case .videoAdjustments: "Adjustments"
    case .viewpoint: "360 Viewpoint"
    case .marquee: "Marquee"
    case .deinterlacing: "Deinterlacing"
    case .subtitlesSelection: "Selection"
    case .subtitlesExternal: "External File"
    case .subtitlesDelay: "Subtitle Delay"
    case .subtitlesScale: "Subtitle Scale"
    case .abLoop: "A-B Loop"
    case .chapters: "Chapters"
    case .streamingHLS: "HLS Streaming"
    case .multiTrackSelection: "Track Selection"
    case .playlistQueue: "Queue"
    case .discoveryLAN: "LAN"
    case .metadata: "Metadata"
    case .thumbnails: "Thumbnails"
    case .events: "Events"
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
    case .audioDelay: "metronome"
    case .equalizer: "slider.vertical.3"
    case .aspectRatio: "aspectratio"
    case .videoAdjustments: "dial.high"
    case .viewpoint: "viewfinder"
    case .marquee: "text.bubble"
    case .deinterlacing: "line.3.horizontal.decrease"
    case .subtitlesSelection: "captions.bubble"
    case .subtitlesExternal: "doc.badge.plus"
    case .subtitlesDelay: "captions.bubble.fill"
    case .subtitlesScale: "textformat.size"
    case .abLoop: "repeat"
    case .chapters: "list.number"
    case .streamingHLS: "antenna.radiowaves.left.and.right"
    case .multiTrackSelection: "rectangle.stack"
    case .playlistQueue: "list.bullet.rectangle"
    case .discoveryLAN: "network"
    case .metadata: "tag"
    case .thumbnails: "photo.on.rectangle"
    case .events: "dot.radiowaves.left.and.right"
    case .statistics: "chart.bar"
    case .logs: "list.clipboard"
    }
  }

  var blurb: String {
    switch self {
    case .videoPlayer:
      "Source picking, tracks, and transport."
    case .musicPlayer:
      "Audio playback and metadata."
    case .simplePlayback:
      "Player plus VideoView."
    case .playerState:
      "Live playback state."
    case .lifecycle:
      "Load, replace, and stop."
    case .seeking:
      "Remote-friendly scrubbing."
    case .relativeSeek:
      "Skip by fixed durations."
    case .rate:
      "Tune playback speed."
    case .frameStep:
      "Step paused video one frame at a time."
    case .thumbnailScrub:
      "Preview tiles while scrubbing."
    case .volume:
      "Volume and mute bindings."
    case .audioTracks:
      "Select embedded audio."
    case .audioChannels:
      "Stereo and mix modes."
    case .audioDelay:
      "Shift audio timing."
    case .equalizer:
      "Presets and live bands."
    case .aspectRatio:
      "Fit, fill, and ratios."
    case .videoAdjustments:
      "Brightness and color tuning."
    case .viewpoint:
      "Yaw, pitch, and field of view."
    case .marquee:
      "Render libVLC marquee text over video."
    case .deinterlacing:
      "Switch deinterlace modes."
    case .subtitlesSelection:
      "Select embedded subtitle tracks."
    case .subtitlesExternal:
      "Attach a bundled sidecar subtitle file on tvOS."
    case .subtitlesDelay:
      "Shift caption timing."
    case .subtitlesScale:
      "Scale captions for TV."
    case .abLoop:
      "Loop between two marks."
    case .chapters:
      "Jump between chapters."
    case .streamingHLS:
      "Adaptive HLS playback."
    case .multiTrackSelection:
      "Audio and subtitle pairing."
    case .playlistQueue:
      "Remote-friendly queue."
    case .discoveryLAN:
      "Find LAN media services."
    case .metadata:
      "Parse media fields."
    case .thumbnails:
      "Generate preview frames."
    case .events:
      "Live Player.events log."
    case .statistics:
      "Playback counters."
    case .logs:
      "Filter VLC log output."
    }
  }
}

private struct TVShowcaseCard: View {
  let showcase: TVShowcase

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Image(systemName: showcase.systemImage)
        .font(.system(size: 36, weight: .semibold))
        .foregroundStyle(.orange)
        .frame(width: 48, height: 48, alignment: .leading)

      VStack(alignment: .leading, spacing: 8) {
        Text(showcase.title)
          .font(.system(size: 32, weight: .semibold, design: .rounded))
          .foregroundStyle(.primary)
          .fixedSize(horizontal: false, vertical: true)

        Text(showcase.blurb)
          .font(.system(size: 23, weight: .medium))
          .foregroundStyle(.secondary)
          .lineSpacing(2)
          .multilineTextAlignment(.leading)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(24)
    .frame(width: 390, height: 210, alignment: .topLeading)
    .background(.regularMaterial, in: .rect(cornerRadius: 24, style: .continuous))
    .contentShape(.rect(cornerRadius: 24, style: .continuous))
  }
}

extension TVShowcase {
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
    case .audioDelay: self = .audioDelay
    case .equalizer: self = .equalizer
    case .aspectRatio: self = .aspectRatio
    case .adjustments: self = .videoAdjustments
    case .viewpoint: self = .viewpoint
    case .marquee: self = .marquee
    case .deinterlacing: self = .deinterlacing
    case .subtitlesSelection: self = .subtitlesSelection
    case .subtitlesExternal: self = .subtitlesExternal
    case .subtitlesDelay: self = .subtitlesDelay
    case .subtitlesScale: self = .subtitlesScale
    case .abLoop: self = .abLoop
    case .chapters: self = .chapters
    case .streamingHLS: self = .streamingHLS
    case .multiTrackSelection: self = .multiTrackSelection
    case .playlistQueue: self = .playlistQueue
    case .discoveryLAN: self = .discoveryLAN
    case .metadata: self = .metadata
    case .thumbnails: self = .thumbnails
    case .events: self = .events
    case .statistics: self = .statistics
    case .logs: self = .logs
    case .audioOutputs,
         .roleAndCork,
         .snapshot,
         .recording,
         .pip,
         .discoveryRenderers,
         .multiConsumer:
      return nil
    }
  }
}
