@testable import SwiftVLC
import CLibVLC
import Synchronization
import Testing

extension Logic {
  @Suite(.tags(.async))
  struct SubtitleTextBridgeTests {
    @Test
    func `Initial snapshot replays to every subscriber`() async {
      let bridge = SubtitleTextBridge()

      var first = bridge.subscribe().makeAsyncIterator()
      var second = bridge.subscribe().makeAsyncIterator()

      #expect(await first.next()?.text == "")
      #expect(await second.next()?.text == "")
    }

    @Test
    func `Callback copies UTF-8 and empty string clears`() async throws {
      let harness = SubtitleTextCallbackHarness()
      let lifetime = makeLifetime(1)
      let bridge = SubtitleTextBridge()
      try #require(bridge.attach(to: lifetime, using: harness.register))
      var values = bridge.subscribe(policy: .unbounded).makeAsyncIterator()

      #expect(await values.next()?.text == "")
      await Task.detached {
        harness.send("Grüße 👋 日本語")
      }.value
      #expect(await values.next()?.text == "Grüße 👋 日本語")
      harness.send("")
      #expect(await values.next()?.text == "")

      lifetime.initialOwnerDidRelease()
    }

    @Test
    func `Callback received during registration becomes authoritative`() async throws {
      let lifetime = makeLifetime(13)
      let bridge = SubtitleTextBridge()

      try #require(
        bridge.attach(to: lifetime) { callback, opaque in
          withNativeSubtitleRegions([.automatic("during registration")]) {
            callback(opaque, $0, $1)
          }
          return true
        }
      )
      var values = bridge.subscribe().makeAsyncIterator()

      #expect(await values.next()?.text == "during registration")
      lifetime.initialOwnerDidRelease()
    }

    @Test
    func `Reattach keeps only newest callback received during registration`() async throws {
      let outgoing = SubtitleTextCallbackHarness()
      let outgoingLifetime = makeLifetime(14)
      let successorLifetime = makeLifetime(15)
      let bridge = SubtitleTextBridge()
      try #require(bridge.attach(to: outgoingLifetime, using: outgoing.register))
      var values = bridge.subscribe(policy: .unbounded).makeAsyncIterator()

      #expect(await values.next()?.text == "")
      outgoing.send("outgoing")
      #expect(await values.next()?.text == "outgoing")

      try #require(
        bridge.attach(to: successorLifetime) { callback, opaque in
          for snapshot in ["one", "two", "three"] {
            withNativeSubtitleRegions([.automatic(snapshot)]) {
              callback(opaque, $0, $1)
            }
          }
          return true
        }
      )
      #expect(await values.next()?.text == "")
      #expect(await values.next()?.text == "three")

