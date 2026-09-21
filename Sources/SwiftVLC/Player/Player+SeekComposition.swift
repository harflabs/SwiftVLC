import CLibVLC

extension Player {
  /// Rebases the first queued relative request on the active command's intended
  /// target so later relative aggregation describes the user's command chain,
  /// not the optimistic clock value captured before A was accepted.
  func rebaseRelativeSeekIfSafe(
    _ command: NativeSeekCommand,
    after active: NativeSeekCommand?
  ) -> NativeSeekCommand {
    guard
      let active,
      command.playbackGeneration == active.playbackGeneration,
      command.externalEpoch == active.externalEpoch,
      case .relative(let offset) = command.operation,
      let activeTarget = active.evidence.requestedTimeMilliseconds,
      let target = clampedRelativeTarget(
        baselineMilliseconds: activeTarget,
        offsetMilliseconds: offset
      )
    else { return command }

    var rebased = command
    rebased.evidence = makeComposedSeekEvidence(
      baseline: command.evidence,
      requestedTimeMilliseconds: target
    )
    if case .time = command.publication {
      rebased.publication = .time(milliseconds: target)
    }
    return rebased
  }

  /// Merges a queued replacement without applying enqueue-time duration to a
  /// target which will only enter VLC later. Pure relative chains retain native
  /// jump semantics. Absolute/fractional intent followed by relative commands
  /// retains its base plus every offset and resolves them once, immediately
  /// before dispatch, against the then-current duration.
  func mergeQueuedSeekReplacement(
    _ replacement: NativeSeekCommand,
    replacing previous: NativeSeekCommand
  ) -> NativeSeekCommand {
    guard
      replacement.playbackGeneration == previous.playbackGeneration,
      replacement.externalEpoch == previous.externalEpoch
    else { return replacement }

    if case .strictRelative(let replacementIntent) = replacement.operation {
      var aggregate = replacement
      let target: Int64?
      switch previous.operation {
      case .strictRelative(var previousIntent):
        previousIntent.offsetsMilliseconds.append(contentsOf: replacementIntent.offsetsMilliseconds)
        previousIntent.fast = replacementIntent.fast
        aggregate.operation = .strictRelative(previousIntent)
        target = resolveStrictRelativeSeekIntent(previousIntent)
      case .time(let milliseconds, _):
        let composition = DeferredSeekComposition(
          base: .absoluteMilliseconds(milliseconds),
          relativeOffsetsMilliseconds: replacementIntent.offsetsMilliseconds,
          fast: replacementIntent.fast
        )
        aggregate.operation = .composed(composition)
        target = resolveDeferredSeekComposition(composition)
      case .position(let position, _):
        let composition = DeferredSeekComposition(
          base: .position(position),
          relativeOffsetsMilliseconds: replacementIntent.offsetsMilliseconds,
          fast: replacementIntent.fast
        )
        aggregate.operation = .composed(composition)
        target = resolveDeferredSeekComposition(composition)
      case .composed(var composition):
        composition.relativeOffsetsMilliseconds.append(contentsOf: replacementIntent.offsetsMilliseconds)
        composition.fast = replacementIntent.fast
        aggregate.operation = .composed(composition)
        target = resolveDeferredSeekComposition(composition)
      case .relative:
        return replacement
      }
      // A relative command extends the latest undispatched intent, not the
      // clock of the earlier native seek still occupying the watcher.
      aggregate.evidence = makeComposedSeekEvidence(
        baseline: previous.evidence,
        requestedTimeMilliseconds: target
      )
      aggregate.publication = target.map {
        .time(milliseconds: $0)
      } ?? .revisionOnly
      return aggregate
    }

    guard case .relative(let replacementOffset) = replacement.operation else {
      return replacement
    }

    switch previous.operation {
    case .relative(let previousOffset):
      let aggregate = previousOffset.addingReportingOverflow(replacementOffset)
      guard !aggregate.overflow else {
        var rejected = replacement
        rejected.operation = .composed(DeferredSeekComposition(
          base: .invalid,
          relativeOffsetsMilliseconds: []
        ))
        return rejected
      }

      var composed = replacement
      composed.operation = .relative(milliseconds: aggregate.partialValue)
      let targetMilliseconds: Int64? = if
        let previousTarget = previous.evidence.requestedTimeMilliseconds {
        clampedRelativeTarget(
          baselineMilliseconds: previousTarget,
          offsetMilliseconds: replacementOffset
        )
      } else {
        nil
      }
      composed.evidence = makeComposedSeekEvidence(
        baseline: previous.evidence,
        requestedTimeMilliseconds: targetMilliseconds
      )
      if case .time = replacement.publication, let targetMilliseconds {
        composed.publication = .time(milliseconds: targetMilliseconds)
      }
      return composed

    case .time(let milliseconds, _):
      return makeDeferredSeekComposition(
        base: .absoluteMilliseconds(milliseconds),
        previous: previous,
        replacement: replacement,
        offsetMilliseconds: replacementOffset
      )

    case .position(let position, _):
      return makeDeferredSeekComposition(
        base: .position(position),
        previous: previous,
        replacement: replacement,
        offsetMilliseconds: replacementOffset
      )

    case .composed(var composition):
      composition.relativeOffsetsMilliseconds.append(replacementOffset)
      composition.fast = false
      return makeDeferredSeekComposition(
        composition: composition,
        previous: previous,
        replacement: replacement
      )

    case .strictRelative:
      // A lenient native jump replacing strict VOD intent remains the latest
      // command. Its raw relative semantics are intentionally preserved.
      return replacement
    }
  }

