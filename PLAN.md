# SwiftVLC v0.10.0 — Implementation Plan

**Baseline:** v0.9.1 (`d6c7a56`), libVLC 4.0 bundled under `Vendor/libvlc.xcframework`, headers under `Sources/CLibVLC/include/vlc/`.
**Status:** working spec for the next release. All work stays local until explicitly decided otherwise — no pushes, no release artifacts, no remote filings are part of this plan.
**Citations:** every `file:line` below was re-verified against the v0.9.1 tree while writing this document.

---

## 1. Overview & goals

v0.10.0 turns SwiftVLC from a strong general-purpose wrapper into a complete playback engine for the most demanding consumer class it targets: **IPTV and live-streaming clients** — apps that zap channels by calling `load()` dozens of times per session, play unknown-duration/timeshift streams, cast to Chromecast/AirPlay mid-playback, ride system Picture-in-Picture, and (on tvOS) have no touch fallback when an event misfires. Several of these behaviors were available in VLCKit (the ObjC libVLC-3 predecessor) and regress under SwiftVLC today; others are libVLC-4 semantics (async stop, end-of-media collapsed into `Stopped`) that the wrapper currently passes through raw.

After v0.10.0 a consumer can:

1. **Seek live and unknown-duration media** without exceptions (`libvlc_media_player_set_position`/`jump_time` are entirely unwrapped today — zero call sites in `Sources/SwiftVLC`; all three public seeks throw on `!isSeekable` or unknown duration, `Player.swift:803-807`, `:814-817`, `:831-834`).
2. **Distinguish natural end-of-media from a user stop.** libVLC 4 removed `libvlc_MediaPlayerEndReached`; both causes arrive as `.stateChanged(.stopped)` (`EventBridge.swift:216-217`, ambiguity admitted at `PlayerState.swift:21`). Auto-advance, mark-watched, and dismiss-on-finish features cannot be built reliably without a synthesized signal.
3. **Trust event delivery.** The public `events` stream and the player's own internal consumer both ride a fixed `.bufferingNewest(64)` subscription (`EventBridge.swift:144-152`, `Player+Events.swift:38-49`) — a consumer stalled past 64 events silently loses one-shot terminal transitions, unrecoverably.
4. **Hand playback off to a renderer mid-session** (`recast(to:)`). `setRenderer` is hard pre-play-only (`Player+Programs.swift:54-67`); VLCKit's `setRendererItem` allowed mid-playback attach, so every casting app currently reimplements capture-time → fresh-player → replay orchestration.
5. **Await stop/teardown.** `stop()` fire-and-forgets `libvlc_media_player_stop_async` (`Player.swift:776-789`); the header explicitly says to wait for the `Stopped` event (`libvlc_media_player.h:305-314`). Apps that deactivate a shared `AVAudioSession` with `.notifyOthersOnDeactivation` after teardown race the still-draining audio output and fail session-busy.
6. **Read decoded video size / vout presence** (`libvlc_video_get_size` is entirely unwrapped; `has_vout` is used only internally at `PixelBufferRenderer.swift:345`) — the only way live channels with 0×0 container track dims can drive an HD/4K badge, and the only cross-platform (tvOS-safe) surface for it.
7. **Approximate absolute subtitle point sizes** (VLC 4 removed the runtime text-renderer setter that VLCKit patched in; relative `spu_text_scale` survives, `Player.swift:251-260`).
8. **Choreograph system PiP**: a restore-to-fullscreen hook (P0.6, spike-first), defined behavior across same-`Player` `load()` media swaps (P0.7, device-validate-first), opt-out of auto-PiP and of library-owned audio-session activation, and a PiP lifecycle event stream.
9. **Set the HTTP User-Agent / app identity per instance.** `VLCInstance` hardcodes `libvlc_set_user_agent(instance, "SwiftVLC", "SwiftVLC")` (`VLCInstance.swift:241`) with no setter. IPTV providers demonstrably fingerprint and allowlist by UA; forcing `"SwiftVLC"` onto the wire invites provider 403s for exactly the consumer class this release targets.

10. **Adopt the library through a real app architecture.** A consumption fixture proves (and documents) the dynamic-intermediary topology — one dynamic core framework wrapping SwiftVLC, static feature libraries above it — yields exactly one libVLC copy (§3.14); background **audio continuation without PiP** is validated on hardware and shipped as a documented contract (§3.15); the `Volume` ceiling is widened to libVLC's real 200% software-amplification range and a **VLCKit porting guide** maps every idiom an ObjC-era consumer carries over (§3.16).