      outgoingLifetime.initialOwnerDidRelease()
      successorLifetime.initialOwnerDidRelease()
    }

    @Test
    func `Identical snapshots are deduplicated`() async throws {
      let harness = SubtitleTextCallbackHarness()
      let lifetime = makeLifetime(2)
      let bridge = SubtitleTextBridge()
      try #require(bridge.attach(to: lifetime, using: harness.register))
      var values = bridge.subscribe(policy: .unbounded).makeAsyncIterator()

      #expect(await values.next()?.text == "")
      harness.send("same")
      harness.send("same")
      harness.send("different")
      #expect(await values.next()?.text == "same")
      #expect(await values.next()?.text == "different")

      lifetime.initialOwnerDidRelease()
    }

    @Test
    func `Two consumers receive independent copies`() async throws {
      let harness = SubtitleTextCallbackHarness()
      let lifetime = makeLifetime(3)
      let bridge = SubtitleTextBridge()
      try #require(bridge.attach(to: lifetime, using: harness.register))
      var first = bridge.subscribe(policy: .unbounded).makeAsyncIterator()
      var second = bridge.subscribe(policy: .unbounded).makeAsyncIterator()

      #expect(await first.next()?.text == "")
      #expect(await second.next()?.text == "")
      harness.send("shared")
      #expect(await first.next()?.text == "shared")
      #expect(await second.next()?.text == "shared")

      lifetime.initialOwnerDidRelease()
    }

    @Test
    func `Default buffering keeps only newest pending snapshot`() async throws {
      let harness = SubtitleTextCallbackHarness()
      let lifetime = makeLifetime(4)
      let bridge = SubtitleTextBridge()
      try #require(bridge.attach(to: lifetime, using: harness.register))
      var values = bridge.subscribe().makeAsyncIterator()

      #expect(await values.next()?.text == "")
      harness.send("one")
      harness.send("two")
      harness.send("three")
      #expect(await values.next()?.text == "three")

      lifetime.initialOwnerDidRelease()
    }

    @Test
    func `Reattach resets and drops callbacks from retired generation`() async throws {
      let oldHarness = SubtitleTextCallbackHarness()
      let newHarness = SubtitleTextCallbackHarness()
      let oldLifetime = makeLifetime(5)
      let newLifetime = makeLifetime(6)
      let bridge = SubtitleTextBridge()
      try #require(bridge.attach(to: oldLifetime, using: oldHarness.register))
      var values = bridge.subscribe(policy: .unbounded).makeAsyncIterator()

      #expect(await values.next()?.text == "")
      oldHarness.send("outgoing")
      #expect(await values.next()?.text == "outgoing")

      try #require(bridge.attach(to: newLifetime, using: newHarness.register))
      #expect(await values.next()?.text == "")
      newHarness.send("successor")
      #expect(await values.next()?.text == "successor")

      // The old attachment deliberately remains alive until its native
      // lifetime ends. Its immutable generation must make this callback inert.
      oldHarness.send("stale")
      bridge.reset()
      #expect(await values.next()?.text == "")

      oldLifetime.initialOwnerDidRelease()
      newLifetime.initialOwnerDidRelease()
    }

    @Test
    func `Failed reattach leaves outgoing generation authoritative`() async throws {
      let outgoing = SubtitleTextCallbackHarness()
      let rejected = SubtitleTextCallbackHarness(registrationSucceeds: false)
      let outgoingLifetime = makeLifetime(7)
      let rejectedLifetime = makeLifetime(8)
      let bridge = SubtitleTextBridge()
      try #require(bridge.attach(to: outgoingLifetime, using: outgoing.register))
      var values = bridge.subscribe(policy: .unbounded).makeAsyncIterator()

      #expect(await values.next()?.text == "")
      outgoing.send("before")
      #expect(await values.next()?.text == "before")
      #expect(!bridge.attach(to: rejectedLifetime, using: rejected.register))
      outgoing.send("after")
      #expect(await values.next()?.text == "after")

      outgoingLifetime.initialOwnerDidRelease()
      rejectedLifetime.initialOwnerDidRelease()
    }

    @Test
    func `Reset rejects a late same-handle cue until native clear`() async throws {
      let harness = SubtitleTextCallbackHarness()
      let lifetime = makeLifetime(9)
      let bridge = SubtitleTextBridge()
      try #require(bridge.attach(to: lifetime, using: harness.register))
      var values = bridge.subscribe(policy: .unbounded).makeAsyncIterator()

      #expect(await values.next()?.text == "")
      harness.send("outgoing")
      #expect(await values.next()?.text == "outgoing")
      bridge.reset(awaitingNativeClear: true)
      #expect(await values.next()?.text == "")

      harness.send("late outgoing")
      harness.send("")
      harness.send("successor")
      #expect(await values.next()?.text == "successor")

      lifetime.initialOwnerDidRelease()
    }

    @Test
    func `Live-output reset arms barrier while latest is already empty`() async throws {
      let harness = SubtitleTextCallbackHarness()
      let lifetime = makeLifetime(11)
      let bridge = SubtitleTextBridge()
      try #require(bridge.attach(to: lifetime, using: harness.register))
      var values = bridge.subscribe(policy: .unbounded).makeAsyncIterator()
      #expect(await values.next()?.text == "")

      // Models a cue callback that was produced before the lifecycle reset but
      // had not acquired the Swift bridge lock yet. There is no value to clear,
      // but the live-output barrier still has to reject that callback.
      bridge.reset(awaitingNativeClear: true)
      harness.send("late outgoing")
      harness.send("")
      harness.send("successor")
      #expect(await values.next()?.text == "successor")

      lifetime.initialOwnerDidRelease()
    }

    @Test
    func `Termination finishes existing and future streams`() async throws {
      let bridge = SubtitleTextBridge()
      var existing = bridge.subscribe(policy: .unbounded).makeAsyncIterator()

      #expect(await existing.next()?.text == "")
      // Publish an active cue so termination must clear presentation before
      // it finishes the stream.
      let harness = SubtitleTextCallbackHarness()
      let lifetime = makeLifetime(10)
      try #require(bridge.attach(to: lifetime, using: harness.register))
      harness.send("visible")
      #expect(await existing.next()?.text == "visible")

      bridge.terminate()

      #expect(await existing.next()?.text == "")
      #expect(await existing.next() == nil)
      var future = bridge.subscribe().makeAsyncIterator()
      #expect(await future.next() == nil)
      lifetime.initialOwnerDidRelease()
    }
  }
}

