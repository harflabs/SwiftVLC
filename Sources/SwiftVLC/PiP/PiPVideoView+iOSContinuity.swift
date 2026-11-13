#if os(iOS)
import Dispatch
import Synchronization

/// The immutable player/media pair copied into one native PiP output.
struct IOSNativePiPPlaybackBinding: Hashable, Sendable {
  let nativeHandle: UInt64
  let playbackGeneration: PlaybackGeneration

  var isValid: Bool {
    nativeHandle != 0 && playbackGeneration.value != 0
  }
}

/// Complete immutable provenance for one native PiP output.
///
/// Several vouts can overlap on the same handle and playback generation. The
/// process-monotonic output value prevents a delayed output from borrowing a
/// successor's handoff or readiness decision.
struct IOSNativePiPOutputIdentity: Hashable, Sendable {
  let binding: IOSNativePiPPlaybackBinding
  let output: UInt64

  init(
    nativeHandle: UInt64,
    playbackGeneration: PlaybackGeneration,
    output: UInt64
  ) {
    binding = IOSNativePiPPlaybackBinding(
      nativeHandle: nativeHandle,
      playbackGeneration: playbackGeneration
    )
    self.output = output
  }

  var isValid: Bool {
    binding.isValid && output != 0 && output != .max
  }
}

/// Thread-safe, single-owner transfer of an active AVKit PiP controller.
///
/// Native v9 callers identify every operation with values captured before the
/// PiP module opens. A shared media-controller snapshot is never consulted.
final class IOSNativePiPContinuityCoordinator: @unchecked Sendable {
  private final class WeakController: @unchecked Sendable {
    weak var value: AnyObject?

    init(_ value: AnyObject) {
      self.value = value
    }
  }

  enum Transition: Sendable {
    case rebuilding(previous: PlaybackGeneration, successor: PlaybackGeneration)
    case restored(
      previous: PlaybackGeneration,
      successor: PlaybackGeneration,
      elapsed: Duration
    )
    case timedOut(
      previous: PlaybackGeneration,
      successor: PlaybackGeneration,
      elapsed: Duration
    )
  }

  enum PreservedControllerTakeOutcome: @unchecked Sendable {
    case preserved(AnyObject)
    case createFresh
    case superseded
  }

  /// Reserves delivery order while invoking client code outside the state lock.
  private final class OrderedTransitionEmitter: @unchecked Sendable {
    private struct State: Sendable {
      var queued: [Transition] = []
      var isDraining = false
    }

    private let state = Mutex(State())
    private let emit: @Sendable (Transition) -> Void

    init(emit: @escaping @Sendable (Transition) -> Void) {
      self.emit = emit
    }

    func enqueue(_ transition: Transition) -> Bool {
      state.withLock { state in
        state.queued.append(transition)
        guard !state.isDraining else { return false }
        state.isDraining = true
        return true
      }
    }

    func drain() {
      while true {
        let transition = state.withLock { state -> Transition? in
          guard !state.queued.isEmpty else {
            state.isDraining = false
            return nil
          }
          return state.queued.removeFirst()
        }
        guard let transition else { return }
        emit(transition)
      }
    }
  }

  private struct Ready: @unchecked Sendable {
    let controllerIdentity: ObjectIdentifier
    let weakController: WeakController
    let output: IOSNativePiPOutputIdentity
  }

  private struct Pending: @unchecked Sendable {
    let controllerIdentity: ObjectIdentifier
    let weakController: WeakController
    var controller: AnyObject?
    let previous: IOSNativePiPOutputIdentity
    var target: IOSNativePiPPlaybackBinding
    var preservedBy: IOSNativePiPOutputIdentity
    var takenBy: IOSNativePiPOutputIdentity?
    /// Exact native output whose armed CAS token may currently time out.
    /// This is nil while a successor owns the controller between take and
    /// either readiness or its own close/preserve transaction.
    var timeoutOwner: IOSNativePiPOutputIdentity?
    let startedAt: ContinuousClock.Instant
  }

