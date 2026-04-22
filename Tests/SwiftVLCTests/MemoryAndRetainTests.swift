@testable import SwiftVLC
import Foundation
import Synchronization
import Testing

/// Weak-reference probes that assert every SwiftVLC type deallocates
/// deterministically when its last strong reference is dropped.
///
/// Complements `LifecycleStressTests`, which exercises rapid
/// create/destroy without leaks being observable. Here we pin a *weak*
/// reference to each type, drop the strong reference, and assert the
/// weak reference goes to nil — the canonical "did Swift deinit run"
/// test. If a retain cycle, a stray strong capture in an event
/// callback, or a continuation holds onto the instance, the weak
/// reference stays valid and the test fails.
///
/// Offloaded C-level cleanup (via `DispatchQueue.global(qos: .utility)`)
/// is deliberately *not* what these tests measure. Those tests live in
/// `LifecycleStressTests`. Here we only care that Swift's side of the
/// ownership graph is clean.
///
/// Tests that exercise lifecycle paths sensitive to cross-test state
/// (Player, Equalizer, VLCInstance, DialogHandler) use
/// `TestInstance.makeAudioOnly()` for isolation. Tests that only
/// allocate lightweight types or probe service discovery use
/// `TestInstance.shared` to skip the per-test instance cost. Serial
/// (`.serialized`) serializes the tests within this suite.
@Suite(
  .tags(.integration, .mainActor, .async),
  .timeLimit(.minutes(2)),
  .serialized
)
@MainActor
struct MemoryAndRetainTests {
  // MARK: - Player

  /// Baseline: drop a player, yield the scheduler, confirm the weak
  /// reference clears. Regression guard for the event consumer `Task`
  /// strong-capturing `self` (it must capture weakly — see
  /// `Player.startEventConsumer`).
  @Test
  func `Player deallocates when last strong reference drops`() async {
    weak var weakPlayer: Player?
    do {
      let player = Player(instance: TestInstance.makeAudioOnly())
      weakPlayer = player
      _ = player.state
    }
    // Allow the event consumer Task to observe cancellation and release
    // its weak capture — a single yield is usually enough but we give
    // the scheduler a few extra ticks for the observation graph.
    await yieldScheduler(times: 8)
    #expect(weakPlayer == nil, "Player leaked — event consumer task or observation graph retained self")
  }

  /// The raw event stream is an independent continuation surface. Dropping
  /// the stream must not hold the player alive, and dropping the player
  /// must finish the stream so consumers don't wait forever.
  @Test
  func `Dropping player with live event stream releases player`() async {
    weak var weakPlayer: Player?
    let stream: AsyncStream<PlayerEvent>
    do {
      let player = Player(instance: TestInstance.makeAudioOnly())
      weakPlayer = player
      stream = player.events
    }
    await yieldScheduler(times: 8)
    #expect(weakPlayer == nil, "Player retained by its own event stream")

    // And the stream must terminate in finite time now that the bridge
    // was invalidated. Race against a 3s ceiling.
    let drained = Mutex(false)
    await withTaskGroup(of: Void.self) { group in
      group.addTask { @Sendable in
        for await _ in stream {}
        drained.withLock { $0 = true }
      }
      group.addTask { @Sendable in
        try? await Task.sleep(for: .seconds(3))
      }
      _ = await group.next()
      group.cancelAll()
    }
    #expect(drained.withLock { $0 }, "Event stream did not finish within 3s after player drop")
  }

  /// Consumer holding the stream must not keep the player alive. The stream
  /// is backed by a continuation inside an `Unmanaged`-retained store, but
  /// the store is owned by the `EventBridge`, not the player's strong graph.
  @Test
  func `Consumer task holding stream does not retain player`() async {
    weak var weakPlayer: Player?
    var consumer: Task<Void, Never>?
    do {
      let player = Player(instance: TestInstance.makeAudioOnly())
      weakPlayer = player
      let stream = player.events
      consumer = Task.detached { @Sendable in
        for await _ in stream {}
      }
    }
    await yieldScheduler(times: 8)
    #expect(weakPlayer == nil, "Consumer task retained the player through the event stream")
    consumer?.cancel()
  }