  /// Applies every accepted strict relative offset before clamping once to the
  /// playable timeline visible at actual native dispatch. Overflow rejects the
  /// aggregate instead of silently dropping an earlier button press.
  func resolveStrictRelativeSeekIntent(
    _ intent: StrictRelativeSeekIntent
  ) -> Int64? {
    var target = intent.baseMilliseconds
    for offset in intent.offsetsMilliseconds {
      let addition = target.addingReportingOverflow(offset)
      guard !addition.overflow else { return nil }
      target = addition.partialValue
    }
    target = max(0, target)
    if let durationMilliseconds = currentDurationMilliseconds {
      target = min(target, durationMilliseconds)
    }
    return target
  }

  func makeDeferredSeekComposition(
    base: DeferredSeekCompositionBase,
    previous: NativeSeekCommand,
    replacement: NativeSeekCommand,
    offsetMilliseconds: Int64
  ) -> NativeSeekCommand {
    makeDeferredSeekComposition(
      composition: DeferredSeekComposition(
        base: base,
        relativeOffsetsMilliseconds: [offsetMilliseconds]
      ),
      previous: previous,
      replacement: replacement
    )
  }

  func makeDeferredSeekComposition(
    composition: DeferredSeekComposition,
    previous: NativeSeekCommand,
    replacement: NativeSeekCommand
  ) -> NativeSeekCommand {
    var composed = replacement
    composed.operation = .composed(composition)
    let estimatedTarget = resolveDeferredSeekComposition(composition)
    composed.evidence = makeComposedSeekEvidence(
      baseline: previous.evidence,
      requestedTimeMilliseconds: estimatedTarget
    )
    if case .time = replacement.publication, let estimatedTarget {
      composed.publication = .time(milliseconds: estimatedTarget)
    }
    return composed
  }

  /// Resolves a composition using one duration snapshot and clamps only after
  /// every offset is applied. Any arithmetic overflow is rejected rather than
  /// silently dropping earlier user intent.
  func resolveDeferredSeekComposition(
    _ composition: DeferredSeekComposition
  ) -> Int64? {
    let baseMilliseconds: Int64
    switch composition.base {
    case .absoluteMilliseconds(let milliseconds):
      baseMilliseconds = milliseconds
    case .position(let position):
      guard let durationMilliseconds = currentDurationMilliseconds else { return nil }
      baseMilliseconds = checkedMilliseconds(
        for: PlaybackPosition(position),
        durationMs: durationMilliseconds
      )
    case .invalid:
      return nil
    }

    var target = baseMilliseconds
    for offset in composition.relativeOffsetsMilliseconds {
      let result = target.addingReportingOverflow(offset)
      guard !result.overflow else { return nil }
      target = result.partialValue
    }
    target = max(0, target)
    if let durationMilliseconds = currentDurationMilliseconds {
      target = min(target, durationMilliseconds)
    }
    return target
  }

  func clampedRelativeTarget(
    baselineMilliseconds: Int64,
    offsetMilliseconds: Int64
  ) -> Int64? {
    let target = baselineMilliseconds.addingReportingOverflow(offsetMilliseconds)
    guard !target.overflow else { return nil }
    var clamped = max(0, target.partialValue)
    if
      let duration,
      let durationMilliseconds = try? duration.checkedNonnegativeMilliseconds(
        parameter: "duration"
      ) {
      clamped = min(clamped, durationMilliseconds)
    }
    return clamped
  }