  private struct ExpectedHandoff: @unchecked Sendable {
    let target: IOSNativePiPPlaybackBinding
    let signal: DispatchSemaphore
    var waiters: Set<IOSNativePiPOutputIdentity> = []
  }

  private struct FreshAuthorization: @unchecked Sendable {
    let output: IOSNativePiPOutputIdentity
    var controllerIdentity: ObjectIdentifier?
    var controller: AnyObject?
  }

  private struct State: @unchecked Sendable {
    var ready: Ready?
    var pending: Pending?
    var expected: ExpectedHandoff?
    var freshAuthorization: FreshAuthorization?
    var supersededThroughPlaybackGeneration: PlaybackGeneration?
    var supersededBindings: Set<IOSNativePiPPlaybackBinding> = []
    var supersededOutputs: Set<IOSNativePiPOutputIdentity> = []
    var lastTimedOutController: WeakController?
    var lastTimedOutOutput: IOSNativePiPOutputIdentity?
  }

  private let clock = ContinuousClock()
  private let expectedHandoffWait: DispatchTimeInterval
  private let state = Mutex(State())
  private let transitionEmitter: OrderedTransitionEmitter

  init(
    expectedHandoffWait: DispatchTimeInterval = .milliseconds(750),
    emit: @escaping @Sendable (Transition) -> Void
  ) {
    self.expectedHandoffWait = expectedHandoffWait
    transitionEmitter = OrderedTransitionEmitter(emit: emit)
  }

  /// Stages one exact distinct-handle successor before predecessor release.
  /// Returning false is intentionally fail-closed for same-handle media loads.
  @discardableResult
  func expectHandoff(to successor: IOSNativePiPPlaybackBinding) -> Bool {
    guard successor.isValid else { return false }

    let result = state.withLock { state
      -> (accepted: Bool, displaced: ExpectedHandoff?, shouldDrain: Bool) in
      let sourceHandle = state.pending?.takenBy?.binding.nativeHandle
        ?? state.pending?.preservedBy.binding.nativeHandle
        ?? state.ready?.output.binding.nativeHandle
      guard let sourceHandle, sourceHandle != successor.nativeHandle else {
        return (false, nil, false)
      }

      if let expected = state.expected, expected.target == successor {
        return (true, nil, false)
      }
      if
        let expected = state.expected,
        expected.target.playbackGeneration > successor.playbackGeneration {
        return (false, nil, false)
      }

      let displaced = state.expected
      if let displaced {
        markSuperseded(displaced, before: successor, in: &state)
      }

      var shouldDrain = false
      if var pending = state.pending, pending.target != successor {
        guard pending.target.playbackGeneration <= successor.playbackGeneration else {
          return (false, nil, false)
        }
        markBindingSuperseded(pending.target, before: successor, in: &state)
        pending.target = successor
        state.pending = pending
        shouldDrain = transitionEmitter.enqueue(.rebuilding(
          previous: pending.previous.binding.playbackGeneration,
          successor: successor.playbackGeneration
        ))
      }

      state.expected = ExpectedHandoff(
        target: successor,
        signal: DispatchSemaphore(value: 0)
      )
      return (true, displaced, shouldDrain)
    }

    if result.shouldDrain {
      transitionEmitter.drain()
    }
    wakeWaiters(result.displaced)
    return result.accepted
  }