The release also lands 15 audit fixes that ride the same code the features rewrite (tracked issues #34, #36, #37, #38, #43, #44, #45, #46, #48), and a **device-validation harness** in the Showcase iOS app, because PiP is untestable in the simulator (`PiPVideoView.swift:320-327` force-disables native PiP rendering there) and two P0s are explicitly validate-first.

### Authoritative scope statement

In scope for v0.10.0:

| Class | Items |
|---|---|
| P0 features | P0.1 lenient seek · P0.2 end-reached · P0.3 recast · P0.4 videoSize/hasVideoOutput · P0.5 subtitle-size convenience · P0.6 PiP restore hook (spike-first) · P0.7 PiP media-swap continuity (validate-first) |
| Coupled prerequisites | P2.14 lossless/filtered events (prerequisite of P0.2) · P1.10 awaitable stop (anchor of the stop/teardown cluster) |
| Non-gating features | P1.11 configurable auto-PiP (**included, does not gate the release** — earlier "possible launch blocker" language is superseded) · P1.1 per-instance UA/app-id · P1.12 PiP lifecycle events (conditional deliverable of the P0.6 spike; sample-buffer half unconditional) |
| Riders on in-scope churn | P1.8 `activeVideoOutputs` (on P0.4) · P3.1 `fast:` on strict seek (on P0.1) · P2.16 audio-session deferral/opt-out (on P1.11) · P2.19 doc half — tvOS renderer-impotence note (on P0.3) · F034 `setRate` de-duplication (#43) |
| Test/CI hardening (lands FIRST) | F036 (#44) · F041 (#45) + F074 rider · P1.13 unit-suite-on-tvOS half · optional P2.19 CI slice-manifest assertion |
| Audit rows riding feature work | F001 (#34) · F003 (#37) · F004 (#36) · F005 (#38) · F009 · F017 · F022 · F023 · F024 · F037 (#46) · F043 · F044 (#48) · F052 · F061 |
| Integration & adoption | Dynamic-intermediary consumption fixture + supported-topology docs (§3.14, promoted from the deferred packaging group) · background-audio-without-PiP contract (§3.15, validate-first **and release-gating**) · `Volume` ceiling widening to 2.0 (§3.16) · VLCKit porting guide (§3.16) |
| Infrastructure | Device-validation harness in Showcase iOS (§ M5) |

Issue ledger: v0.10.0 absorbs **#34, #36, #37, #38, #43, #44, #45, #46, #48**. Open issues #16, #35, #39, #40, #41, #47, #49 are not release-gating (see §6; the F063 one-liner remains a cheap discretionary add).

Note on #37: the original triage left F003 (overlay/adjustment state dropped across the native-handle swap) without a scheduled bucket. This plan resolves that: **F003 is in scope**, inside the M2 cluster — `recast(to:)` makes the same swap user-visible mid-session, exactly when marquee/logo/adjustments are active, so the carry-over fix must land with or before it.

---

## 2. Milestone plan

Ordering is driven by three hard rules (expanded in §4): test/CI hardening lands **before** the code it protects; P2.14 lands **with or before** P0.2; the stop/teardown cluster ships as **one unit**.

### M0 — Test & CI hardening (first; everything after stands on it)

| Item | What | Why first |
|---|---|---|
| F036 (#44) | Convert ~34 silent-bailout `guard poll(...) else { return }` sites across the 4 EventBridge suites (`Tests/SwiftVLCTests/Player/EventBridgeTests.swift:37-44`, `:69-79`, `:127-141`) to `try #require(await poll(...))` per the existing `PlayerTests.swift:162` pattern | M1/M2 build their regression tests in these exact suites; building on green-on-timeout destroys the confidence the clusters need |
| F041 (#45) | Add sanitizer-eligible playback-free teardown variants (EventBridge attach/detach churn, native-handle swap via direct `replaceNativePlayerForDrawablePlayback`, offloaded deinit) and document the residual gap in `sanitize.yml`. Today `sanitize.yml:118-128` sets `CI=true` while every `PlayerCleanupRaceTests`/`AudioOutputRaceTests` test is `.enabled(if: canPlayMedia)` — TSan/ASan never see the `Player.swift:776-789` stop path or the `:389-431` deinit offload that M2 rewrites | Sanitizer backstop for the M2 rewrite |
| F074 (rider) | Remove the dead `MemoryTests` token from the `--filter` regex (`sanitize.yml:127`) while the file is open | One-liner, same file as F041 |
| P1.13 (unit half) | New CI job running `SwiftVLCTests` on a tvOS **simulator** destination (the suite runs against real libVLC). Today tvOS is build-only (`test.yml:70-79`); the `test` job's own comments admit `swift test` on the macOS host "only ever type-checks the macOS slice" (`test.yml:125-134`) | Four of the seven P0s (P0.1/P0.2/P0.4/P0.5) explicitly serve tvOS consumers; their new test suites should execute on tvOS from day one, not be retrofitted. The empty tvOS UI-test half stays deferred |
| P2.19 CI half (optional) | Archive-member manifest assertion: diff `ar t` of each `Vendor/libvlc.xcframework/*/libvlc.a` slice against a checked-in expected manifest | The tvOS slice lacks 216 iOS objects including the entire Chromecast plugin stack; P0.3 expands the casting API surface, so keeping the slice matrix true over time becomes release-relevant. Small; drop if M0 runs long |
| §3.14 fixture | Dynamic-intermediary consumption fixture: a `.dynamic` library product wrapping SwiftVLC, consumed by static libraries + an app target, with a scripted single-libvlc-copy assertion | Adoption-blocking if broken, zero coupling with feature work, and the cheapest thing in the release to learn early — if the supported topology needs a product/linkage change, every later milestone should build against it |

**Exit criteria:** EventBridge suites fail red on a never-delivered event (verified by temporarily breaking delivery); sanitizer job exercises handle-swap + offloaded-deinit paths under TSan/ASan; tvOS test job green on CI config (runnable locally via `xcodebuild test -destination 'platform=tvOS Simulator,...'`); §3.14 fixture builds for iOS + tvOS simulators with its single-copy assertion green.

### M1 — Event-delivery rework (P2.14 + riders; prerequisite of M2)

P2.14 (lossless/filtered subscriptions) plus the audit rows on the same surface: F001 (#34), F004 (#36), F009, F037 (#46), F023. Full spec §3.1.

**Why before M2:** P0.2's `.endReached` is a one-shot terminal event; on a lossy 64-newest buffer it can be dropped at exactly the moment it matters and never re-fires. The internal observable consumer rides the same lossy subscription, so even `Player.state` can permanently miss a transition under backlog.

### M2 — Stop/teardown cluster (ONE unit)

P1.10 (awaitable stop) + P0.2 (end-reached) + P0.3 (recast) + the carry-over fix F003 (#37) + F005 (#38) + F022 + F024 + F043/F044 (#48) + F052 + F034. Full specs §3.2–§3.4.

**Why one unit:** all three features mutate the same surfaces — `Player.stop()` (`Player.swift:776-789`), the media-replacement paths (`replaceNativePlayerForDrawablePlayback`, `Player.swift:519-574`; `prepareDrawableForPlayback`, `:505-509`; `releaseNativePlayer`, `Player+NativeLifecycle.swift:5-22`), and the `.stateChanged` handling (`Player+Events.swift:64-77`). Three independent changes here will conflict textually and semantically (each redefines what "stopped" means).

### M3 — Seek & playback info

P0.1 (+P3.1, F017) · P0.4 (+P1.8) · P0.5 · P1.1 · the §3.16 adoption riders (`Volume` ceiling + VLCKit porting guide). Full specs §3.5–§3.8, §3.16. Independent of M2 except that F017's position-publication fix should merge after the cluster settles `resetMediaDerivedState()`. M3 can run in parallel with the M4 spike.

### M4 — Picture-in-Picture

Gated on the **P0.6 feasibility spike** (§3.9). Then: P0.6 restore hook + P0.7 continuity (per device validation) + P1.11 (+P2.16) + P1.12 + F061. Full specs §3.9–§3.12. All device verification rides the M5 harness.

### M5 — Device-validation harness (Showcase iOS)

Built incrementally; the **skeleton plus matrix screens (a) and (c) must exist before M4's validation phase** — schedule the harness start right after M0. Full spec §3.13.

---

## 3. Per-item specs

### 3.1 P2.14 — Lossless / filtered event subscriptions (M1) — effort M

**Motivation.** One fixed policy serves two incompatible consumers: a ~30 Hz `.timeChanged`/`.positionChanged` firehose and one-shot terminal transitions (`.stateChanged(.stopped)`, `.mediaStopping`, the new `.endReached`). The public accessor takes no parameters (`Player.swift:304-306`); both broadcasters are constructed with `defaultBufferSize: 64` (`EventBridge.swift:144-145`); `Broadcaster.subscribe` hardcodes `.bufferingNewest` (`Broadcaster.swift:100-102`). A MainActor stall of a few seconds at end-of-media (scene transition, heavy reducer work, sync I/O) silently drops exactly the event an auto-advance feature needs. VLCKit's delegate dispatch was lossless; consumers porting from it have no reason to expect drops.

**Public API.**

```swift
public enum EventBufferingPolicy: Sendable {
  /// Keep the newest `count` undelivered events; older ones are dropped.
  case newest(Int)
  /// Never drop. Memory grows with consumer lag — document the caveat.
  case unbounded
}

extension Player {
  public nonisolated func events(
    policy: EventBufferingPolicy = .newest(64),
    filter: (@Sendable (PlayerEvent) -> Bool)? = nil
  ) -> AsyncStream<PlayerEvent>

  /// Lossless state-transition stream — lifecycle only, no firehose.
  public nonisolated var stateTransitions: AsyncStream<PlayerState> { get }
}
```

The existing parameterless `events` remains as sugar for the default policy.

**Internal design.**

- `Broadcaster.subscribe(bufferSize:filter:)` already exists internally (`Broadcaster.swift:96-132`); the work is a policy parameter (map `.unbounded` → `AsyncStream` `.unbounded` buffering) plumbed through `EventBridge.makeStream()`/`makeSourcedStream()` (`EventBridge.swift:147-153`) and the `Player` accessor.
- **Required fix before exposing public filters:** filters currently execute **inside** the Mutex — `broadcast()` evaluates `sub.filter?(element)` within `state.withLock` (`Broadcaster.swift:141-147`), contradicting its own doc comment ("filters and yields run outside the broadcaster's lock", `:137-139`). Harmless while filters are internal/trivial; with user-supplied closures it is a deadlock hazard (a filter touching the broadcaster re-enters the non-recursive `Mutex`) and blocks libVLC's event thread under the lock. Hoist: snapshot subscribers under the lock, evaluate filter + yield outside.
- **Upgrade the internal consumer too.** `startEventConsumer` rides `makeSourcedStream()` with the same 64-newest buffer (`Player+Events.swift:37-49`), so `Player.state` itself can miss `.stopped` under backlog. Switch the internal sourced subscription to `.unbounded` (the loop yields per event; the producer is libVLC's low-rate event thread — bounded in practice by consumer liveness).
- **F001 (#34, XS):** `unsubscribe(id:)` computes `becameEmpty` under one lock then writes `lifecyclePending = .scheduledOff` under a second (`Broadcaster.swift:245-257`), clobbering a concurrent `subscribe`'s `.scheduledOn` (`:111`) — a silently orphaned subscriber is precisely the delivery defect this item exists to kill. Move the phase write into the first lock, matching `finishAll()`/`terminate()`.
- **F009 (XS):** every libVLC event fans through two broadcasters even with zero consumers (`EventBridge.swift:155-158`). Gate each `broadcast` on the existing cheap `isEmpty`.
- **F004 (#36, XS):** every non-`.shared` `VLCInstance` leaks its log-`Broadcaster` graph through a self-contained retain cycle (`Core/Logging.swift`, the `LogBroadcaster` shared-reference design). Custom instances built with `--network-caching`/`--http-reconnect`-style arguments are the documented norm for streaming consumers, and apps that rebuild their engine per playback session pay the leak repeatedly — fix the one-line weak-box while this milestone is in the `Broadcaster` neighborhood anyway.
- **Documented limitation:** even lossless streams never see terminal events of a swapped-out native handle — `replaceNativePlayerForDrawablePlayback` calls `eventBridge.reattach(to:)` (`Player.swift:558`) before the old handle is stopped on a background queue (`Player+NativeLifecycle.swift:5-22`), and `handleSourcedEvent`'s source guard drops in-flight stragglers (`Player+Events.swift:54-56`). By design; say so in the `events` doc comment.

**Tests.** (Real libVLC, per repo convention.) Stall a consumer past 64 events across a state transition; assert the `.unbounded` stream delivers it while a `.newest(1)` stream may not (regression-documenting). Filter test: subscribe with `filter: { $0.isStateChange }`-style predicate, assert firehose events absent. Deadlock test: a filter that itself calls `events(...)` must not deadlock (post-hoist). F037 (#46, S): subscribe via `player.events`, force the handle swap (`makeAudioOnly()` + drawable flip), assert the *same* stream yields an event sourced from the new pointer. F023 (XS): fix the canonical showcase (`Showcase/iOS/CaseStudies/10-Diagnostics-Events.swift:49-56`) to subscribe **before** `play()` and demonstrate the lossless policy.

**Acceptance.** Public policy/filter API shipped; filter evaluation provably outside the lock; internal consumer lossless; F001/F004/F009 landed (F004 verified by a weak-probe test on a non-shared instance); #46 test red-green verified; the diagnostics showcase subscribes before `play()` and demonstrates the lossless policy (F023).

### 3.2 P1.10 — Awaitable stop / teardown completion (M2 anchor) — effort M

**Motivation.** `stop()` fire-and-forgets `stop_async` (`Player.swift:776-789`); the isolated `deinit` offloads `bridge.invalidate()` → stop → `libvlc_media_player_release` to `DispatchQueue.global(qos: .utility)` with no completion signal (`Player.swift:389-431`). The libVLC header is explicit: "the user should wait for the libvlc_MediaPlayerStopped event to know when the stop is finished" (`libvlc_media_player.h:305-314`). Apps that own a shared `AVAudioSession` (every iOS/tvOS media app) must deactivate it with `.notifyOthersOnDeactivation` *after* the audio output drains; without an awaitable, deactivation races the drain and fails session-busy, so other apps' audio never resumes. VLCKit's libVLC-3 stop was synchronous; this is a behavioral regression class for anyone porting.

**Public API.**

```swift
@MainActor extension Player {
  /// Stops playback and suspends until the native stop completes and
  /// audio/video outputs are released.
  public func stopAndWait() async
  /// Awaitable full teardown (deinit-equivalent choreography). The Player
  /// is unusable afterwards.
  public func shutdown() async
}
```

**Internal design.**

- `stopAndWait()` = `stop()` + await the handle's terminal `Stopped`. Use a dedicated internal unbounded sourced subscription (M1 makes this reliable), matching on the current source id; if the player is already terminal, return immediately. Defensive timeout (e.g. 10 s) with a debug-only diagnostic — never hang the caller on a wedged pipeline.
- `shutdown()` mirrors the deinit offload (`Player.swift:389-431`) but with a checked continuation resumed at the end of the offloaded closure. Refactor deinit and `shutdown()` onto one shared static helper so the choreography (set_nsobject(nil) → invalidate → stop → release → drop retained drawables) exists once.
- The completion hook at the end of the offloaded closure is exactly what **F052** needs: rewrite the vacuous cleanup-timing probe (`MemoryPressureTests.swift:673-715` dispatches its drain probe onto a *concurrent* queue, measuring nothing) on top of it.
- Clarify scope: `stopAndWait()` awaits the **explicit-stop** path only. On the media-replacement path the old handle's `Stopped` is unobservable (bridge reattached first — §3.1); `recast` (§3.4) therefore awaits *new-session readiness*, not old-handle stop.

**Riders.** **F024 (XS):** `Showcase/iOS/CaseStudies/07-Playlist-Queue.swift:72` calls only `listPlayer.stop()` on disappear, bypassing the `Player` stop state machine — fix across the three platform analogs while stop semantics are being redefined, demonstrating the new awaitable pattern. **F044 (#48, S) + F043 (XS):** weak-probe drawable-release tests (attach → swap → detach → drop refs → poll probe nil → assert `player.drawable == nil`); P1.10's awaitable makes them deterministic. **F034 (#43, XS):** make `setRate(_:)` (`Player.swift:154-161`) internal so `setPlaybackRate(_:)` (`Player+Typed.swift:46-48`) is the single public mutator — a pre-1.0 break that gets strictly more expensive after the adoption wave this release invites.

**Tests.** Play → `stopAndWait()` → assert `AVAudioSession.setActive(false)` succeeds immediately (iOS host test). `shutdown()` leaves no draining libVLC threads (signposts/weak probes). Stress: rapid load→stopAndWait→load cycles. Idempotence: `stopAndWait()` on an idle player returns immediately.

**Acceptance.** Audio-session deactivation test green; F052 probe rewritten on the real hook; deinit and `shutdown()` share one implementation; riders landed — F024 showcase stop fixed across the three platform analogs, F043/F044 weak-probe drawable-release tests green and deterministic on the new awaitable, `setRate(_:)` internal with `setPlaybackRate(_:)` the single public mutator (F034, #43).

### 3.3 P0.2 — Synthesized `.endReached` distinct from user stop (M2) — effort M

**Motivation.** libVLC 4 removed the `EndReached` player event; natural end and user stop are byte-identical `.stopped` transitions (`EventBridge.swift:216-217`; `PlayerState.swift:21` admits the ambiguity; `libvlc_media_player.h:305-314` confirms `Stopped` is also the async-stop completion). `media_player_media_stopping` carries no end-reason and fires on every teardown (`libvlc_events.h:385-388`; wrapped as `.mediaStopping`). Consumers cannot synthesize the distinction themselves: `reconcilePlaybackIntent` forces intent to `false` on any terminal state (`Player+Events.swift:197-210`) and `playbackIntentEvents` is internal (`Player.swift:308-310`). Every app with auto-advance/mark-watched/dismiss-on-finish needs this; false positives are often *permanent* (content wrongly marked watched). On tvOS there is no touch fallback when auto-advance misfires.

**Public API.**

```swift
// PlayerEvent gains:
case endReached   // .stopped reached at end-of-stream, not library/user-issued

@MainActor extension Player {
  /// True after a natural end; resets on the next load()/play().
  public internal(set) var didReachEnd: Bool { get }
}
```

**Internal design — the flag lives off the MainActor.** A `final class PlaybackEndCoordinator: Sendable` holding a `Mutex` over:

```swift
struct EndState {
  var libraryStopPending = false   // a stop() was issued; next Stopped is not natural
  var sawErrorSinceLastPlay = false
  var suppressSynthesis = false    // a MediaListPlayer is driving the handle
}
```

shared between `Player` (writer) and the EventBridge C-callback context (reader/consumer). Rules:

1. **Set** `libraryStopPending` in `stop()` **before** `libvlc_media_player_stop_async` (`Player.swift:776-789`) — the callback thread's ordering is then authoritative. Skip setting when `nativePlaybackState` is already terminal (a stop on a stopped player emits no new `Stopped`; an unconsumed flag would go stale).
2. **Clear** both `libraryStopPending` and `sawErrorSinceLastPlay` unconditionally in `resetMediaDerivedState()` (`Player+Events.swift:245-260`), which both `load()` and the replacement branch of `play(Media:)` already call. This is the critical rule: on a media swap the old handle's `Stopped` **never arrives** (bridge reattached first, source guard drops stragglers — §3.1), so a swap must *clear*, never *set*, the flag — otherwise the next genuine natural end is silently suppressed. Channel-zap apps hit this path constantly.
3. **Error latch:** libVLC 4 emits `EncounteredError` and then still transitions to stopped. The callback sets `sawErrorSinceLastPlay` when decoding the error event; synthesis is suppressed while it is set — a flaky stream must surface `.encounteredError`, not a phantom `.endReached`.
4. **Synthesis point:** in the player event callback, immediately after broadcasting `.stateChanged(.stopped)`, consult the coordinator; if neither flag is set, broadcast `.endReached` with the **same source id**. Internal source filtering then works unchanged and ordering (`.stopped` then `.endReached`) is identical for every subscriber — no MainActor consumer-lag race, no new injection API. The MainActor `handleEvent` merely sets `didReachEnd = true` on `.endReached` and resets it in `resetMediaDerivedState()`.
5. **`MediaListPlayer` bypass:** the list player drives the same native handle via `libvlc_media_list_player_set_media_player` (`MediaListPlayer.swift:59`) and stops/advances through list-player C calls (`:168`, `:174`) that never pass through `Player.stop()` — every list-initiated stop would synthesize a spurious `.endReached`. Setting `MediaListPlayer.mediaPlayer` flips `suppressSynthesis` on that player's coordinator (cleared on detach); document that list consumers should use the list-level `libvlc_MediaListEndReached` (future P2.4 work) instead.

**Documentation.** `.endReached` vs `.mediaStopping` (the latter fires for both causes); `didReachEnd` reset semantics; the list-player suppression; the swapped-handle non-delivery rule.

**Tests.** Play a short finite clip to completion → exactly one `.endReached`; explicit mid-playback `stop()` → none; `stop()` → `load()` → play-to-end → exactly one (stale-flag regression — the key test for rule 2); truncated/corrupt file → `.encounteredError`, no `.endReached`; backlog test — stall the consumer past 64 events across EOM, assert delivery on an unbounded stream (requires M1); list-player-driven stop → no synthesis; `stop()` on an already-stopped player followed by play-to-end → exactly one.

**Acceptance.** All seven tests green on macOS and tvOS-sim CI; ordering guarantee (`.stopped` precedes `.endReached`, same source) asserted.

### 3.4 P0.3 — `recast(to:)` mid-playback renderer hand-off (M2) — effort S–M

**Motivation.** The dominant casting interaction is tapping a discovered device **while playing locally**. VLCKit's `setRendererItem` allowed mid-playback attach; SwiftVLC's `setRenderer` throws unless the player is idle-like and has never played (`Player+Programs.swift:54-67`), and its docs prescribe building a fresh `Player` (`:44-48`) — forcing every casting app to reimplement capture-elapsed → new player → renderer-while-idle → replay → teardown, plus re-wiring drawable/audio-session/Now-Playing. libVLC offers no single C call (`libvlc_media_player_set_renderer` is documented pre-first-play-only); but SwiftVLC already owns the hard part internally — `replaceNativePlayerForDrawablePlayback` (`Player.swift:519-574`) rebuilds the handle and re-applies renderer (from `selectedRenderer`, `:541-546`), volume/mute/rate/role/delays/subtitle-scale/EQ/drawable, and aspect via `applyAspectRatio` (`:560`, impl `:934-949`).

**Public API.**

```swift
@MainActor extension Player {
  /// Switches the active renderer mid-playback on this same Player —
  /// drawable, observation, and app-side Now-Playing wiring survive.
  /// Pass nil to return to local playback. Resumes from the captured
  /// position when the new session is seekable.
  public func recast(to renderer: RendererItem?) async throws(VLCError)
}
```

**Internal design.**

- Ride the existing lazy path: capture `currentMedia` + `currentTime` + was-playing; save prior `selectedRenderer`; assign the new one; flip `nativePlayerNeedsReplacementBeforePlayback` (`Player.swift:361`-area flag, consumed by `prepareDrawableForPlayback`, `:505-509`); call `play()`. The swap applies the renderer to the fresh handle and throws **before any `self` state is mutated** if the renderer is rejected (`:541-546` releases only `newPointer`) — on that throw, `recast` restores the prior `selectedRenderer` and replacement flags, leaving local playback intact.
- **What is awaited — be precise.** Not the old handle's stop: on the replacement path the old handle is stopped on a background queue *after* the new one exists (`releaseNativePlayer`, `Player+NativeLifecycle.swift:5-22`) and its `Stopped` is unobservable (§3.1). `recast` awaits the **new session**: subscribe to `stateTransitions`/events, await playing, then gate time-restore on `isSeekable` becoming true (renderer sessions often reject pre-buffer seeks; live streams never become seekable — recast there is stop+swap+play, no restore). P1.10's `stopAndWait()` is the *explicit-stop* awaitable and is not on this path.
- **F003 (#37) — carry-over set, lands with or before this item.** Verified lost today (all write per-player object vars on the live pointer with no re-application in `:531-552`): marquee (`Marquee.swift` setters), logo (`Logo.swift`), video adjustments (`VideoAdjustments.swift`), teletext page (`Player+Overlays.swift` teletext setter), plus the `_marqueeText` shadow desync (`Player.swift:340`). Additional per-player state also lost, confirmed by the same pattern: **deinterlace** (`Player+Programs.swift:103`-area setter), **audio output + output device** (`Player+Audio.swift:33`, `:54` — especially relevant to recast, since renderer↔local switching is exactly when audio routing matters), **stereo/mix mode** (`Player+Audio.swift:77`, `:90`), **viewpoint** (`Player+Overlays.swift` `updateViewpoint`). Marquee restore must route through the cache-bust shadow logic (`scheduleMarqueeTextRestore`, `Marquee.swift:204-237`), not a raw var copy. **Documented resets, not carried:** A-B loop (bounds are meaningless post-recast; the `.stopped` handler already invalidates `abLoopState`, `Player+Events.swift:70-76`) and track/chapter/title selection (renderer sessions may expose different ES ids — exact parity is impossible with handle replacement; VLCKit kept the same handle, hence kept selection; document best-effort re-selection as app-side).
- **F005 (#38, S):** `MediaListPlayer` binds `newValue.pointer` once (`MediaListPlayer.swift:59`) and is never re-wired when `Player` swaps its handle. Add a main-actor swap hook re-calling `set_media_player`, or at minimum document that a list-player-attached Player must not also drive a drawable/recast. Land inside this rewrite rather than reopening it.
- **F022 (XS):** `Logo` snapshots `player.pointer` at init while `Marquee` stores the player and reads live — mirror the `Marquee` pattern while the swap surface is open (the cluster makes stale snapshots more likely to interleave).
- **P2.19 doc rider (XS):** `recast(to:)`, `setRenderer`, and `RendererDiscoverer` compile un-gated on tvOS, but the tvOS binary slice lacks the entire Chromecast plugin stack (216-object `ar t` diff vs iOS) — discovery can surface devices playback can never reach. Document the impotence on every renderer API doc comment shipped/touched by this item (compile-gating is a breaking decision deferred to the full P2.19).

**Tests.** Device-only for the real hand-off (no simulator sink) — harness matrix item (d′): start local → `recast(to: device)` → resumes on the renderer ≈ at captured time, same `Player` drives `currentTime`; `recast(to: nil)` returns to local; overlays/adjustments survive (F003 assertion); `currentMedia` survives. CI: `recast` on an idle player behaves like `setRenderer`; renderer-rejection throw leaves prior renderer + local playback intact; carry-over unit tests via the swap (set marquee/adjustments → force swap → read back). Define and test recast-while-PiP at the doc level: PiP stops with a defined reason (see §3.12); full unavailability-reason API stays deferred (P2.17).

**Acceptance.** Same-instance hand-off works on hardware; F003 carry-over verified across plain `stop()`→`play()` swaps too (the pre-existing bug, independent of recast).

### 3.5 P0.1 — Lenient/raw seek for live & unknown-duration media (M3) — effort S

**Motivation.** Live, timeshift, and catch-up streams report unknown duration yet **are** position-seekable via `libvlc_media_player_set_position(p_mi, f_pos, b_fast)` (`libvlc_media_player.h:1354-1363` — "has no effect if playback is not enabled", returns 0/−1) and time-jumpable via `libvlc_media_player_jump_time` (`:1333-1342` — relative seek that works without known duration). Both are **entirely unwrapped** (zero call sites in `Sources/SwiftVLC`); SwiftVLC only calls `set_time(…, /* fast */ false)` (`Player.swift:805`, `:849`). All three public seeks throw on live media (`:803-807`, `:814-817`, `:831-834`), so scrub/jump/remote-skip controls — including the system PiP skip buttons, which route through `try? player.seek(to:)` (`PiPVideoView.swift:526-537`) — silently die on exactly the content IPTV apps play. VLCKit accepted `position =` unconditionally and no-op'd, so ports inherit call sites that assume leniency.

**Public API.**

```swift
@MainActor extension Player {
  /// Best-effort fractional seek (wraps set_position). PlaybackPosition
  /// clamps 0...1 at construction; returns false on no-op (the C 0/-1).
  @discardableResult
  public func seek(toPosition position: PlaybackPosition, fast: Bool = false) -> Bool
  /// Precise relative seek via jump_time — works without known duration.
  @discardableResult
  public func jump(by offset: Duration) -> Bool
}
// P3.1 rider — same surface, source-compatible:
public func seek(to time: Duration, fast: Bool = false) throws(VLCError)
```

**Internal design.** Pure parameter plumbing over vendored C. `jump(by:)` must wrap `jump_time` directly — do **not** re-derive a target from `currentTime`/`duration` the way the throwing `seek(by:)` does (`Player.swift:836-851`); that derivation is what breaks on live. Keep the strict throwing trio for VOD scrubbers. Thread `b_fast` through the strict absolute seek too (P3.1 — both call sites `:805`/`:849`; default `false` preserves behavior). **F017 rider (XS):** the strict seeks update `currentTime` but never the `_position` shadow (only event handlers write it — `Player+Events.swift` position writes), leaving fractional `position` stale for paused media; publish derived position alongside `currentTime` when duration is known, on both strict and lenient paths.

**Tests.** Finite local asset: `seek(toPosition: 0.5)` lands ≈ half duration; `position` updates while paused (F017). HLS live URL: `seek(toPosition:)` returns without throwing, playback continues. `jump(by: .seconds(-10))` rewinds VOD; returns `false` on a stopped player (no crash). `fast: true` vs `false` landing precision on a long sparse-keyframe file. **Device caveat:** whether timeshift inputs accept `set_position` with unknown duration is a demuxer runtime property — harness matrix item (f) gates declaring this item complete.

**Acceptance.** Lenient pair shipped + tested on macOS and tvOS-sim CI; harness item (f) executed against a real catch-up stream.

### 3.6 P0.4 — `videoSize` + `hasVideoOutput` (M3) — effort S

**Motivation.** Resolution badges (HD/4K) on live channels whose containers declare 0×0 track dims need the *decoded* size. `libvlc_video_get_size` (`libvlc_media_player.h:1990-1993`) is entirely unwrapped; `libvlc_media_player_has_vout` (`:1535`) is called only inside the PiP renderer (`PixelBufferRenderer.swift:345`) with no public symbol. The raw `.voutChanged(Int)` event exists (`PlayerEvent.swift:43`) but the `@Observable` handler drops it in the no-mutation `break` branch (`Player+Events.swift:168-172`) — no synchronous getter, no initial value, no observation. `Track.width/height` are container-declared, not decoded. VLCKit parity: `videoSize`/`hasVideoOut`. PiP frame dims cannot substitute — the PiP types do not compile on tvOS, so this must live at the cross-platform `Player` layer.

**Public API.**

```swift
@MainActor extension Player {   // Player is already @Observable
  public var videoSize: CGSize? { get }    // nil when no vout / C returns -1
  public var hasVideoOutput: Bool { get }
  // P1.8 rider — stored, replaces the break branch:
  public internal(set) var activeVideoOutputs: Int { get }
}
```

**Internal design.** `videoSize`/`hasVideoOutput` are computed live-reads with `.voutChanged`-triggered empty `withMutation` invalidation — the existing externally-mutated-state idiom (`Player+Events.swift:150-166`). **Do not refresh only off `.voutChanged`:** adaptive-HLS mid-stream resolution switches fire no size event in libVLC 4 — also invalidate on track-selection events (`esSelected`/tracksChanged handling already in the same switch). **P1.8 rider (S):** the event payload already carries the new vout count (decoded at `EventBridge.swift` voutChanged branch) — store it (mirroring the `bufferFill` stored-state pattern, `Player.swift:51`) by replacing the `break`, and reset it in `resetMediaDerivedState()` so a stale count never survives a media change. P0.4's invalidation wires off the same lines — shipping one without the other touches and reopens the identical branch.

**Tests.** Known-resolution local file: `videoSize` equals known size once vout is up, `hasVideoOutput == true`, `activeVideoOutputs ≥ 1`; audio-only file: `nil`/`false`/`0`; both flip on the `.voutChanged` transition; values reset across `load()`. Harness: a live stream with declared 0×0 dims yields non-nil decoded size (engine smoke screen); an adaptive rendition switch updates `videoSize` without vout recreation.

**Acceptance.** All three properties ship together (they share the rewritten `.voutChanged`/track-selection invalidation branch — partial landing reopens it); CI tests green on macOS and tvOS-sim; `activeVideoOutputs` reset covered by the across-`load()` test; harness smoke screen confirms a decoded size on a declared-0×0 live stream and the adaptive-switch invalidation on hardware.

### 3.7 P0.5 — Approximate absolute subtitle size (M3) — effort S

**Motivation.** VLCKit-era apps exposed absolute subtitle point sizes via a runtime text-renderer setter that was a VLCKit-side libVLC-3 patch, never carried to VLC 4 (VLCKit's own v4 source comments it out pending upstream #294). SwiftVLC offers relative scaling only — `subtitleTextScale`/`setSubtitleScale` (`Player.swift:251-260`) over `spu_text_scale` (`libvlc_media_player.h:2160`, `:2179`). 10-foot tvOS UIs ship font-size pickers; those apps need a supported approximation. Decision recorded: ship the relative convenience; document the **static** `--freetype-fontsize` config-option escape hatch (the freetype module is present in both iOS and tvOS slices per the archive audit) as *experimental pending device validation*; do not escalate upstream beyond watching #294.

**Public API.**

```swift
extension SubtitleScale {   // ExpressibleByFloatLiteral with presets, PlaybackValues.swift
  public init(approximatePoints: Double, basePoints: Double = 18)
}
```

**Internal design.** Pure value-type math (clamped to SubtitleScale's 0.1...5.0). Docs: a live mid-playback *absolute* size change is impossible in VLC 4 — say so explicitly; document the `VLCInstance(arguments: ["--freetype-fontsize=…"])` / `Media.addOption` static path with the experimental caveat.

**Tests.** `SubtitleScale(approximatePoints: 36, basePoints: 18)` ≈ 2.0; applying it updates `subtitleTextScale`; the value survives the native-handle swap (it is in the re-applied set — `libvlc_video_get/set_spu_text_scale` carry-over at `Player.swift:535`/`:551`). Harness item (g): device-validate `--freetype-fontsize` on a subtitled stream before the escape hatch is documented as working.

**Acceptance.** Convenience init shipped with clamping and the "no live absolute size change in VLC 4" limitation documented; swap-survival test green; the `--freetype-fontsize` escape hatch is documented only with whatever harness item (g) actually observed on device (pass *or* fail — the doc states the recorded result, never an untested claim).

### 3.8 P1.1 — Per-instance User-Agent / application id (M3) — effort S

**Motivation.** `VLCInstance` hardcodes `libvlc_set_user_agent(instance, "SwiftVLC", "SwiftVLC")` (`VLCInstance.swift:241`); the only public init takes `arguments:` alone. IPTV providers fingerprint and allowlist by UA — a library that forces `"SwiftVLC"` onto the wire breaks playback for the very consumer class v0.10 targets, with only a per-media HTTP-only `addOption(":http-user-agent=…")` escape hatch. C: `libvlc_set_user_agent` (`libvlc.h:215-217`) + sibling `libvlc_set_app_id` (`:229-231`), both unwrapped; VLCKit exposed both. UA is instance-global and must be set right after `libvlc_new` — which is exactly where the hardcode sits.

**Public API.**

```swift
extension VLCInstance {
  // Widen the existing designated init IN PLACE (nil defaults — a parallel
  // all-defaulted extension init invites overload ambiguity):
  public init(arguments: [String] = defaultArguments,
              applicationName: String? = nil,
              httpUserAgent: String? = nil) throws(VLCError)
  public func setUserAgent(name: String, http: String)
  public func setAppID(_ id: String, version: String, icon: String)
}
```

`"SwiftVLC"` remains the default when nil. Effort S, zero coupling. (The per-media typed sugar sibling stays deferred — `Media.addOption` is already public.)

**Tests.** Init with custom UA + assert via a local HTTP fixture that the wire UA matches (the test suite already plays network fixtures); `setAppID` smoke (no observable getter — assert no throw/no crash, document fire-and-forget).

**Acceptance.** Wire-UA fixture test green; behavior with both parameters nil byte-identical to today (`"SwiftVLC"`/`"SwiftVLC"` defaults — zero change for existing consumers); the designated init widened in place with no new overload (ambiguity check compiles a nil-free call site unchanged).

### 3.9 P0.6 — PiP restore-to-fullscreen hook (M4) — **feasibility spike first**

**Motivation.** System PiP has two exits: the **restore** button (app should rebuild its fullscreen UI; AVKit holds the shrink-back animation until the app calls the completion) and the **X** button (app should dismiss/teardown). SwiftVLC surfaces both as the same `isActive → false` flip. `grep -rn restoreUserInterface Sources/` = zero hits; `PiPController`'s delegate conformance implements only willStart/didStart/didStop/failedToStart (`PiPController+Delegate.swift`). Without an async restore callback, no app can choreograph PiP→fullscreen or distinguish close from restore — a hard blocker for any app replacing an in-app floating player with system PiP.

**Ground truth (native drawable path).** SwiftVLC never owns the `AVPictureInPictureController` there: libVLC's window controller arrives via the `pictureInPictureReady` block (`PiPVideoView.swift:249-256` → `handlePictureInPictureReady`, `:358-375`); SwiftVLC KVC-extracts `avPipController` (`:440-446`) and installs only KVO on `isPictureInPicturePossible`/`isPictureInPictureActive` plus the `stateChangeEventHandler` block (`:428-438`). `PiPController.delegate = self` is wired only on the sample-buffer path (`PiPController.swift:469`). The only native-path interception point is `avController.delegate` post-extraction.

**Public API (ships regardless of spike outcome).**

```swift
@MainActor extension PiPController {
  /// Invoked from restoreUserInterfaceForPictureInPictureStop…; the AVKit
  /// completion is held until the async body finishes.
  public var onRestoreUserInterface: (@MainActor () async -> Void)? { get set }
}
```

**De-risked split:** the API plus its trivial **sample-buffer-path implementation** (where SwiftVLC *is* the delegate and the restore method is simply missing from `PiPController+Delegate.swift`) lands spike-independent. Only the **native-path wiring** is spike-gated.

**Spike protocol (one device session, shares hardware time with the P0.7 matrix; ~1–2 days):**

1. **Baseline:** does libVLC's delegate implement `restoreUserInterfaceForPictureInPictureStop(completionHandler:)`? (`respondsToSelector` probe on `avController.delegate`, log its class.) What do restore/X visibly do today? (Harness matrix item (c).)
2. **Delegate identity + set-timing:** is the delegate the window controller itself or a helper, and is it assigned before the ready callback fires? Lazy assignment after extraction clobbers naive replacement — this single observation decides proxy vs libVLC-patch.
3. **Forwarding-proxy viability:** install a retained NSObject proxy (`forwardingTargetForSelector` to the original delegate; `AVPictureInPictureController.delegate` is weak, so the backend stores the proxy and clears it in `clearWindowController`, `PiPVideoView.swift:415-426`) that adds the restore method with deferred completion. Pass criteria: possible/active flags keep tracking (libVLC bookkeeping intact); restore tap fires the hook and the deferral visibly holds the shrink-back; X tap fires didStop only. Edge to resolve: if the original delegate *also* implements restore — exactly one completion call, and observe whether the original's restore does real work (e.g. vout re-attachment) that must still run.
4. **Survival across vout rebuilds:** `handlePictureInPictureReady` clears+reinstalls per media (`:358-362`) — verify proxy reinstall across a channel zap.
5. **Install-while-active:** does AVKit check `respondsToSelector` for restore at delegate-set time or per-invocation? (Determines whether the hook can be installed after PiP already started.)

**Exit criteria / go-no-go.** *Go (M):* (2) shows stable early assignment and (3) passes → implement the proxy; **P1.12's event stream becomes an explicit deliverable of the same plumbing** (willStart/didStart/didStop/failedToStart flow through interception built exactly once). Also: per audit F062, if the proxy is installed on the native path, re-evaluate the `pipMainActorSync` `DispatchQueue.main.sync` invariant (`PiPController+Delegate.swift`) for the new call paths — write the conclusion into the spike report. *No-go (L+):* fallback is a libVLC-side patch to the bundled window controller adding a restore-handler property analogous to `stateChangeEventHandler` — feasible without upstream acceptance because the binary is built locally (`scripts/build-libvlc.sh`); record the fork-maintenance liability and re-estimate M4 before committing.

**What the spike cannot determine:** stability of the private KVC surface (`"avPipController"`, `"stateChangeEventHandler"`) across libVLC revisions — acceptable because the binary is pinned and the existing `respondsToSelector` guards (`:429`, `:441`) degrade gracefully; the contract is re-testable per pin.

**Rider — F061 (XS):** the `@objc` drawable selectors (`mediaController`/`pictureInPictureReady`/`canStartPictureInPictureAutomaticallyFromInline`, `PiPVideoView.swift:244-261`) inherit `@MainActor` isolation but are invoked from libVLC's vout thread; bodies are immutable-only today, but P0.6/P0.7 add mutable state to this exact file. Make the bodies `nonisolated` and document the off-main contract while the file is open, so future mutable access fails to compile.

**Tests.** Device-only manual matrix (harness items (c) + spike steps 3–5): restore → hook fires, completion deferral holds the animation until the fullscreen UI is up; X → didStop only, no restore callback. Sample-buffer path: unit-testable delegate-method presence + completion-once semantics.

**Acceptance.** `onRestoreUserInterface` API + sample-buffer implementation merged regardless of spike outcome; spike report recorded (delegate identity/timing, proxy pass-fail per step 3–5, the F062 `pipMainActorSync` conclusion) before any native-path implementation merges; on *go* — device matrix shows restore firing the hook exactly once with the AVKit completion held until the async body returns, X never firing it, and possible/active tracking intact across a channel zap; F061 rider landed (bodies `nonisolated`, off-main contract documented).

### 3.10 P0.7 — PiP continuity across `load()` on the same Player (M4) — **validate-first**

**Motivation.** Channel-zap UX: PiP must survive starting new content on the same `Player`. `PiPVideoView.updateUIView` rebuilds the controller only on `Player` *identity* change (`PiPVideoView.swift:52-65`), so a same-player `load()` keeps the Swift-side controller — but every new media triggers libVLC vout teardown/recreation, and `handlePictureInPictureReady` unconditionally clears the previous window controller (KVO, `avPipController`, `stateChangeEventHandler`) before installing the new one (`:358-375`; `clearWindowController` `:415-426`). Whether the **OS PiP window** visually survives a stop→load→play cycle is a property of libVLC's bundled vout reusing the AVKit controller — not determinable from source. There is no "was active → re-start on next ready" mechanism and no event telling the app the PiP backend was rebuilt.

**Plan.** Harness matrix item (a) answers it on hardware first. Outcomes:

- *Window survives:* effort S — document the guarantee + gap/freeze characteristics per content-class transition (VOD→live, live→live); add a regression note to the harness.
- *Window closes:* effort M–L — implement auto-resume:

```swift
@MainActor extension PiPController {
  /// When true (default), PiP active at the start of a media swap is
  /// re-started when the new vout's ready callback fires.
  public var resumesAcrossMediaReplacement: Bool { get set }
}
```

  ("was-active" latch set when `handlePictureInPictureReady` clears a controller while `isActive`, consumed on the next ready callback → `start()`), plus a backend-rebuilt signal on the P1.12 stream so apps can react if auto-resume fails. If even re-`start()` cannot be made acceptable, the remaining path is libVLC-side controller reuse — same fork-liability calculus as P0.6's no-go branch; escalate to the maintainer with the device evidence before committing.

**Tests.** Device-only matrix: PiP on stream A → `load()` B (same `Player`) → window survival, gap/freeze duration; seekable-VOD→live and live→live; the fresh-`Player` renderer hand-off case is *expected* to tear PiP down via the identity check (`:52-65`) — confirm and document.

**Acceptance.** Matrix item (a) results recorded for all transition classes *before* any mechanism commitment; on *survives* — the guarantee and per-class gap/freeze characteristics documented on the PiP API surface plus a harness regression note; on *closes* — `resumesAcrossMediaReplacement` (default `true`) implemented and device-verified to re-engage PiP across a zap, with the backend-rebuilt signal emitted on the P1.12 stream; the fresh-`Player` teardown behavior confirmed and documented either way.

### 3.11 P1.11 + P2.16 — Configurable auto-PiP and audio-session policy (M4) — effort S

**Motivation.** Both PiP paths force `canStartPictureInPictureAutomaticallyFromInline = true`: the native drawable protocol method returns a literal `true` (`PiPVideoView.swift:258-261`) and the sample-buffer path sets the AVKit flag (`PiPController.swift:471`); `PiPVideoView.init` takes no configuration. Auto-PiP is an OS-policy bit the app must own: **apps with parental-control or policy-gated playback** (watch-time limits, lock screens) cannot tolerate video escaping to an OS window the app can only reclaim with a visible flash; kiosk/enterprise apps disable it outright. Hardcoding it in a library is wrong regardless of any one consumer's default. *(Authoritative: P1.11 is in scope and non-gating — earlier "possible launch blocker" language is superseded by the recorded decision.)*

**P2.16 rider (same init, second knob — avoids two-pass pre-1.0 API churn).** Every `PiPController` init on iOS calls `configureAudioSession()` — `.playback`/`.moviePlayback` + `setActive(true)`, errors `try?`-swallowed (`PiPController.swift:379-385`; called from both init paths). Because `PiPVideoView` builds a fresh controller per player swap (`PiPVideoView.swift:52-65`), the library re-activates the session at view-construction times the app does not control, re-grabbing audio focus from other apps after a dismiss — and undoing P1.10's own acceptance criterion (`setActive(false)` succeeds after `stopAndWait()`).

**Public API.**

```swift
PiPVideoView(player, controller: $pip,
             startsAutomaticallyFromInline: Bool = true,
             managesAudioSession: Bool = true)
```

plumbed to both backend sites; when `managesAudioSession` is true, defer `setActive(true)` from init to `start()`/first active playback.

**Tests.** Device-only: flag false → background during fullscreen playback → no PiP, audio continues (interacts with the deferred background-contract item — record observations for it); flag true → auto-PiP engages. Audio-session: construct `PiPVideoView` with `managesAudioSession: false` → session category/active state untouched (assertable in a host app).

**Acceptance.** Both knobs plumbed to both backend sites (the native protocol method's literal `true` and the sample-buffer AVKit flag; both `configureAudioSession()` call paths); defaults (`true`/`true`) preserve current behavior exactly; `managesAudioSession: false` leaves session category and active state untouched in a host-app assertion; with it `true`, activation is deferred to `start()`/first active playback (no re-grab at view construction — verified against P1.10's `setActive(false)` criterion); device matrix items (b)/(e) recorded.

### 3.12 P1.12 — PiP lifecycle events + stop reason + surfaced failure (M4) — effort S–M, conditional

**Motivation.** Beyond two booleans (`isPossible`/`isActive`), SwiftVLC emits no PiP lifecycle stream, and the `failedToStartPictureInPictureWithError` error is explicitly discarded with `_` (`PiPController+Delegate.swift:46-53` — the doc comment even says "SwiftVLC does not propagate PiP start failures"). Apps need: failure detail for logging/retry policy, stop *reason* (user-close vs restore vs failure vs media-end — error-driven stop-PiP for a frozen-frame stream error depends on it), and will/did transitions to pause expensive fullscreen work.

**Public API.**

```swift
public enum PiPStopReason: Sendable { case userClosed, restoreRequested, failure, mediaEnded, unknown }
public enum PiPEvent: Sendable {
  case willStart, didStart
  case willStop(reason: PiPStopReason), didStop(reason: PiPStopReason)
  case failedToStart(any Error)
}
@MainActor extension PiPController { public var pipEvents: AsyncStream<PiPEvent> { get } }
```

**Scoping.** Sample-buffer path (SwiftVLC owns the delegate): unconditional — emit the stream and stop discarding the error. Native path: conditional deliverable of the P0.6 spike's *intercept* outcome (the proxy is the only place will/did/failed are observable; emitting then is near-free, retrofitting later reopens the interception). `userClosed` vs `restoreRequested` discrimination *requires* P0.6's restore callback — without it, reasons degrade to `.unknown`; document that. recast-while-PiP (§3.4) emits `didStop(reason:)` with a defined reason.

**Tests.** Device-only manual matrix shared with P0.6 (restore/X/failure/media-end each produce the right event+reason). Use a `Broadcaster` under the hood so the M1 policy work applies.

**Acceptance.** Sample-buffer half shipped unconditionally: delegate methods emit `PiPEvent`s and `failedToStart` carries the previously-discarded error (`PiPController+Delegate.swift:46-53` no longer drops it); native half ships iff the P0.6 spike returns *go* (otherwise deferred with the interception, documented); reason fidelity documented — without the restore hook, `userClosed`/`restoreRequested` degrade to `.unknown`; recast-while-PiP emits `didStop` with the §3.4-defined reason; device matrix rows for restore/X/failure/media-end recorded.

### 3.13 M5 — Device-validation harness (Showcase iOS app) — effort M

**Motivation.** PiP cannot be validated in the simulator (`PiPVideoView.swift:320-327`), two P0s are validate-first, and several acceptance criteria above are demuxer/OS runtime properties. The harness is a new section in the existing Showcase iOS app: one screen per matrix item plus one engine smoke screen per content class, so any maintainer with a device and their own streams can re-run the matrix per release.

**Stream configuration — operator-supplied, never committed.** The harness reads a gitignored local config; the repo documents the shape and ships no URLs:

```jsonc
// Showcase/iOS/ValidationHarness/streams.local.json   (gitignored; a
// streams.local.example.json with placeholder hosts IS committed)
{
  "liveTS":    "http://<host>/live/channel.ts",     // raw MPEG-TS live
  "hlsLive":   "https://<host>/live/master.m3u8",   // live HLS, unknown duration
  "vod":       "https://<host>/movie.mp4",          // finite, seekable
  "catchup":   "http://<host>/timeshift/...",       // timeshift/catch-up capable (matrix f)
  "subtitled": "https://<host>/subbed.m3u8",        // text subtitles (matrix g)
  "adaptive":  "https://<host>/abr/master.m3u8",    // multi-rendition (P0.4 switch test)
  "audioOnly": "https://<host>/radio.aac"
}
```

Missing keys disable the dependent screens with an explanatory row, so a partial config still runs.

**Matrix screens (one each):**

| # | Screen | Gates |
|---|---|---|
| (a) | PiP survival across same-`Player` `load()` (channel zap), per transition class | P0.7 — top release risk |
| (b) | Auto-PiP trigger conditions from a fullscreen view (full-screen + playing at background time) | P1.11 |
| (c) | Restore/X baseline with no hook installed (logs delegate class, `respondsToSelector` probes) | P0.6 spike step 1–2 |
| (d) | Cast-start-while-PiP behavior; (d′) `recast` end-to-end against a real sink | P0.3; deferred P2.17 evidence |
| (e) | Background audio continuation when PiP does **not** engage (vout starved) | §3.15 — **release-gating**; P1.11 test |
| (f) | `set_position`/`jump_time` against a real timeshift/catch-up stream | P0.1 completeness |
| (g) | `--freetype-fontsize` survival on a subtitled stream | P0.5 escape-hatch doc |

**Engine smoke screens** (one per content class: live TS, HLS live, VOD, catch-up): start latency, seek behavior, track listing, hardware-decode/statistics readout — establishing baseline libVLC-4 demuxer behavior for the risk register.

**Acceptance.** Harness builds in CI (compile only — screens are device-interactive); every matrix screen renders a recordable PASS/FAIL/observation row; results from one full device pass are recorded in the spike/validation report before M4 features merge.

### 3.14 Consumption through a dynamic intermediary framework — fixture + supported-topology docs (M0) — effort S–M

**Motivation.** SwiftVLC's library product is **automatic type** (`Package.swift:9`, no `type:`), and its binary dependency is a large per-slice **static archive** (`Vendor/libvlc.xcframework/*/libvlc.a` — `ar` archives, the iOS slice alone hundreds of MB). Layered apps routinely put all SDK-heavy integrations behind a single **dynamic** core framework — so module maps and linker settings propagate once — with many static feature libraries above it and the app target on top. Whether that topology yields exactly **one** copy of libVLC in the final process is untested. SwiftVLC's own manifest already documents the failure mode for its test target: re-linking `CLibVLC` "can load duplicate Objective-C runtime classes from libVLC's static dependencies" (`Package.swift:80-83`). Two copies means duplicate-class warnings at launch, two libVLC plugin registries and static-initializer runs, and undefined behavior in exactly the casting/PiP ObjC machinery this release builds on; if Xcode instead resolves the automatic product *statically into every consumer*, the breakage is the same with more copies. Until the supported topology is proven and documented, adoption through any nontrivial app architecture is a coin flip — which is why this runs in **M0**, before feature work piles on top.

**Deliverable.** A fixture (e.g. `Fixtures/DynamicHost/`): a local package declaring a `.library(type: .dynamic)` product `MediaCore` that depends on SwiftVLC, two `.static` feature libraries depending on `MediaCore`, and a minimal app target linking the app + both features. Scripted assertions: the app launches with zero ObjC duplicate-class runtime warnings; exactly one statically-bound libvlc copy in the final bundle (`nm`/`otool` symbol-presence audit over every image); `VLCInstance.shared` reachable from both static features and identity-equal across them. A new docc page records the supported product/topology guidance — including whether SwiftVLC's product should declare an explicit `type:` — so consumers don't rediscover this empirically.

**Tests / acceptance.** Fixture builds in CI for iOS and tvOS simulators; the single-copy script assertion is green; the docc topology page ships. **If the fixture fails, fixing the product/linkage declaration is in scope for this release** — learning that is the point of running it first.

### 3.15 Background audio continuation without PiP (validated in M5, **release-gating**) — effort doc-S, fix-M on failure

**Motivation.** Media apps ship `UIBackgroundModes: audio` and rely on the engine continuing **audio** decode while the video output is starved in the background — that is the entire basis of lock-screen Now-Playing and remote-command UX. On tvOS (no PiP exists) and on iOS whenever PiP is impossible, not engaged, or disabled (P1.11 ships exactly that knob), this is the *only* background path. libVLC-3-era wrappers continued audio in this state; whether libVLC 4's pipeline stalls when the drawable vout is starved without PiP is a runtime property not determinable from source. Previously this was deferred as observation-only; it is promoted because it is a correctness **contract**, not a curiosity — a consumer cannot adopt the library for background-audio apps on a "we'll see" basis.

**Plan.** Harness matrix item (e) answers it on hardware. Outcomes:

- *Audio continues:* document the guarantee on `VideoView`/`Player` (audio keeps playing with the vout starved; `timeChanged` keeps firing for lock-screen position; video rendering resumes on foreground), plus the tvOS equivalent statement.
- *Pipeline stalls:* a background-policy fix becomes **in scope before release** — design after the evidence (candidates: suspend-video-keep-audio via vout disable, or drawable detach/reattach choreography on scene-phase transitions).

**Acceptance.** Matrix (e) recorded for: fullscreen playing → background with auto-PiP off; audio-only media → background; foreground return re-renders video. On *continues* — the documented guarantee ships. On *stalls* — the fix is implemented and matrix (e) re-run green. **The release does not ship with (e) unresolved.**

### 3.16 Adoption riders (M3): `Volume` ceiling widening + VLCKit porting guide — effort XS + S

**Volume ceiling (XS).** `Volume` clamps to `0.0...1.25` with `.max = 1.25` (`Player/PlaybackValues.swift:56-84`). libVLC's software amplification accepts well beyond nominal (volume is a percentage where 100 = 0 dB), and VLCKit exposed the full 0–200 range — so ports that map a full-scale volume slider to 200% silently lose their loudness headroom, a user-audible regression on quietly-mastered streams. Widen the clamp to `0.0...2.0` (`.max = 2.0`), update the doc comment with the above-unity distortion caveat. Source-compatible: clamping only loosens; `.unity` and all literals below 1.25 behave identically.

**VLCKit porting guide (S, docc page).** One page mapping VLCKit idioms to their SwiftVLC equivalents, cross-linked to the APIs this release ships: unconditional `position =` writes → lenient `seek(toPosition:fast:)`/`jump(by:)` (§3.5); the `.ended` state → `.endReached`/`didReachEnd` (§3.3); mid-playback `setRendererItem` → `recast(to:)` (§3.4); index-based track selection (`-1` = off) → stable `Track.id` selection with `nil` deselect; **rebuffering**: SwiftVLC synthesizes a `.buffering` state only pre-play (`Player+Events.swift:125-139`) — derive mid-playback rebuffer spinners from `bufferFill < 1` while `.playing`; **live metadata**: there is no `mediaMetaDataDidChange` equivalent — `await media.parse()` once before playback is the supported pattern, and live ICY-style in-stream metadata updates are not observed (state the limitation explicitly); delegate thread-marshaling proxies (`NSLock` + main-queue hops) → delete, events are MainActor-consumable; the 0–200 volume scale → `Volume` 0–2.0. Every claim in the guide must link to a shipping symbol — the guide doubles as an adoption-coverage checklist for this release.

**Tests / acceptance.** `Volume` clamp tests updated (2.0 passes through as 200%, 2.5 clamps to 2.0, `.unity` byte-identical); wire-through asserted against `libvlc_audio_set_volume`; the porting guide ships in docc with all cross-links resolving.

---

## 4. Coupling & sequencing constraints

1. **Test-first rule (M0).** F036/F041/P1.13-unit land before M1/M2 code. New feature tests must be written against the hardened harness (no `guard poll … else { return }` pattern — `try #require` only).
2. **P2.14 before P0.2 — load-bearing.** A lossy stream structurally undermines a one-shot terminal event. Do not ship P0.2 alone. (The C-callback synthesis design reduces but does not remove the dependency: `Player.state`/`didReachEnd` still ride the internal subscription M1 upgrades.)
3. **M2 is one unit.** P1.10 + P0.2 + P0.3 + F003/F005/F022 all touch `Player.swift` stop/swap paths and `Player+Events.swift` terminal handling. One branch, one review, one merge. F003 must land **with or before** `recast` (the swap becomes user-visible mid-session).
4. **Flag semantics invariant (P0.2):** set on `stop()` *before* `stop_async`; **cleared** (never set) on every media-replacement/load path via `resetMediaDerivedState()`; consumed only at `Stopped` decode on the callback thread; error latch suppresses synthesis. Any deviation re-derives the stale-flag bug.
5. **Spike gate before M4 commitment.** No M4 implementation work (beyond the spike-independent `onRestoreUserInterface` API + sample-buffer implementation, P1.11/P2.16, and F061) until the P0.6 spike reports go/no-go and P0.7's matrix item (a) has device results. Re-estimate M4 at that point.
6. **Harness skeleton early.** M5's screens (a)/(c) must exist before the spike session; schedule harness scaffolding immediately after M0.
7. **What `recast` awaits:** new-session seekability — never the old handle's stop (unobservable post-reattach). `stopAndWait()` is the explicit-stop awaitable only. Implementing the cluster with these crossed is the most likely coupling mistake; §3.2/§3.4 are the authority.
8. **Local-only.** Nothing in this plan pushes, releases, tags, or files anything remote.

---

## 5. Risk register

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| **P0.6 not implementable as a proxy** (late delegate assignment, broken state tracking) | Medium | M4 slips to L+ (libVLC-side patch; fork maintenance liability) | Spike-first with explicit no-go criteria; restore API + sample-buffer half ship regardless; patch path is locally feasible (`scripts/build-libvlc.sh`) |
| **P0.7: OS PiP window closes on vout swap** | Unknown (that's the point) | Channel-zap UX degraded; M–L mechanism work; worst case libVLC controller reuse | Validate-first on hardware (matrix a) before any design commitment; auto-resume design pre-sketched |
| **Private KVC surface (`avPipController`, `stateChangeEventHandler`) shifts in a future libVLC bump** | Low (binary pinned) | Native PiP hook silently downgrades | Existing `respondsToSelector` guards degrade gracefully; re-run matrix (c) per pin; v0.10 bumps nothing |
| **libVLC-4 demuxer behavior on timeshift/catch-up** (`set_position` with unknown duration is a runtime property) | Medium | P0.1 incomplete for catch-up content | Matrix item (f) against a real stream gates the item's acceptance; lenient API returns `false` rather than misbehaving |
| **Simulator PiP blindness** | Certain | All PiP acceptance is device-only; CI proves compile + non-PiP logic only | M5 harness institutionalizes the device pass; manual matrix recorded per release |
| **`.unbounded` event streams under a wedged consumer** | Low | Memory growth | Documented caveat; default stays `.newest(64)`; internal consumer yields per event |
| **`.endReached` false positive/negative regressions** | Low after design corrections | Permanent consumer-side effects (mark-watched) | The seven-test matrix in §3.3 (incl. stale-flag, error-latch, list-player cases) on macOS + tvOS CI |
| **Dynamic-intermediary topology double-links the static archive** (or automatic-type resolves statically into every consumer) | Medium | Adoption through layered app architectures blocked; duplicate ObjC classes / duplicate plugin registries are UB in the casting/PiP machinery | §3.14 fixture runs in M0 with a single-copy assertion; a product/linkage fix becomes in-scope on failure |
| **Background audio stalls when the vout is starved without PiP** | Unknown (runtime property) | Lock-screen / Now-Playing UX dies on tvOS and on every PiP-off iOS path | §3.15 is release-gating: matrix (e) on hardware, in-scope fix on failure — the release does not ship with it unresolved |
| **Effort estimates are desk estimates** for the PiP tier | Medium | Schedule | Re-estimate M4 after the spike + device matrix, per plan |

---

## 6. Out of scope / deferred

### 6.1 Roadmap items deferred (with the reasons they don't gate v0.10)

| Item | Why deferred |
|---|---|
| Watch-time/time-point interpolation API (`libvlc_media_player_watch_time`, unwrapped) | `timeChanged` + M1 filtering suffice for correctness; M/L item; pairs with a later PiP CMTimebase retrofit (`PiPController.swift` timebase resync) |
| RendererDiscoverer snapshot array | Consumers can accumulate from `events` (`RendererItem` is refcounted); flag: would ease harness screen (d′) — promote only if the harness build finds it painful |
| Codec description / `remainingTime` / profile+level | UI conveniences, trivially derivable (`Track.codec` FourCC + `currentTime`/`duration` are public); the §3.16 porting guide documents the derivations |
| Video crop group | Escalation conditional on `display_fit`-based `.fill` (`Player.swift:948-949`) proving insufficient — fold the check into harness smoke screens; promote on failure only |
| Live-PiP control-surface override (`requiresLinearPlayback`-style) | Only bites when libVLC misreports seekability; gated on matrix (f) results — re-evaluate after the harness runs |
| Renderer×PiP unavailability-reason API | The single v0.10 obligation — define recast-while-PiP — is in §3.4/§3.12; the full reason enum defers |
| Per-slice plugin matrix (full), per-platform binary targets | Deferred; v0.10 ships the tvOS renderer-impotence doc note + the optional CI manifest assertion. The dynamic-intermediary consumption fixture and the background-audio contract were **promoted into scope** (§3.14, §3.15) |
| tvOS UI-test half of P1.13; tvOS PiP (`AVPictureInPictureController` exists on tvOS; PiP sources are `#if os(iOS) || os(macOS)`-gated) | Post-v0.10 platform work |
| P2 parity long tail (subitems, parse flags, list events, meta-extra, file-stat, node media, duplicate, index(of:), tracklist-by-type, wait-for-length) and P3 long tail (except P3.1, promoted) | No overlap with v0.10 files; none touch playback/casting/PiP correctness |

### 6.2 Audit rows: fix-later (not in v0.10)

F002 (#35) · F007 (#39) · F008 · F010 (#40) · F012 · F013 · F015 (#41) · F016 · F018 · F019 · F020 · F021 · F025 · F028 · F029 · F031 · F038 (#47) · F042 · F051 · F054 · F058 · F059 · F060 · F063 · F065 · F066 · F069 · F070 · F075 · F076 · F077 — real findings with no v0.10 file coupling; schedule post-release. Notes:

- **F004 (#36) was promoted into M1** (§3.1): custom `VLCInstance(arguments:)` is the documented norm for streaming consumers (`--network-caching`/`--http-reconnect`), making the per-instance log-Broadcaster leak recurring, not one-shot.
- **Discretionary cheap add (maintainer call, recommended):** F063 (one-line `MediaDiscoverer.deinit` instance-capture UAF fix, mirroring `RendererDiscoverer`). A one-liner to a CONFIRMED defect; including it costs minutes.
- **Conditional riders, decide during M1:** F012 (per-event snapshot allocation — fold a single-subscriber fast path in **only if** M1's filter-hoist rewrites the fan-out loop anyway; otherwise profile-first, post-v0.10) and F013 (per-tick 5×sync-C-call poll for live streams, `Player+Events.swift:88-94` — the IPTV hot path adjacent to M1/M2 churn; correctness-neutral, so defer is also defensible — flag at M2 review).
- F028's clean fix (event-driven `.lengthChanged` wait) deliberately lands *after* M1 ships the filtered-subscription API it should demonstrate.
- F077 (release.sh glob guard): not in scope (no release cut is part of this plan); carry as a checklist note for whenever a release is cut.

### 6.3 Audit rows: out-of-scope (recorded, no action in any near release)

Docs/idiom-only or paths v0.10 does not touch: F006 · F026 · F027 · F030 · F032 · F033 · F035 · F039 · F040 · F045 (#49) · F046 · F047 · F048 · F049 · F050 · F053 · F055 · F056 · F057 · F062 · F064 · F067 · F068 · F071 · F072 · F073 · F078 · F079 · F080 · F081 · F082 · F083. Standing constraints carried forward: **F057** — the dual lock-side comment documenting the vmem Prepare→Display 1:1 retain contract must land before any future libVLC bump (v0.10 bumps none); **F062** — re-evaluate the `pipMainActorSync` invariant if the P0.6 spike installs a delegate proxy (written into the spike exit criteria, §3.9). Issue #16 (HDR10/HLG investigation) is independent exploratory work, not release-gating.

---

## Appendix — effort summary

| Milestone | Items | Effort |
|---|---|---|
| M0 | F036, F041+F074, P1.13-unit, optional P2.19-CI, §3.14 topology fixture | S+M+M (+S) + S–M |
| M1 | P2.14 + F001/F004/F009/F037/F023 | M + 3×XS + S + XS |
| M2 | P1.10, P0.2, P0.3 + F003/F005/F022/F024/F043/F044/F052/F034 | M+M+(S–M) + S+S+4×XS+2×S |
| M3 | P0.1(+P3.1,F017), P0.4(+P1.8), P0.5, P1.1, §3.16 Volume + porting guide | S+2×XS, S+S, S, S, XS+S |
| M4 | P0.6 spike → P0.6, P0.7, P1.11+P2.16, P1.12, F061 | spike → M or L+; S or M–L; S+S; S–M; XS |
| M5 | Harness (7 matrix screens + 4 smoke screens + config plumbing) + §3.15 contract | M + doc-S (fix-M on failure) |

PiP-tier estimates are desk estimates by explicit policy — re-estimate after the spike and the first full device matrix pass.

*End of plan.*