extension Integration {
  @Suite(.tags(.mainActor, .async))
  @MainActor struct PlayerTextSubtitleStreamTests {
    @Test
    func `First call opts in and later calls only add subscribers`() async throws {
      let harness = SubtitleTextCallbackHarness()
      let native = makeNativeOperations(harness: harness)
      let player = Player(instance: TestInstance.makeAudioOnly())

      var first = try player.textSubtitleStream(using: native).makeAsyncIterator()
      var second = try player.textSubtitleStream(using: native).makeAsyncIterator()

      #expect(await first.next()?.text == "")
      #expect(await second.next()?.text == "")
      #expect(harness.availabilityProbeCount == 1)
      #expect(harness.registrationCount == 1)
      harness.send("caption")
      #expect(await first.next()?.text == "caption")
      #expect(await second.next()?.text == "caption")
    }

    @Test
    func `Latest snapshot replays after every subscriber leaves`() async throws {
      let harness = SubtitleTextCallbackHarness()
      let native = makeNativeOperations(harness: harness)
      let player = Player(instance: TestInstance.makeAudioOnly())

      do {
        var first = try player.textSubtitleStream(using: native).makeAsyncIterator()
        #expect(await first.next()?.text == "")
        harness.send("first")
        #expect(await first.next()?.text == "first")
      }
      await Task.yield()

      harness.send("while unsubscribed")
      var late = try player.textSubtitleStream(using: native).makeAsyncIterator()

      #expect(await late.next()?.text == "while unsubscribed")
      #expect(harness.availabilityProbeCount == 1)
      #expect(harness.registrationCount == 1)
    }

    @Test
    func `First enable after playback started is rejected before availability probe`() throws {
      let harness = SubtitleTextCallbackHarness()
      let native = makeNativeOperations(harness: harness, isAvailable: false)
      let player = Player(instance: TestInstance.makeAudioOnly())
      player.nativePlayerHasStartedPlayback = true

      do {
        _ = try player.textSubtitleStream(using: native)
        Issue.record("Expected textSubtitleStream() to reject late opt-in")
      } catch {
        #expect(error.invalidState != nil)
        #expect(harness.availabilityProbeCount == 0)
        #expect(harness.registrationAttempts == 0)
      }
    }

    @Test
    func `Native playback started outside Player play rejects late opt-in`() throws {
      let harness = SubtitleTextCallbackHarness()
      let native = makeNativeOperations(harness: harness, isAvailable: false)
      let player = Player(instance: TestInstance.makeAudioOnly())
      player._nativePlaybackStateOverrideForTesting = .opening

      do {
        _ = try player.textSubtitleStream(using: native)
        Issue.record("Expected native-driven playback to reject late opt-in")
      } catch {
        #expect(error.invalidState != nil)
        #expect(harness.availabilityProbeCount == 0)
        #expect(harness.registrationAttempts == 0)
      }
    }

    @Test
    func `Historical native-driven playback remains a late opt-in`() throws {
      let harness = SubtitleTextCallbackHarness()
      let native = makeNativeOperations(harness: harness, isAvailable: false)
      let player = Player(instance: TestInstance.makeAudioOnly())
      // Native start history is now recorded authoritatively at callback entry;
      // this seam models that accepted start before the delayed main-actor Stop.
      player.nativePlayerHasStartedPlayback = true
      player.handleEvent(.stateChanged(.stopped))

      do {
        _ = try player.textSubtitleStream(using: native)
        Issue.record("Expected stopped native-driven playback to remain a late opt-in")
      } catch {
        #expect(error.invalidState != nil)
        #expect(harness.availabilityProbeCount == 0)
        #expect(harness.registrationAttempts == 0)
      }
    }