  /// Preserves only a controller owned by `retiringOutput` for the currently
  /// staged, distinct-handle target. Same-handle rebuilds fail closed.
  func preserve(
    _ controller: AnyObject,
    from retiringOutput: IOSNativePiPOutputIdentity,
    allowsSameGenerationRebuild _: Bool = false
  ) -> Bool {
    guard retiringOutput.isValid else { return false }
    let startedAt = clock.now

    let result = state.withLock { state
      -> (accepted: Bool, expected: ExpectedHandoff?, shouldDrain: Bool) in
      guard let expected = state.expected else {
        return (false, nil, false)
      }

      let target = expected.target
      guard
        target.nativeHandle != retiringOutput.binding.nativeHandle,
        target.playbackGeneration >= retiringOutput.binding.playbackGeneration
      else { return (false, nil, false) }

      if var pending = state.pending {
        // A newer replacement can supersede an output after it has already
        // taken the shared controller but before it prepares. That exact
        // owner must still be allowed to return the controller into the
        // successor chain. No other superseded output gets this exception.
        let exactCurrentOwner = pending.takenBy.map { $0 == retiringOutput }
          ?? (pending.preservedBy == retiringOutput)
        guard
          pending.controllerIdentity == ObjectIdentifier(controller),
          exactCurrentOwner
        else { return (false, nil, false) }

        if pending.target != target {
          guard pending.target.playbackGeneration <= target.playbackGeneration else {
            return (false, nil, false)
          }
          markBindingSuperseded(pending.target, before: target, in: &state)
          pending.target = target
        }
        pending.controller = controller
        pending.preservedBy = retiringOutput
        pending.takenBy = nil
        pending.timeoutOwner = retiringOutput
        state.pending = pending
        return (true, expected, false)
      }

      guard
        !isSuperseded(retiringOutput, in: state),
        let ready = state.ready,
        ready.output == retiringOutput,
        ready.controllerIdentity == ObjectIdentifier(controller)
      else { return (false, nil, false) }

      state.pending = Pending(
        controllerIdentity: ready.controllerIdentity,
        weakController: ready.weakController,
        controller: controller,
        previous: retiringOutput,
        target: target,
        preservedBy: retiringOutput,
        takenBy: nil,
        timeoutOwner: retiringOutput,
        startedAt: startedAt
      )
      let shouldDrain = transitionEmitter.enqueue(.rebuilding(
        previous: retiringOutput.binding.playbackGeneration,
        successor: target.playbackGeneration
      ))
      return (true, expected, shouldDrain)
    }

    if result.shouldDrain {
      transitionEmitter.drain()
    }
    wakeWaiters(result.expected)
    return result.accepted
  }

  func takePreservedController(for output: IOSNativePiPOutputIdentity) -> AnyObject? {
    switch takePreservedControllerOutcome(for: output) {
    case .preserved(let controller): controller
    case .createFresh, .superseded: nil
    }
  }