  func makeComposedSeekEvidence(
    baseline: SeekSettlementEvidence,
    requestedTimeMilliseconds: Int64?
  ) -> SeekSettlementEvidence {
    let requestedPosition: Double? = if
      let requestedTimeMilliseconds,
      let duration,
      let durationMilliseconds = try? duration.checkedNonnegativeMilliseconds(
        parameter: "duration"
      ),
      durationMilliseconds > 0 {
      min(1, max(0, Double(requestedTimeMilliseconds) / Double(durationMilliseconds)))
    } else {
      nil
    }
    return SeekSettlementEvidence(
      baselineTimeMilliseconds: baseline.baselineTimeMilliseconds,
      baselinePosition: baseline.baselinePosition,
      requestedTimeMilliseconds: requestedTimeMilliseconds,
      requestedPosition: requestedPosition
    )
  }

  /// Re-reads native evidence at the actual dispatch boundary. A queued
  /// command can wait behind a keyframe-adjusted landing for nearly its full
  /// queue deadline; enqueue-time getters then describe the previous episode
  /// and can make that landing look like stable evidence for the successor.
  func finalizeSeekCommandForDispatch(
    _ command: NativeSeekCommand
  ) -> NativeSeekCommand {
    var finalized = command
    let baseline = nativeSeekClockPointForEvidence()

    switch command.operation {
    case .time(let milliseconds, _):
      finalized.evidence = makeSeekSettlementEvidence(
        baseline: baseline,
        requestedTimeMilliseconds: milliseconds
      )
      if case .time = command.publication {
        finalized.publication = .time(milliseconds: milliseconds)
      }

    case .position(let position, _):
      let requestedTimeMilliseconds = currentDurationMilliseconds.map {
        checkedMilliseconds(for: PlaybackPosition(position), durationMs: $0)
      }
      finalized.evidence = makeSeekSettlementEvidence(
        baseline: baseline,
        requestedTimeMilliseconds: requestedTimeMilliseconds,
        requestedPosition: position
      )
      finalized.publication = .position(
        position,
        timeMilliseconds: requestedTimeMilliseconds
      )

    case .relative(let milliseconds):
      let requestedTimeMilliseconds = baseline.timeMilliseconds.flatMap {
        clampedRelativeTarget(
          baselineMilliseconds: $0,
          offsetMilliseconds: milliseconds
        )
      }
      finalized.evidence = makeSeekSettlementEvidence(
        baseline: baseline,
        requestedTimeMilliseconds: requestedTimeMilliseconds
      )
      if case .time = command.publication {
        finalized.publication = requestedTimeMilliseconds.map {
          .time(milliseconds: $0)
        } ?? .revisionOnly
      }

    case .strictRelative(let intent):
      guard let requestedTimeMilliseconds = resolveStrictRelativeSeekIntent(intent) else {
        finalized.evidence = makeSeekSettlementEvidence(
          baseline: baseline,
          requestedTimeMilliseconds: nil
        )
        return finalized
      }
      finalized.operation = .time(
        milliseconds: requestedTimeMilliseconds,
        fast: intent.fast
      )
      finalized.evidence = makeSeekSettlementEvidence(
        baseline: baseline,
        requestedTimeMilliseconds: requestedTimeMilliseconds
      )
      finalized.publication = .time(milliseconds: requestedTimeMilliseconds)

    case .composed(let composition):
      guard let requestedTimeMilliseconds = resolveDeferredSeekComposition(composition) else {
        finalized.evidence = makeSeekSettlementEvidence(
          baseline: baseline,
          requestedTimeMilliseconds: nil
        )
        return finalized
      }
      finalized.operation = .time(
        milliseconds: requestedTimeMilliseconds,
        fast: composition.fast
      )
      finalized.evidence = makeSeekSettlementEvidence(
        baseline: baseline,
        requestedTimeMilliseconds: requestedTimeMilliseconds
      )
      if case .time = command.publication {
        finalized.publication = .time(milliseconds: requestedTimeMilliseconds)
      }
    }
    return finalized
  }

  var currentDurationMilliseconds: Int64? {
    guard let duration else { return nil }
    return try? duration.checkedNonnegativeMilliseconds(parameter: "duration")
  }
}