    @Test
    func `Stopping an idle drawable player still permits first opt-in`() async throws {
      let harness = SubtitleTextCallbackHarness()
      let native = makeNativeOperations(harness: harness)
      let player = Player(instance: TestInstance.makeAudioOnly())
      player.setDrawable(harness)

      player.stop()

      #expect(player.nativePlayerNeedsReplacementBeforePlayback)
      var values = try player.textSubtitleStream(using: native).makeAsyncIterator()
      #expect(await values.next()?.text == "")
      #expect(harness.availabilityProbeCount == 1)
      #expect(harness.registrationCount == 1)
    }

    @Test
    func `Unavailable extension and failed registration use operationFailed`() throws {
      let unavailableHarness = SubtitleTextCallbackHarness()
      let player = Player(instance: TestInstance.makeAudioOnly())

      do {
        _ = try player.textSubtitleStream(
          using: makeNativeOperations(harness: unavailableHarness, isAvailable: false)
        )
        Issue.record("Expected unavailable callback extension to throw")
      } catch {
        #expect(error.operationFailed != nil)
      }
      #expect(unavailableHarness.registrationCount == 0)

      let rejectedHarness = SubtitleTextCallbackHarness(registrationSucceeds: false)
      do {
        _ = try player.textSubtitleStream(using: makeNativeOperations(harness: rejectedHarness))
        Issue.record("Expected rejected callback registration to throw")
      } catch {
        #expect(error.operationFailed != nil)
      }
      #expect(rejectedHarness.registrationAttempts == 1)
    }

    @Test
    func `Playback racing a rejected registration is classified as late opt-in`() throws {
      let harness = SubtitleTextCallbackHarness(registrationSucceeds: false)
      let player = Player(instance: TestInstance.makeAudioOnly())
      let native = SubtitleTextNativeOperations(
        isAvailable: {
          harness.probeAvailability(true)
        },
        register: { _, callback, opaque in
          player.nativePlayerHasStartedPlayback = true
          return harness.register(callback, opaque)
        }
      )

      do {
        _ = try player.textSubtitleStream(using: native)
        Issue.record("Expected playback-start race to reject text capture")
      } catch {
        #expect(
          error
            == .invalidState("textSubtitleStream() must be called before playback starts")
        )
      }
      #expect(harness.availabilityProbeCount == 1)
      #expect(harness.registrationAttempts == 1)
      #expect(harness.registrationCount == 0)
    }

    @Test
    func `Rejected first registration can be retried`() async throws {
      let harness = SubtitleTextCallbackHarness(registrationResults: [false, true])
      let native = makeNativeOperations(harness: harness)
      let player = Player(instance: TestInstance.makeAudioOnly())

      do {
        _ = try player.textSubtitleStream(using: native)
        Issue.record("Expected first callback registration to fail")
      } catch {
        #expect(error == .operationFailed("Register text subtitle callback"))
      }
      #expect(!player.isTextSubtitleCaptureEnabled)

      var values = try player.textSubtitleStream(using: native).makeAsyncIterator()
      #expect(await values.next()?.text == "")
      #expect(harness.availabilityProbeCount == 2)
      #expect(harness.registrationAttempts == 2)
      #expect(harness.registrationCount == 1)
      harness.send("recovered")
      #expect(await values.next()?.text == "recovered")
    }

    @Test
    func `Load stop and terminal events clear without finishing stream`() async throws {
      let harness = SubtitleTextCallbackHarness()
      let native = makeNativeOperations(harness: harness)
      let player = Player(instance: TestInstance.makeAudioOnly())
      var values = try player
        .textSubtitleStream(using: native)
        .makeAsyncIterator()

      #expect(await values.next()?.text == "")
      harness.send("before load")
      #expect(await values.next()?.text == "before load")
      try player.load(Media(url: TestMedia.silenceURL))
      #expect(await values.next()?.text == "")
      harness.send("")

      harness.send("before stop")
      #expect(await values.next()?.text == "before stop")
      player.stop()
      #expect(await values.next()?.text == "")
      harness.send("")

      harness.send("before end")
      #expect(await values.next()?.text == "before end")
      player.handleEvent(.endReached)
      #expect(await values.next()?.text == "")
      harness.send("")

      harness.send("before error")
      #expect(await values.next()?.text == "before error")
      player.handleEvent(.encounteredError)
      #expect(await values.next()?.text == "")
    }