  func takePreservedControllerOutcome(
    for output: IOSNativePiPOutputIdentity
  ) -> PreservedControllerTakeOutcome {
    guard output.isValid else { return .superseded }

    enum Selection {
      case preserved(PreservedControllerTake)
      case wait(ExpectedHandoff)
      case createFresh
      case superseded
    }

    let selection = state.withLock { state -> Selection in
      guard !isSuperseded(output, in: state) else { return .superseded }

      if let taken = takePreservedControllerIfAvailable(in: &state, for: output) {
        return .preserved(taken)
      }

      if var expected = state.expected {
        guard expected.target == output.binding else {
          state.supersededOutputs.insert(output)
          return .superseded
        }
        expected.waiters.insert(output)
        state.expected = expected
        return .wait(expected)
      }

      // A fresh controller is safe only when there is provably no existing
      // controller owner. An explicit expectation is the sole path by which
      // a distinct-handle successor can take a ready/pending controller.
      if let pending = state.pending {
        if
          pending.previous.binding.nativeHandle == output.binding.nativeHandle
          || pending.preservedBy.binding.nativeHandle == output.binding.nativeHandle
          || pending.takenBy?.binding.nativeHandle == output.binding.nativeHandle
          || pending.target.nativeHandle == output.binding.nativeHandle {
          state.supersededBindings.insert(output.binding)
        }
        state.supersededOutputs.insert(output)
        return .superseded
      }

      if let ready = state.ready {
        // Any second output without an exact staged handoff would create two
        // AVPictureInPictureControllers. When the native handle matches, it
        // additionally proves an unsupported same-handle rebuild/media-list
        // change, so invalidate both immutable bindings on that handle.
        if ready.output.binding.nativeHandle == output.binding.nativeHandle {
          state.supersededBindings.insert(ready.output.binding)
          state.supersededBindings.insert(output.binding)
        }
        state.supersededOutputs.insert(output)
        return .superseded
      }

      if let authorized = state.freshAuthorization {
        guard authorized.output == output else {
          if authorized.output.binding.nativeHandle == output.binding.nativeHandle {
            state.supersededBindings.insert(authorized.output.binding)
            state.supersededBindings.insert(output.binding)
          }
          state.supersededOutputs.insert(output)
          return .superseded
        }
      } else {
        state.freshAuthorization = FreshAuthorization(
          output: output,
          controllerIdentity: nil,
          controller: nil
        )
      }
      return .createFresh
    }

    switch selection {
    case .preserved(let result):
      if result.shouldDrain {
        transitionEmitter.drain()
      }
      return .preserved(result.controller)
    case .createFresh:
      return .createFresh
    case .superseded:
      return .superseded
    case .wait(let expected):
      _ = expected.signal.wait(timeout: .now() + expectedHandoffWait)
      let result = resolveExpectedHandoffAfterWait(expected, for: output)
      if result.shouldDrain {
        transitionEmitter.drain()
      }
      return result.outcome
    }
  }

  /// Binds the sole fresh-controller authorization to the exact Objective-C
  /// controller before native code can publish it or begin asynchronous
  /// preparation. A rejected claim has no state side effects.
  @discardableResult
  func didClaimFreshController(
    _ controller: AnyObject,
    output: IOSNativePiPOutputIdentity
  ) -> Bool {
    guard output.isValid else { return false }
    return state.withLock { state in
      let identity = ObjectIdentifier(controller)
      guard !isSuperseded(output, in: state) else { return false }

      if var pending = state.pending {
        guard
          pending.controllerIdentity == identity,
          pending.takenBy == output
        else { return false }
        pending.timeoutOwner = output
        state.pending = pending
        return true
      }

      guard
        var authorization = state.freshAuthorization,
        authorization.output == output
      else { return false }
      if let existing = authorization.controllerIdentity {
        return existing == identity
      }
      authorization.controllerIdentity = identity
      authorization.controller = controller
      state.freshAuthorization = authorization
      return true
    }
  }

  /// Rolls back only an output reservation that never acquired a controller.
  /// Used when native allocation/initialization fails before the exact claim.
  @discardableResult
  func rollbackUnclaimedFreshController(
    output: IOSNativePiPOutputIdentity
  ) -> Bool {
    guard output.isValid else { return false }
    return state.withLock { state in
      guard
        let authorization = state.freshAuthorization,
        authorization.output == output,
        authorization.controllerIdentity == nil
      else { return false }
      state.freshAuthorization = nil
      return true
    }
  }

  func isCurrentReady(
    _ controller: AnyObject,
    output: IOSNativePiPOutputIdentity
  ) -> Bool {
    guard output.isValid else { return false }
    return state.withLock { state in
      guard !isSuperseded(output, in: state), let ready = state.ready else {
        return false
      }
      return ready.output == output
        && ready.controllerIdentity == ObjectIdentifier(controller)
    }
  }

  /// Coherently snapshots the one output that has completed exact native
  /// claim and readiness. A weakly expired controller or superseded binding
  /// is not evidence of a live output and therefore returns nil.
  func currentReadyOutputIdentity() -> IOSNativePiPOutputIdentity? {
    state.withLock { state in
      guard
        let ready = state.ready,
        ready.weakController.value != nil,
        !isSuperseded(ready.output, in: state)
      else { return nil }
      return ready.output
    }
  }

