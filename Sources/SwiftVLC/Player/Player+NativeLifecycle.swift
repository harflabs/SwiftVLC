import CLibVLC
import Foundation

extension Player {
  func releaseNativePlayer(
    _ nativePlayer: OpaquePointer,
    retaining drawables: [AnyObject] = [],
    resumeBeforeStop: Bool = false
  ) {
    nonisolated(unsafe) let nativePlayer = nativePlayer
    nonisolated(unsafe) let drawables = drawables
    DispatchQueue.global(qos: .utility).async {
      libvlc_media_player_set_nsobject(nativePlayer, nil)
      Self.stopNativePlayerBeforeRelease(nativePlayer, resumeBeforeStop: resumeBeforeStop)
      libvlc_media_player_release(nativePlayer)
      _ = drawables
    }
  }

  nonisolated static func stopNativePlayerBeforeRelease(
    _ nativePlayer: OpaquePointer,
    resumeBeforeStop: Bool
  ) {
    if resumeBeforeStop || PlayerState(from: libvlc_media_player_get_state(nativePlayer)) == .paused {
      libvlc_media_player_set_pause(nativePlayer, 0)
    }
    libvlc_media_player_stop_async(nativePlayer)
  }

  var shouldReplaceNativePlayerBeforePlaybackLoad: Bool {
    guard currentMedia != nil else { return false }
    switch state {
    case .opening, .buffering, .playing, .paused, .stopping, .error:
      return true
    case .idle, .stopped:
      break
    }

    switch nativePlaybackState {
    case .opening, .buffering, .playing, .paused, .stopping, .error:
      return true
    case .idle, .stopped:
      return false
    }
  }
}