    @Test
    func `Audio-only stop cannot leave native-clear barrier armed`() async throws {
      let harness = SubtitleTextCallbackHarness()
      let native = makeNativeOperations(harness: harness)
      let player = Player(instance: TestInstance.makeAudioOnly())
      var values = try player
        .textSubtitleStream(using: native)
        .makeAsyncIterator()

      #expect(await values.next()?.text == "")
      player._nativePlaybackStateOverrideForTesting = .playing
      #expect(player.activeVideoOutputs == 0)
      #expect(player.hasVideoOutput == false)

      // An audio-only pipeline has no SPU and therefore cannot deliver the
      // native empty callback used to release a live-output reset barrier.
      // The first cue from a subsequent same-handle video must still pass.
      player.stop()
      harness.send("cue at zero")
      #expect(await values.next()?.text == "cue at zero")
    }

    @Test
    func `Successor output initial clear releases a stale vout barrier`() async throws {
      let harness = SubtitleTextCallbackHarness()
      let native = makeNativeOperations(harness: harness)
      let player = Player(instance: TestInstance.makeAudioOnly())
      var values = try player
        .textSubtitleStream(using: native)
        .makeAsyncIterator()

      #expect(await values.next()?.text == "")
      // Models a queued voutChanged(0): the native SPU has already delivered
      // its final clear, but MainActor still mirrors one outgoing output.
      player.activeVideoOutputs = 1
      player.stop()
      harness.send("retiring cue")

      // The patched engine emits this ordered empty callback when the
      // successor input attaches, before even a cue beginning at time zero.
      harness.send("")
      harness.send("cue at zero")
      #expect(await values.next()?.text == "cue at zero")
    }

    @Test
    func `Stale terminal event cannot clear successor generation`() async throws {
      let harness = SubtitleTextCallbackHarness()
      let native = makeNativeOperations(harness: harness)
      let player = Player(instance: TestInstance.makeAudioOnly())
      _ = try player.textSubtitleStream(using: native)
      var values = player.subtitleTextBridge
        .subscribe(policy: .unbounded)
        .makeAsyncIterator()

      #expect(await values.next()?.text == "")
      harness.send("successor")
      #expect(await values.next()?.text == "successor")

      player.sessionGeneration = 1
      player.handleSourcedEvent(
        SourcedPlayerEvent(
          nativeHandleGeneration: player.eventBridge.currentNativeHandleGeneration,
          playbackGeneration: 0,
          event: .stateChanged(.stopped)
        )
      )
      harness.send("still current")
      #expect(await values.next()?.text == "still current")
    }

    @Test
    func `Player reattach preserves stream and retires old callback generation`() async throws {
      let harness = SubtitleTextCallbackHarness()
      let native = makeNativeOperations(harness: harness)
      let player = Player(instance: TestInstance.makeAudioOnly())
      _ = try player.textSubtitleStream(using: native)
      var values = player.subtitleTextBridge
        .subscribe(policy: .unbounded)
        .makeAsyncIterator()
      #expect(await values.next()?.text == "")

      harness.send("outgoing", registrationAt: 0)
      #expect(await values.next()?.text == "outgoing")

      let successorLifetime = makeLifetime(12)
      try player.reattachTextSubtitleCaptureIfEnabled(to: successorLifetime)
      #expect(harness.registrationCount == 2)
      #expect(await values.next()?.text == "")

      harness.send("successor", registrationAt: 1)
      #expect(await values.next()?.text == "successor")
      harness.send("stale", registrationAt: 0)
      harness.send("still successor", registrationAt: 1)
      #expect(await values.next()?.text == "still successor")

      successorLifetime.initialOwnerDidRelease()
    }