  /// Permanently retires every output binding copied from one native handle.
  /// Used when libVLC changes media internally on the same handle and can
  /// reuse the existing vout, making the frozen playback generation stale.
  @discardableResult
  func retireBindings(forNativeHandle nativeHandle: UInt64) -> Bool {
    !retireControllers(forNativeHandle: nativeHandle).isEmpty
  }

  /// Atomically invalidates and removes every coordinator owner associated
  /// with one native handle, returning the exact controllers the caller must
  /// close after the state lock is released. This is the fail-closed path for
  /// media-list navigation that can keep rendering through the same vout.
  func retireControllers(forNativeHandle nativeHandle: UInt64) -> [AnyObject] {
    guard nativeHandle != 0 else { return [] }
    let result = state.withLock { state
      -> (controllers: [AnyObject], wake: ExpectedHandoff?) in
      var bindings: Set<IOSNativePiPPlaybackBinding> = []
      var controllers: [AnyObject] = []
      if let ready = state.ready, ready.output.binding.nativeHandle == nativeHandle {
        bindings.insert(ready.output.binding)
        if let controller = ready.weakController.value {
          controllers.append(controller)
        }
        state.ready = nil
      }
      if let pending = state.pending {
        let candidates = [
          pending.previous.binding,
          pending.target,
          pending.preservedBy.binding,
          pending.takenBy?.binding
        ]
        let matchingBindings = candidates.compactMap(\.self).filter {
          $0.nativeHandle == nativeHandle
        }
        for binding in matchingBindings {
          bindings.insert(binding)
        }
        if !matchingBindings.isEmpty {
          if let controller = pending.controller {
            controllers.append(controller)
          } else if let controller = pending.weakController.value {
            controllers.append(controller)
          }
          state.pending = nil
        }
      }
      if
        let authorization = state.freshAuthorization,
        authorization.output.binding.nativeHandle == nativeHandle {
        bindings.insert(authorization.output.binding)
        if let controller = authorization.controller {
          controllers.append(controller)
        }
        state.freshAuthorization = nil
      }
      var wake: ExpectedHandoff?
      if
        let expected = state.expected,
        expected.target.nativeHandle == nativeHandle {
        bindings.insert(expected.target)
        wake = expected
        state.expected = nil
      }
      state.supersededBindings.formUnion(bindings)
      var seen: Set<ObjectIdentifier> = []
      let uniqueControllers = controllers.filter {
        seen.insert(ObjectIdentifier($0)).inserted
      }
      return (uniqueControllers, wake)
    }
    wakeWaiters(result.wake)
    return result.controllers
  }

  /// Accepts readiness only for the exact output that took the preserved
  /// controller or won the sole fresh-controller authorization.
  @discardableResult
  func didBecomeReady(
    _ controller: AnyObject,
    output: IOSNativePiPOutputIdentity
  ) -> Bool {
    guard output.isValid else { return false }
    let now = clock.now
    let result = state.withLock { state -> (accepted: Bool, shouldDrain: Bool) in
      guard !isSuperseded(output, in: state) else { return (false, false) }

      if let pending = state.pending {
        guard
          pending.controllerIdentity == ObjectIdentifier(controller),
          pending.target == output.binding,
          pending.takenBy == output
        else { return (false, false) }

        state.pending = nil
        clearExpectedHandoff(in: &state, matching: output.binding)
        state.freshAuthorization = nil
        state.ready = Ready(
          controllerIdentity: pending.controllerIdentity,
          weakController: pending.weakController,
          output: output
        )
        return (
          true,
          transitionEmitter.enqueue(.restored(
            previous: pending.previous.binding.playbackGeneration,
            successor: pending.target.playbackGeneration,
            elapsed: pending.startedAt.duration(to: now)
          ))
        )
      }

      if let ready = state.ready, ready.output == output {
        return (ready.controllerIdentity == ObjectIdentifier(controller), false)
      }
      guard
        let authorization = state.freshAuthorization,
        authorization.output == output,
        authorization.controllerIdentity == ObjectIdentifier(controller)
      else { return (false, false) }
      if
        state.lastTimedOutOutput == output,
        state.lastTimedOutController?.value === controller {
        return (false, false)
      }

      state.freshAuthorization = nil
      state.ready = Ready(
        controllerIdentity: ObjectIdentifier(controller),
        weakController: WeakController(controller),
        output: output
      )
      state.lastTimedOutController = nil
      state.lastTimedOutOutput = nil
      return (true, false)
    }
    if result.shouldDrain {
      transitionEmitter.drain()
    }
    return result.accepted
  }

