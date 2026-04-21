import Foundation
import SwiftUI
import SwiftVLC

/// Test-mode infrastructure for the showcase app. Every entry point is
/// gated on `LaunchArguments.isUITestMode`; in normal use, none of this code
/// runs.
enum UITestSupport {
  /// Subscribes to `VLCInstance.shared.logStream` and writes one JSONL record
  /// per entry to the file at `-UITestLogPath`. Idempotent — safe to call
  /// once from `ShowcaseApp.init`.
  ///
  /// `fsync` after every write so the test process can read entries even if
  /// the app is forcibly terminated mid-scenario.
  static func startLogMirrorIfRequested() {
    guard
      LaunchArguments.isUITestMode,
      let path = LaunchArguments.logPathValue
    else { return }

    let url = URL(fileURLWithPath: path)
    FileManager.default.createFile(atPath: path, contents: nil)

    Task.detached(priority: .utility) {
      guard let handle = try? FileHandle(forWritingTo: url) else { return }
      defer { try? handle.close() }

      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601

      for await entry in VLCInstance.shared.logStream(minimumLevel: .debug) {
        let record = LogRecord(
          ts: Date(),
          level: entry.level.description,
          module: entry.module,
          message: entry.message
        )
        guard let data = try? encoder.encode(record) else { continue }
        try? handle.write(contentsOf: data)
        try? handle.write(contentsOf: Data([0x0A]))
        try? handle.synchronize()
      }
    }
  }

  private struct LogRecord: Codable {
    let ts: Date
    let level: String
    let module: String?
    let message: String
  }
}

@MainActor
extension UITestRoute {
  /// The case-study view this route resolves to. Add a case here as each
  /// showcase grows UI tests.
  @ViewBuilder
  var view: some View {
    switch self {
    case .simplePlayback: SimplePlaybackCase()
    case .playerState: PlayerStateCase()
    case .seeking: SeekingCase()
    case .volume: VolumeCase()
    case .abLoop: ABLoopCase()
    case .relativeSeek: RelativeSeekCase()
    case .frameStep: FrameStepCase()
    case .rate: RateCase()
    case .thumbnails: ThumbnailsCase()
    case .audioTracks: AudioTracksCase()
    case .snapshot: SnapshotCase()
    #if os(iOS) || os(macOS)
    case .pip: PiPCase()
    #else
    case .pip: EmptyView()
    #endif
    case .audioOutputs: AudioOutputsCase()
    case .lifecycle: LifecycleCase()
    case .aspectRatio: AspectRatioCase()
    case .deinterlacing: DeinterlacingCase()
    case .equalizer: EqualizerCase()
    case .audioChannels: AudioChannelsCase()
    case .audioDelay: AudioDelayCase()
    case .recording: RecordingCase()
    case .marquee: MarqueeCase()
    case .adjustments: VideoAdjustmentsCase()
    case .viewpoint: ViewpointCase()
    case .subtitlesSelection: SubtitlesSelectionCase()
    #if os(iOS) || os(macOS)
    case .subtitlesExternal: SubtitlesExternalCase()
    #else
    case .subtitlesExternal: EmptyView()
    #endif
    case .chapters: ChaptersCase()
    case .subtitlesDelay: SubtitlesDelayCase()
    case .subtitlesScale: SubtitlesScaleCase()
    }
  }
}