    @Test
    func `Native player replacement reattaches capture to successor`() async throws {
      let harness = SubtitleTextCallbackHarness()
      let native = makeNativeOperations(harness: harness)
      let player = Player(instance: TestInstance.makeAudioOnly())
      _ = try player.textSubtitleStream(using: native)
      var values = player.subtitleTextBridge
        .subscribe(policy: .unbounded)
        .makeAsyncIterator()
      #expect(await values.next()?.text == "")

      let outgoingPointer = player.pointer
      let outgoingLifetime = player.nativeHandleLifetime
      let outgoingLease = outgoingLifetime.acquireNativeOwnerLease()
      _ = libvlc_media_player_retain(outgoingPointer)
      defer {
        libvlc_media_player_release(outgoingPointer)
        outgoingLease.endAfterNativeOwnerRelease()
      }
      harness.send("outgoing", registrationAt: 0)
      #expect(await values.next()?.text == "outgoing")

      try player.replaceNativePlayerForDrawablePlayback(target: nil)

      let successorPointer = player.pointer
      #expect(successorPointer != outgoingPointer)
      #expect(harness.registeredPlayers == [outgoingPointer, successorPointer])
      #expect(await values.next()?.text == "")

      harness.send("successor", registrationAt: 1)
      #expect(await values.next()?.text == "successor")
      harness.send("stale", registrationAt: 0)
      harness.send("still successor", registrationAt: 1)
      #expect(await values.next()?.text == "still successor")
    }

    @Test
    func `Replacement registration failure leaves native player atomically unchanged`() async throws {
      let harness = SubtitleTextCallbackHarness(registrationResults: [true, false])
      let native = makeNativeOperations(harness: harness)
      let player = Player(instance: TestInstance.makeAudioOnly())
      _ = try player.textSubtitleStream(using: native)
      var values = player.subtitleTextBridge
        .subscribe(policy: .unbounded)
        .makeAsyncIterator()
      #expect(await values.next()?.text == "")
      harness.send("outgoing", registrationAt: 0)
      #expect(await values.next()?.text == "outgoing")

      let outgoingPointer = player.pointer
      let outgoingLifetime = player.nativeHandleLifetime
      let outgoingEventGeneration = player.eventBridge.currentNativeHandleGeneration

      do {
        try player.replaceNativePlayerForDrawablePlayback(target: nil)
        Issue.record("Expected successor callback registration to fail")
      } catch {
        #expect(error == .operationFailed("Reattach text subtitle capture"))
      }

      #expect(player.pointer == outgoingPointer)
      #expect(player.nativeHandleLifetime === outgoingLifetime)
      #expect(player.eventBridge.currentNativeHandleGeneration == outgoingEventGeneration)
      #expect(harness.registrationAttempts == 2)
      harness.send("still outgoing", registrationAt: 0)
      #expect(await values.next()?.text == "still outgoing")
    }

    @Test
    func `Queued terminal event does not clear an already restarted playback`() async throws {
      let harness = SubtitleTextCallbackHarness()
      let native = makeNativeOperations(harness: harness)
      let player = Player(instance: TestInstance.makeAudioOnly())
      _ = try player.textSubtitleStream(using: native)
      var values = player.subtitleTextBridge
        .subscribe(policy: .unbounded)
        .makeAsyncIterator()

      #expect(await values.next()?.text == "")
      harness.send("successor")
      #expect(await values.next()?.text == "successor")
      player.publishPlaybackIntent(true)
      player.handleEvent(.endReached)
      harness.send("still visible")
      #expect(await values.next()?.text == "still visible")
    }

    @Test
    func `Shutdown finishes existing and future text streams`() async throws {
      let harness = SubtitleTextCallbackHarness()
      let native = makeNativeOperations(harness: harness)
      let player = Player(instance: TestInstance.makeAudioOnly())
      var existing = try player
        .textSubtitleStream(using: native)
        .makeAsyncIterator()
      #expect(await existing.next()?.text == "")
      harness.send("visible")
      #expect(await existing.next()?.text == "visible")

      await player.shutdown()

      #expect(await existing.next()?.text == "")
      #expect(await existing.next() == nil)
      var future = try player.textSubtitleStream(using: native).makeAsyncIterator()
      #expect(await future.next() == nil)
    }

    @Test
    func `First enable after shutdown is rejected before native probes`() async {
      let harness = SubtitleTextCallbackHarness()
      let native = makeNativeOperations(harness: harness)
      let player = Player(instance: TestInstance.makeAudioOnly())

      await player.shutdown()

      do {
        _ = try player.textSubtitleStream(using: native)
        Issue.record("Expected first text capture enable after shutdown to fail")
      } catch {
        #expect(
          error
            == .invalidState("text subtitle capture cannot be enabled after shutdown")
        )
      }
      #expect(harness.availabilityProbeCount == 0)
      #expect(harness.registrationAttempts == 0)
    }

    @Test
    func `Player deinit finishes a text stream`() async throws {
      let harness = SubtitleTextCallbackHarness()
      let native = makeNativeOperations(harness: harness)
      var player: Player? = Player(instance: TestInstance.makeAudioOnly())
      var values = try #require(player)
        .textSubtitleStream(using: native)
        .makeAsyncIterator()
      #expect(await values.next()?.text == "")
      harness.send("visible")
      #expect(await values.next()?.text == "visible")

      player = nil

      #expect(await values.next()?.text == "")
      #expect(await values.next() == nil)
    }
  }
}