  /// Clears a taken-but-unprepared handoff or a rejected ready callback. The
  /// exact output match prevents an old close from clearing its successor.
  func didCancel(
    _ controller: AnyObject,
    output: IOSNativePiPOutputIdentity
  ) {
    guard output.isValid else { return }
    let now = clock.now
    let result = state.withLock { state
      -> (expected: ExpectedHandoff?, shouldDrain: Bool) in
      if
        let ready = state.ready,
        ready.output == output,
        ready.controllerIdentity == ObjectIdentifier(controller) {
        // Only this exact output is retired. The cancel is the proof that its
        // controller is closed, so a later output of the same handle and
        // media may create a fresh one: libVLC reopens the display on the
        // same player whenever the stream changes resolution. Retiring the
        // whole binding here left PiP unavailable for the rest of the media.
        // Media changes the output identity cannot see are retired explicitly
        // through `retireControllers(forNativeHandle:)`.
        state.supersededOutputs.insert(output)
        state.ready = nil
        return (nil, false)
      }
      if
        let authorization = state.freshAuthorization,
        authorization.output == output,
        authorization.controllerIdentity == ObjectIdentifier(controller) {
        state.supersededOutputs.insert(output)
        state.freshAuthorization = nil
        return (nil, false)
      }

      guard
        let pending = state.pending,
        pending.controllerIdentity == ObjectIdentifier(controller),
        pending.takenBy == output || pending.timeoutOwner == output
      else { return (nil, false) }

      state.supersededOutputs.insert(output)
      state.supersededBindings.insert(output.binding)
      state.pending = nil
      let expected = removeExpectedHandoff(in: &state, matching: pending.target)
      state.lastTimedOutController = pending.weakController
      state.lastTimedOutOutput = output
      return (
        expected,
        transitionEmitter.enqueue(.timedOut(
          previous: pending.previous.binding.playbackGeneration,
          successor: pending.target.playbackGeneration,
          elapsed: pending.startedAt.duration(to: now)
        ))
      )
    }
    if result.shouldDrain {
      transitionEmitter.drain()
    }
    wakeWaiters(result.expected)
  }

  /// Completes only the timeout owned by `output`'s native CAS token.
  func didTimeOut(
    _ controller: AnyObject,
    output: IOSNativePiPOutputIdentity
  ) {
    guard output.isValid else { return }
    let now = clock.now
    let result = state.withLock { state
      -> (expected: ExpectedHandoff?, shouldDrain: Bool) in
      let controllerIdentity = ObjectIdentifier(controller)
      if
        let authorization = state.freshAuthorization,
        authorization.output == output,
        authorization.controllerIdentity == controllerIdentity {
        state.freshAuthorization = nil
        state.supersededOutputs.insert(output)
        state.supersededBindings.insert(output.binding)
        return (nil, false)
      }

      guard
        let pending = state.pending,
        pending.controllerIdentity == controllerIdentity,
        pending.timeoutOwner == output
      else { return (nil, false) }

      state.pending = nil
      state.supersededOutputs.insert(output)
      let expected = removeExpectedHandoff(in: &state, matching: pending.target)
      state.lastTimedOutController = pending.weakController
      state.lastTimedOutOutput = output
      return (
        expected,
        transitionEmitter.enqueue(.timedOut(
          previous: pending.previous.binding.playbackGeneration,
          successor: pending.target.playbackGeneration,
          elapsed: pending.startedAt.duration(to: now)
        ))
      )
    }
    if result.shouldDrain {
      transitionEmitter.drain()
    }
    wakeWaiters(result.expected)
  }