  // MARK: - Media

  @Test
  func `Media deallocates when last strong reference drops`() throws {
    weak var weakMedia: Media?
    do {
      let media = try Media(url: TestMedia.testMP4URL)
      weakMedia = media
    }
    #expect(weakMedia == nil, "Media leaked")
  }

  /// Player.load takes `sending Media`, but the player retains the media
  /// for as long as it's the `currentMedia`. Replacing currentMedia with
  /// another media must release the old one.
  @Test
  func `Replacing player's currentMedia releases the prior media`() throws {
    let player = Player(instance: TestInstance.makeAudioOnly())
    weak var weakFirst: Media?
    do {
      let first = try Media(url: TestMedia.testMP4URL)
      weakFirst = first
      player.load(first)
    }
    // First media is still current, so still retained.
    #expect(weakFirst != nil)

    let second = try Media(url: TestMedia.twosecURL)
    player.load(second)
    // First media should now be free.
    #expect(weakFirst == nil, "Player retained the prior media after a new load()")
  }

  // MARK: - MediaList

  @Test
  func `MediaList deallocates when last strong reference drops`() {
    weak var weakList: MediaList?
    do {
      let list = MediaList()
      weakList = list
    }
    #expect(weakList == nil, "MediaList leaked")
  }

  /// `MediaList.withLocked` hands out a `LockedView` scoped to the closure.
  /// The view is `~Escapable` so it cannot outlive the scope — but we
  /// also want to confirm the lock is released and the list deallocates
  /// normally afterwards.
  @Test
  func `MediaList deallocates after withLocked scope`() throws {
    weak var weakList: MediaList?
    do {
      let list = MediaList()
      weakList = list
      try list.append(Media(url: TestMedia.testMP4URL))
      list.withLocked { view in
        #expect(view.count == 1)
      }
    }
    #expect(weakList == nil, "withLocked scope retained the list")
  }

  // MARK: - MediaListPlayer

  @Test
  func `MediaListPlayer deallocates when last strong reference drops`() {
    weak var weakListPlayer: MediaListPlayer?
    do {
      let listPlayer = MediaListPlayer(instance: TestInstance.makeAudioOnly())
      weakListPlayer = listPlayer
    }
    #expect(weakListPlayer == nil, "MediaListPlayer leaked")
  }

  /// `MediaListPlayer` holds its `Player` via a strong `_mediaPlayer`
  /// reference. Dropping the list player must release the player too —
  /// otherwise a MediaListPlayer ↔ Player retain cycle would leak both.
  @Test
  func `MediaListPlayer does not retain its Player cyclically`() async {
    weak var weakListPlayer: MediaListPlayer?
    weak var weakPlayer: Player?
    do {
      let listPlayer = MediaListPlayer(instance: TestInstance.makeAudioOnly())
      let player = Player(instance: TestInstance.makeAudioOnly())
      listPlayer.mediaPlayer = player
      weakListPlayer = listPlayer
      weakPlayer = player
    }
    await yieldScheduler(times: 8)
    #expect(weakListPlayer == nil, "MediaListPlayer leaked")
    #expect(weakPlayer == nil, "Player retained by MediaListPlayer → retain cycle")
  }

  // MARK: - Equalizer

  @Test
  func `Equalizer deallocates when last strong reference drops`() {
    weak var weakEQ: Equalizer?
    do {
      let eq = Equalizer()
      weakEQ = eq
    }
    #expect(weakEQ == nil, "Equalizer leaked")
  }