final class SubtitleTextCallbackHarness: @unchecked Sendable {
  private struct Registration: @unchecked Sendable {
    let player: OpaquePointer?
    let callback: swiftvlc_subtitle_text_snapshot_cb
    let opaque: UnsafeMutableRawPointer
  }

  private struct State {
    var registrations: [Registration] = []
    var availabilityProbeCount = 0
    var registrationAttempts = 0
  }

  private let state = Mutex(State())
  private let registrationResults: [Bool]

  init(registrationSucceeds: Bool = true) {
    registrationResults = [registrationSucceeds]
  }

  init(registrationResults: [Bool]) {
    self.registrationResults = registrationResults
  }

  func probeAvailability(_ result: Bool) -> Bool {
    state.withLock { $0.availabilityProbeCount += 1 }
    return result
  }

  func register(
    _ callback: swiftvlc_subtitle_text_snapshot_cb,
    _ opaque: UnsafeMutableRawPointer
  ) -> Bool {
    register(nil, callback, opaque)
  }

  func register(
    _ player: OpaquePointer,
    _ callback: swiftvlc_subtitle_text_snapshot_cb,
    _ opaque: UnsafeMutableRawPointer
  ) -> Bool {
    register(Optional(player), callback, opaque)
  }

  private func register(
    _ player: OpaquePointer?,
    _ callback: swiftvlc_subtitle_text_snapshot_cb,
    _ opaque: UnsafeMutableRawPointer
  ) -> Bool {
    let attempt = state.withLock { state -> Int in
      defer { state.registrationAttempts += 1 }
      return state.registrationAttempts
    }
    let succeeds = registrationResults.indices.contains(attempt)
      ? registrationResults[attempt]
      : registrationResults.last ?? false
    guard succeeds else { return false }
    state.withLock {
      $0.registrations.append(
        Registration(player: player, callback: callback, opaque: opaque)
      )
    }
    return true
  }

  var availabilityProbeCount: Int {
    state.withLock { $0.availabilityProbeCount }
  }

  var registrationAttempts: Int {
    state.withLock { $0.registrationAttempts }
  }

  var registrationCount: Int {
    state.withLock { $0.registrations.count }
  }

  var registeredPlayers: [OpaquePointer] {
    state.withLock { $0.registrations.compactMap(\.player) }
  }

  func send(_ text: String) {
    send(text.isEmpty ? [] : [.automatic(text)])
  }

  func send(_ text: String, registrationAt index: Int) {
    send(text.isEmpty ? [] : [.automatic(text)], registrationAt: index)
  }

  func send(_ regions: [NativeSubtitleRegionInput]) {
    guard let registration = state.withLock({ $0.registrations.last }) else { return }
    withNativeSubtitleRegions(regions) {
      registration.callback(registration.opaque, $0, $1)
    }
  }

  func send(_ regions: [NativeSubtitleRegionInput], registrationAt index: Int) {
    guard
      let registration = state.withLock({ state in
        state.registrations.indices.contains(index) ? state.registrations[index] : nil
      }) else { return }
    withNativeSubtitleRegions(regions) {
      registration.callback(registration.opaque, $0, $1)
    }
  }
}

struct NativeSubtitleRegionInput {
  let text: String
  let placement: UInt32
  let webVTT: swiftvlc_webvtt_placement_t

  static let defaultWebVTTPayload: swiftvlc_webvtt_placement_t = {
    var placement = swiftvlc_webvtt_placement_t()
    placement.horizontal_position = 0.5
    placement.vertical_position = 0.96
    placement.horizontal_anchor = nativeUInt32(swiftvlc_webvtt_horizontal_anchor_center)
    placement.vertical_anchor = nativeUInt32(swiftvlc_webvtt_vertical_anchor_bottom)
    placement.text_alignment = nativeUInt32(swiftvlc_webvtt_text_alignment_center)
    placement.writing_direction = nativeUInt32(swiftvlc_webvtt_writing_direction_horizontal)
    return placement
  }()