  private struct PreservedControllerTake {
    let controller: AnyObject
    let shouldDrain: Bool
  }

  private struct ExpectedHandoffResolution {
    let outcome: PreservedControllerTakeOutcome
    let shouldDrain: Bool
  }

  private func takePreservedControllerIfAvailable(
    in state: inout State,
    for output: IOSNativePiPOutputIdentity
  ) -> PreservedControllerTake? {
    guard
      var pending = state.pending,
      pending.target == output.binding,
      pending.takenBy == nil,
      let controller = pending.controller
    else { return nil }

    // Retain across the native take -> rebind -> synchronous ready window.
    // A returned autoreleased Objective-C value is not a lifetime contract,
    // and pre-prepare cancellation must still be able to identify/release the
    // exact controller deterministically.
    pending.takenBy = output
    pending.timeoutOwner = nil
    state.pending = pending
    if let expected = removeExpectedHandoff(in: &state, matching: output.binding) {
      for waiter in expected.waiters where waiter != output {
        state.supersededOutputs.insert(waiter)
      }
      wakeWaiters(expected)
    }
    state.freshAuthorization = nil
    return PreservedControllerTake(controller: controller, shouldDrain: false)
  }

  private func resolveExpectedHandoffAfterWait(
    _ expected: ExpectedHandoff,
    for output: IOSNativePiPOutputIdentity
  ) -> ExpectedHandoffResolution {
    state.withLock { state in
      guard
        state.expected?.signal === expected.signal,
        state.expected?.target == output.binding
      else {
        return ExpectedHandoffResolution(outcome: .superseded, shouldDrain: false)
      }

      if let taken = takePreservedControllerIfAvailable(in: &state, for: output) {
        return ExpectedHandoffResolution(
          outcome: .preserved(taken.controller),
          shouldDrain: taken.shouldDrain
        )
      }

      // A wait deadline is not evidence that the predecessor disappeared.
      // Keep its expectation/pending ownership intact and fail this exact
      // output closed; a later output may retry after native close/preserve
      // or exact cancellation proves that no controller remains.
      if state.ready != nil || state.pending != nil {
        if
          var current = state.expected,
          current.signal === expected.signal,
          current.target == output.binding {
          current.waiters.remove(output)
          state.expected = current
        }
        state.supersededOutputs.insert(output)
        return ExpectedHandoffResolution(
          outcome: .superseded,
          shouldDrain: false
        )
      }

      let current = state.expected
      state.expected = nil
      if let current {
        for waiter in current.waiters where waiter != output {
          state.supersededOutputs.insert(waiter)
        }
        wakeWaiters(current)
      }

      var shouldDrain = false
      if let pending = state.pending, pending.target == output.binding {
        state.pending = nil
        state.lastTimedOutController = pending.weakController
        state.lastTimedOutOutput = output
        shouldDrain = transitionEmitter.enqueue(.timedOut(
          previous: pending.previous.binding.playbackGeneration,
          successor: pending.target.playbackGeneration,
          elapsed: pending.startedAt.duration(to: clock.now)
        ))
      }
      state.freshAuthorization = FreshAuthorization(
        output: output,
        controllerIdentity: nil,
        controller: nil
      )
      return ExpectedHandoffResolution(outcome: .createFresh, shouldDrain: shouldDrain)
    }
  }

