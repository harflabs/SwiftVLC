@testable import SwiftVLC
import CLibVLC
import Foundation
import Observation
import Testing

extension Integration {
  @Suite(.tags(.mainActor), .timeLimit(.minutes(1)))
  @MainActor struct PlayerBehaviorOwnershipTests {
    @Test
    func `Reentrant load supersedes active play without starting the newer media`() throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      try player.load(Media(url: TestMedia.silenceURL))
      player._setStateForTesting(state: .playing)
      player.activeVideoOutputs = 1
      let newest = try Media(url: TestMedia.twosecURL)
      let action = BehaviorObservationAction { player.load(newest) }
      withObservationTracking { _ = player.activeVideoOutputs } onChange: {
        MainActor.assumeIsolated { action.run() }
      }

      try player.play(Media(url: TestMedia.silenceURL))

      #expect(action.didRun)
      #expect(player.currentMedia === newest)
      #expect(player.state == .idle)
      #expect(!player.nativePlayerHasStartedPlayback)
    }

    @Test
    func `Scoped adjustments follow replacement and leave the retired handle untouched`() throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      let old = player.pointer
      let lease = player.nativeHandleLifetime.acquireNativeOwnerLease()
      _ = libvlc_media_player_retain(old)
      defer {
        libvlc_media_player_release(old)
        lease.endAfterNativeOwnerRelease()
      }
      try player.withAdjustments { adjustments in
        try player.replaceNativePlayerForDrawablePlayback(target: nil)
        adjustments.contrast = 1.5
        adjustments.brightness = 0.7
        #expect(adjustments.contrast == 1.5)
      }
      #expect(player.adjustments.contrast == 1.5)
      #expect(player.adjustments.brightness == 0.7)
      #expect(libvlc_video_get_adjust_float(old, UInt32(libvlc_adjust_Contrast.rawValue)) == 1)
    }

    @Test
    func `Shared equalizer updates both players and detaches only its owner`() throws {
      let first = Player(instance: TestInstance.makeAudioOnly())
      let second = Player(instance: TestInstance.makeAudioOnly())
      let equalizer = Equalizer()
      first.equalizer = equalizer
      second.equalizer = equalizer
      var firstUpdates = 0
      var secondUpdates = 0
      first._observableControlNativeDispatchHookForTesting = { _, dispatch in
        if case .equalizer(.some) = dispatch {
          firstUpdates += 1
        }
      }
      second._observableControlNativeDispatchHookForTesting = { _, dispatch in
        if case .equalizer(.some) = dispatch {
          secondUpdates += 1
        }
      }
      equalizer.preampGain = 5.0
      #expect(firstUpdates == 1)
      #expect(secondUpdates == 1)
      first.equalizer = nil
      try equalizer.setAmplification(6, forBand: 0)
      #expect(firstUpdates == 1)
      #expect(secondUpdates == 2)
      try second.replaceNativePlayerForDrawablePlayback(target: nil)
      equalizer.preampGain = 7.0
      #expect(secondUpdates == 3)
      #expect(second.equalizer === equalizer)
    }

    @Test
    func `Native audio events update shadows and ignore unavailable native values`() {
      let player = Player(instance: TestInstance.makeAudioOnly())
      player._nativeVolumeOverrideForTesting = 20
      player._nativeMuteOverrideForTesting = 1
      player.handleEvent(.volumeChanged(0.2))
      player.handleEvent(.muted)
      #expect(player.volume == 0.2)
      #expect(player.isMuted)
      player._nativeMuteOverrideForTesting = 0
      player.handleEvent(.unmuted)
      #expect(!player.isMuted)
      player._nativeVolumeOverrideForTesting = -100
      player._nativeMuteOverrideForTesting = -1
      player.handleEvent(.volumeChanged(-1))
      #expect(player.volume == 0.2)
      #expect(!player.isMuted)
    }

    @Test
    func `A newer volume command wins over an event refresh`() {
      let player = Player(instance: TestInstance.makeAudioOnly())
      player._nativeVolumeOverrideForTesting = 20
      let action = BehaviorObservationAction { try! player.setAudioVolume(Volume(0.8)) }
      withObservationTracking { _ = player.volume } onChange: {
        MainActor.assumeIsolated { action.run() }
      }
      player.handleEvent(.volumeChanged(0.2))
      #expect(action.didRun)
      #expect(player.volume == 0.8)
    }
  }
}

@MainActor
private final class BehaviorObservationAction {
  private(set) var didRun = false
  private let action: @MainActor () -> Void

  init(_ action: @escaping @MainActor () -> Void) {
    self.action = action
  }

  func run() {
    guard !didRun else { return }
    didRun = true
    action()
  }
}