  static func automatic(
    _ text: String,
    noisyWebVTTPayload: Bool = false
  ) -> Self {
    var payload = swiftvlc_webvtt_placement_t()
    if noisyWebVTTPayload {
      payload = defaultWebVTTPayload
      payload.horizontal_position = 0.17
      payload.vertical_position = 0.83
      payload.maximum_width = 0.4
      payload.flags = nativeUInt32(SWIFTVLC_WEBVTT_PLACEMENT_HAS_MAXIMUM_WIDTH)
      payload.horizontal_anchor = nativeUInt32(swiftvlc_webvtt_horizontal_anchor_right)
    }
    return Self(
      text: text,
      placement: nativeUInt32(swiftvlc_subtitle_text_placement_automatic),
      webVTT: payload
    )
  }

  static func webVTT(
    _ text: String,
    horizontalPosition: Float,
    verticalPosition: Float,
    horizontalAnchor: any BinaryInteger = swiftvlc_webvtt_horizontal_anchor_center,
    verticalAnchor: any BinaryInteger = swiftvlc_webvtt_vertical_anchor_bottom,
    maximumWidth: Float? = nil,
    maximumHeight: Float? = nil,
    textAlignment: any BinaryInteger = swiftvlc_webvtt_text_alignment_center,
    writingDirection: any BinaryInteger = swiftvlc_webvtt_writing_direction_horizontal
  ) -> Self {
    var payload = swiftvlc_webvtt_placement_t()
    payload.horizontal_position = horizontalPosition
    payload.vertical_position = verticalPosition
    payload.horizontal_anchor = nativeUInt32(horizontalAnchor)
    payload.vertical_anchor = nativeUInt32(verticalAnchor)
    payload.text_alignment = nativeUInt32(textAlignment)
    payload.writing_direction = nativeUInt32(writingDirection)
    if let maximumWidth {
      payload.maximum_width = maximumWidth
      payload.flags |= nativeUInt32(SWIFTVLC_WEBVTT_PLACEMENT_HAS_MAXIMUM_WIDTH)
    }
    if let maximumHeight {
      payload.maximum_height = maximumHeight
      payload.flags |= nativeUInt32(SWIFTVLC_WEBVTT_PLACEMENT_HAS_MAXIMUM_HEIGHT)
    }
    return Self(
      text: text,
      placement: nativeUInt32(swiftvlc_subtitle_text_placement_webvtt),
      webVTT: payload
    )
  }

  fileprivate func nativeRegion(
    text: UnsafePointer<CChar>
  ) -> swiftvlc_subtitle_text_region_t {
    var region = swiftvlc_subtitle_text_region_t()
    region.text = text
    region.placement = placement
    region.webvtt = webVTT
    return region
  }
}

func withNativeSubtitleRegions<Result>(
  _ inputs: [NativeSubtitleRegionInput],
  _ body: (
    UnsafePointer<swiftvlc_subtitle_text_region_t>?,
    Int
  )
    throws -> Result
)
  rethrows -> Result {
  guard !inputs.isEmpty else { return try body(nil, 0) }
  var regions = Array(
    repeating: swiftvlc_subtitle_text_region_t(),
    count: inputs.count
  )

  func copyText(at index: Int) throws -> Result {
    guard index < inputs.count else {
      return try regions.withUnsafeBufferPointer {
        try body($0.baseAddress, $0.count)
      }
    }
    return try inputs[index].text.withCString { text in
      regions[index] = inputs[index].nativeRegion(text: text)
      return try copyText(at: index + 1)
    }
  }

  return try copyText(at: 0)
}

func nativeUInt32(_ value: some BinaryInteger) -> UInt32 {
  UInt32(truncatingIfNeeded: value)
}

func makeLifetime(_ address: Int) -> NativePlayerHandleLifetime {
  NativePlayerHandleLifetime(pointer: OpaquePointer(bitPattern: address)!)
}

private func makeNativeOperations(
  harness: SubtitleTextCallbackHarness,
  isAvailable: Bool = true
) -> SubtitleTextNativeOperations {
  SubtitleTextNativeOperations(
    isAvailable: { harness.probeAvailability(isAvailable) },
    register: { player, callback, opaque in
      harness.register(player, callback, opaque)
    }
  )
}