  private func isSuperseded(
    _ output: IOSNativePiPOutputIdentity,
    in state: State
  ) -> Bool {
    // A compact generation watermark rejects callbacks from displaced
    // successors, but it must never consume the exact predecessor that still
    // owns the shared controller. In A -> B -> C, superseding B advances the
    // watermark past A even though A remains the sole Ready owner until its
    // close/preserve transaction. Exact invalidation sets below still win for
    // fail-closed same-handle media changes.
    let isCurrentOwner = state.ready?.output == output
      || state.pending?.previous == output
      || state.pending?.preservedBy == output
      || state.pending?.takenBy == output
      || state.freshAuthorization?.output == output
    if
      !isCurrentOwner,
      let through = state.supersededThroughPlaybackGeneration,
      output.binding.playbackGeneration <= through {
      return true
    }
    return state.supersededBindings.contains(output.binding)
      || state.supersededOutputs.contains(output)
  }

  private func markSuperseded(
    _ expected: ExpectedHandoff,
    before successor: IOSNativePiPPlaybackBinding,
    in state: inout State
  ) {
    markBindingSuperseded(expected.target, before: successor, in: &state)
    state.supersededOutputs.formUnion(expected.waiters)
  }

  private func markBindingSuperseded(
    _ binding: IOSNativePiPPlaybackBinding,
    before successor: IOSNativePiPPlaybackBinding,
    in state: inout State
  ) {
    if binding.playbackGeneration < successor.playbackGeneration {
      if
        state.supersededThroughPlaybackGeneration.map({
          binding.playbackGeneration > $0
        }) ?? true {
        state.supersededThroughPlaybackGeneration = binding.playbackGeneration
      }
      state.supersededBindings = state.supersededBindings.filter {
        $0.playbackGeneration > binding.playbackGeneration
      }
      state.supersededOutputs = state.supersededOutputs.filter {
        $0.binding.playbackGeneration > binding.playbackGeneration
      }
    } else {
      state.supersededBindings.insert(binding)
    }
  }

  private func clearExpectedHandoff(
    in state: inout State,
    matching target: IOSNativePiPPlaybackBinding
  ) {
    if let expected = removeExpectedHandoff(in: &state, matching: target) {
      wakeWaiters(expected)
    }
  }

  private func removeExpectedHandoff(
    in state: inout State,
    matching target: IOSNativePiPPlaybackBinding
  ) -> ExpectedHandoff? {
    guard let expected = state.expected, expected.target == target else {
      return nil
    }
    state.expected = nil
    return expected
  }

  private func wakeWaiters(_ expected: ExpectedHandoff?) {
    guard let expected else { return }
    for _ in expected.waiters {
      expected.signal.signal()
    }
  }

  // MARK: v8 compile compatibility

  /// These provenance-free entry points intentionally provide no continuity.
  func expectHandoff(for _: PlaybackGeneration) {}

  func preserve(
    _: AnyObject,
    for _: PlaybackGeneration?,
    allowsSameGenerationRebuild _: Bool = false
  ) -> Bool {
    false
  }

  func takePreservedController(for _: PlaybackGeneration?) -> AnyObject? {
    nil
  }

  func takePreservedControllerOutcome(
    for _: PlaybackGeneration?
  ) -> PreservedControllerTakeOutcome {
    .superseded
  }

  @discardableResult
  func didBecomeReady(_: AnyObject, mediaGeneration _: PlaybackGeneration?) -> Bool {
    false
  }

  func didTimeOut(_: AnyObject) {}

  #if DEBUG
  func _isWaitingForExpectedHandoffForTesting(
    _ output: IOSNativePiPOutputIdentity
  ) -> Bool {
    state.withLock { state in
      guard let expected = state.expected else { return false }
      return expected.target == output.binding && expected.waiters.contains(output)
    }
  }

  func _isWaitingForExpectedHandoffForTesting(
    _ binding: IOSNativePiPPlaybackBinding
  ) -> Bool {
    state.withLock { state in
      guard let expected = state.expected else { return false }
      return expected.target == binding && !expected.waiters.isEmpty
    }
  }
  #endif
}
#endif
