import SwiftUI

struct RootView: View {
  var body: some View {
    NavigationStack {
      if let route = UITestRoute.current {
        route.view
      } else {
        rootForm
      }
    }
    .accessibilityIdentifier(AccessibilityID.Root.navigationStack)
  }

  private var rootForm: some View {
    Form {
      Section("Apps") {
        NavigationLink("Video Player") { VideoPlayerApp() }
        NavigationLink("Music Player") { MusicPlayerApp() }
      }

      Section("Foundation") {
        NavigationLink("Simple playback") { SimplePlaybackCase() }
        NavigationLink("Player state") { PlayerStateCase() }
        NavigationLink("Lifecycle") { LifecycleCase() }
      }

      Section("Transport") {
        NavigationLink("Seeking") { SeekingCase() }
        NavigationLink("Relative seek") { RelativeSeekCase() }
        NavigationLink("Playback rate") { RateCase() }
        NavigationLink("Frame step") { FrameStepCase() }
        NavigationLink("Thumbnail scrubbing") { ThumbnailScrubCase() }
      }

      Section("Audio") {
        NavigationLink("Volume") { VolumeCase() }
        NavigationLink("Tracks") { AudioTracksCase() }
        NavigationLink("Channels") { AudioChannelsCase() }
        NavigationLink("Outputs") { AudioOutputsCase() }
        NavigationLink("Delay") { AudioDelayCase() }
        NavigationLink("Equalizer") { EqualizerCase() }
        NavigationLink("Role & corking") { RoleAndCorkCase() }
      }

      Section("Video") {
        NavigationLink("Aspect ratio") { AspectRatioCase() }
        NavigationLink("Adjustments") { VideoAdjustmentsCase() }
        NavigationLink("Snapshot") { SnapshotCase() }
        NavigationLink("360° viewpoint") { ViewpointCase() }
        NavigationLink("Marquee") { MarqueeCase() }
        NavigationLink("Deinterlacing") { DeinterlacingCase() }
      }

      Section("Subtitles") {
        NavigationLink("Selection") { SubtitlesSelectionCase() }
        NavigationLink("External file") { SubtitlesExternalCase() }
        NavigationLink("Delay") { SubtitlesDelayCase() }
        NavigationLink("Scale") { SubtitlesScaleCase() }
      }

      Section("Advanced") {
        NavigationLink("A-B loop") { ABLoopCase() }
        NavigationLink("Chapters") { ChaptersCase() }
        NavigationLink("Recording") { RecordingCase() }
        NavigationLink("Picture in Picture") { PiPCase() }
        NavigationLink("HLS streaming") { StreamingHLSCase() }
        NavigationLink("Multi-track selection") { MultiTrackSelectionCase() }
      }

      Section("Playlist") {
        NavigationLink("Queue") { PlaylistQueueCase() }
      }

      Section("Discovery") {
        NavigationLink("LAN") { DiscoveryLANCase() }
        NavigationLink("Renderers") { DiscoveryRenderersCase() }
      }

      Section("Media") {
        NavigationLink("Metadata") { MetadataCase() }
        NavigationLink("Thumbnails") { ThumbnailsCase() }
      }

      Section("Diagnostics") {
        NavigationLink("Events") { EventsCase() }
        NavigationLink("Multi-consumer events") { MultiConsumerEventsCase() }
        NavigationLink("Statistics") { StatisticsCase() }
        NavigationLink("Logs") { LogsCase() }
      }
    }
    .showcaseFormStyle()
    .navigationTitle("SwiftVLC")
  }
}