  /// Attaching an equalizer to a player installs a mutation observer
  /// closure. The closure must capture the player weakly, otherwise
  /// `player.equalizer = eq` creates a retain cycle.
  @Test
  func `Equalizer attached to Player does not create retain cycle`() async {
    weak var weakPlayer: Player?
    weak var weakEQ: Equalizer?
    do {
      let player = Player(instance: TestInstance.makeAudioOnly())
      let eq = Equalizer()
      player.equalizer = eq
      eq.preamp = 5
      weakPlayer = player
      weakEQ = eq
    }
    await yieldScheduler(times: 8)
    #expect(weakPlayer == nil, "Player retained via Equalizer.onChange")
    #expect(weakEQ == nil, "Equalizer leaked")
  }

  /// Clearing `player.equalizer = nil` detaches the mutation observer
  /// immediately. After clearing, a subsequent drop of the player and
  /// the equalizer must both deallocate.
  @Test
  func `Clearing Player.equalizer detaches the onChange handler`() async {
    weak var weakEQ: Equalizer?
    let player = Player(instance: TestInstance.makeAudioOnly())
    do {
      let eq = Equalizer()
      player.equalizer = eq
      weakEQ = eq
      player.equalizer = nil
    }
    await yieldScheduler(times: 4)
    #expect(weakEQ == nil, "Equalizer retained after player.equalizer = nil")
  }

  // MARK: - DialogHandler

  /// Dialog handlers register themselves with a per-instance handler
  /// registry. Dropping the handler must drop the registry entry too,
  /// otherwise repeatedly creating/destroying handlers against the same
  /// instance grows unbounded memory usage.
  @Test
  func `DialogHandler deallocates when last strong reference drops`() {
    let instance = TestInstance.makeAudioOnly()
    weak var weakHandler: DialogHandler?
    do {
      let handler = DialogHandler(instance: instance)
      weakHandler = handler
      _ = handler.dialogs
    }
    #expect(weakHandler == nil, "DialogHandler leaked")
  }

  // MARK: - Discoverers

  @Test
  func `MediaDiscoverer deallocates when last strong reference drops`() throws {
    guard
      let service = MediaDiscoverer.availableServices(
        category: .lan,
        instance: TestInstance.shared
      ).first else {
      return
    }
    weak var weakDisc: MediaDiscoverer?
    do {
      let disc = try MediaDiscoverer(name: service.name, instance: TestInstance.shared)
      weakDisc = disc
    }
    #expect(weakDisc == nil, "MediaDiscoverer leaked")
  }

  @Test
  func `RendererDiscoverer deallocates when last strong reference drops`() throws {
    guard
      let service = RendererDiscoverer.availableServices(
        instance: TestInstance.shared
      ).first else {
      return
    }
    weak var weakDisc: RendererDiscoverer?
    do {
      let disc = try RendererDiscoverer(name: service.name, instance: TestInstance.shared)
      weakDisc = disc
      _ = disc.events
    }
    #expect(weakDisc == nil, "RendererDiscoverer leaked")
  }

  // MARK: - VLCInstance

  /// A bespoke `VLCInstance` should deinit when dropped — verifies our
  /// `LogBroadcaster.invalidate()` tear-down doesn't leave a strong
  /// reference through the retained callback box.
  @Test
  func `Custom VLCInstance deallocates when dropped`() {
    weak var weakInstance: VLCInstance?
    do {
      let instance = TestInstance.makeAudioOnly()
      weakInstance = instance
    }
    #expect(weakInstance == nil, "VLCInstance leaked")
  }

  /// Opening and closing a logStream must not retain the instance beyond
  /// the lifetime of that stream. Regression guard for the
  /// `LogBroadcaster` reconcile path not leaking a retained `self`.
  @Test
  func `VLCInstance deallocates even with logStream created and dropped`() async {
    weak var weakInstance: VLCInstance?
    do {
      let instance = TestInstance.makeAudioOnly()
      weakInstance = instance
      let stream = instance.logStream(minimumLevel: .error)
      let task = Task.detached { @Sendable in
        for await _ in stream {}
      }
      task.cancel()
      _ = await task.value
    }
    // LogBroadcaster install/uninstall is bounced through a serial queue.
    // 200ms is generous for a simple install→uninstall round-trip.
    try? await Task.sleep(for: .milliseconds(200))
    #expect(weakInstance == nil, "VLCInstance leaked through logStream install path")
  }

  // MARK: - Heavy churn without unbounded growth

  /// The headline stability proof: 500 full Player lifecycles through
  /// create → event-stream subscribe → drop, all on a single instance.
  /// A `WeakProbes` tracker holds a weak reference per iteration; if
  /// any link of the ownership chain (event consumer task, observation
  /// graph, stream continuation) retained strongly, undead Players
  /// would remain in the tracker and `aliveCount()` would be non-zero.
  @Test
  func `Five hundred Player lifecycles do not accumulate undead instances`() async {
    let instance = TestInstance.makeAudioOnly()
    let probes = WeakProbes<Player>()

    for _ in 0..<500 {
      autoreleasepool {
        let player = Player(instance: instance)
        probes.add(player)
        _ = player.events
      }
    }

    // Each Player's event-consumer Task captures `self` weakly and must
    // resume once past its cancellation check to release the stream.
    await yieldScheduler(times: 32)
    let alive = probes.aliveCount()
    #expect(alive == 0, "\(alive) Players leaked out of 500")
  }

  /// Same shape as the Player churn test, but for Media. Media has a
  /// synchronous deinit (no offload), so this is a tighter check.
  @Test
  func `One thousand Media lifecycles do not accumulate undead instances`() throws {
    let probes = WeakProbes<Media>()
    for _ in 0..<1000 {
      try autoreleasepool {
        let media = try Media(url: TestMedia.testMP4URL)
        probes.add(media)
      }
    }
    let alive = probes.aliveCount()
    #expect(alive == 0, "\(alive) Media leaked out of 1000")
  }

  /// Churn the Equalizer + Player pair so the onChange handler install /
  /// uninstall path is hit repeatedly. If `player.equalizer = nil` (the
  /// handler-clearing path) ever leaves a strong reference behind, this
  /// surfaces as undead Equalizers.
  @Test
  func `Player equalizer install-clear churn does not accumulate Equalizers`() async {
    let player = Player(instance: TestInstance.makeAudioOnly())
    let probes = WeakProbes<Equalizer>()
    for _ in 0..<200 {
      autoreleasepool {
        let eq = Equalizer()
        probes.add(eq)
        player.equalizer = eq
        eq.preamp = Float.random(in: -10...10)
        player.equalizer = nil
      }
    }
    await yieldScheduler(times: 16)
    let alive = probes.aliveCount()
    #expect(alive == 0, "\(alive) Equalizers leaked out of 200")
  }

  // MARK: - Helpers

  /// Yields the task scheduler `n` times so pending main-actor tasks
  /// (deinit cleanup, event-consumer cancellation, observation graph
  /// teardown) get a chance to run before we probe the weak reference.
  private func yieldScheduler(times n: Int) async {
    for _ in 0..<n {
      await Task.yield()
    }
  }
}

/// Tracks multiple weak references to a reference type so a churn loop
/// can ask "did everything I created deallocate?" without drowning in
/// individual `weak var` bindings.
///
/// Entries that have already deallocated are lazily pruned from the
/// backing array on every `aliveCount()` call so the storage doesn't
/// grow unbounded in long-running tests.
///
/// Used only from the main actor — no `Sendable` conformance needed.
@MainActor
private final class WeakProbes<T: AnyObject> {
  private struct Probe {
    weak var object: T?
  }

  private var probes: [Probe] = []

  func add(_ object: T) {
    probes.append(Probe(object: object))
  }

  func aliveCount() -> Int {
    probes = probes.filter { $0.object != nil }
    return probes.count
  }
}
