#if os(iOS) || os(macOS)
import CoreVideo
import Foundation
import Synchronization
import Testing
@_spi(Qualification) @testable import SwiftVLC

@MainActor
@Suite(.serialized)
struct PiPTimebaseDiagnosticsTests {
  #if os(iOS)
  @Test
  func `Performance snapshot combines active vout geometry and presentation telemetry`() throws {
    let player = Player()
    let controller = PiPController(player: player)
    let registration = try #require(controller.callbackRegistration)
    let context = try #require(registration.currentContextForTesting)
    let opaque = try #require(registration.currentOpaqueForTesting)
    let decodeRenderer = PixelBufferRenderer()
    decodeRenderer.state.withLock {
      $0.width = 1920
      $0.height = 1080
    }
    let vout = try #require(
      context.makeVoutContext(
        handleOpaque: opaque,
        decodeRenderer: decodeRenderer,
        sourceGeometry: PixelBufferSourceGeometry(fullFrameWidth: 1920, height: 1080)
      )
    )
    defer { vout.cleanupDecodeStorage() }
    controller.renderer.state.withLock {
      $0.renderPoolAllocationFailureCount = 2
      $0.lastRenderPoolAllocationStatus = kCVReturnAllocationFailed
    }
    controller.renderer.enqueueState.withLock {
      $0.presentedFrameCount = 120
      $0.replacementCount = 3
      $0.backpressureDropCount = 4
    }

    let snapshot = try #require(controller.renderPerformanceQualificationSnapshot)

    #expect(snapshot.sourceWidth == 1920)
    #expect(snapshot.sourceHeight == 1080)
    #expect(snapshot.renderPoolAllocationFailureCount == 2)
    #expect(snapshot.lastRenderPoolAllocationStatus == kCVReturnAllocationFailed)
    #expect(snapshot.deliveredFrameCount == 120)
    #expect(snapshot.droppedFrameCount == 7)
  }
  #endif

  @Test
  func `Snapshot reports the direct renderer and clock without mutating either`() throws {
    let player = Player()
    let controller = PiPController(player: player)

    let before = controller._controlTimebaseSecondsForTesting()
    let rendererBefore = controller.renderer.telemetrySnapshot
    let snapshot = controller.timebaseDiagnosticSnapshot()
    let rendererAfter = controller.renderer.telemetrySnapshot

    #expect(snapshot.playbackGeneration == 0)
    #expect(snapshot.isPlaybackActive == false)
    #expect(snapshot.isPictureInPictureActive == false)
    #expect(snapshot.mediaTimeSeconds == 0)
    #expect(snapshot.controlTimebaseSeconds == before)
    #expect(snapshot.controlTimebaseRate == 0)
    #expect(snapshot.decodedFrameCount == 0)
    #expect(snapshot.decodedContentChangeCount == 0)
    #expect(snapshot.lastDecodedContentFingerprint == nil)
    #expect(snapshot.renderGeneration == rendererBefore.renderGeneration)
    #expect(snapshot.frameDurationValue == nil)
    #expect(snapshot.frameDurationTimescale == nil)
    #expect(snapshot.presentationCopyRequired == false)
    #expect(snapshot.presentationCopyFrameCount == 0)
    #expect(snapshot.presentationCopyFailureCount == 0)
    #expect(
      snapshot.displayLayerFlushRequestCount
        == rendererBefore.displayLayerFlushRequestCount
    )
    #expect(snapshot.decodePoolAllocationFailureCount == 0)
    #expect(snapshot.lastDecodePoolAllocationStatus == nil)
    #expect(snapshot.renderPoolAllocationFailureCount == 0)
    #expect(snapshot.lastRenderPoolAllocationStatus == nil)
    #expect(snapshot.vmemLockAttemptCount == 0)
    #expect(snapshot.vmemLockSuccessCount == 0)
    #expect(snapshot.vmemPoolUnavailableCount == 0)
    #expect(snapshot.vmemBaseAddressLockFailureCount == 0)
    #expect(snapshot.vmemPendingInstallFailureCount == 0)
    #expect(snapshot.vmemUnlockCallbackCount == 0)
    #expect(snapshot.vmemDisplayCallbackCount == 0)
    #expect(snapshot.vmemDisplayConsumeFailureCount == 0)
    #expect(snapshot.deliveredFrameCount == 0)
    #expect(snapshot.displayLayerStatus == "unknown")
    #expect(snapshot.displayLayerError == nil)
    #expect(snapshot.lastDeliveredSamplePlaybackGeneration == nil)
    #expect(snapshot.correctionCount >= 1)
    #expect(controller._controlTimebaseSecondsForTesting() == before)
    #expect(rendererAfter == rendererBefore)
    _ = try JSONEncoder().encode(snapshot)
  }

  @Test
  func `Every timebase write is emitted with a monotonic sequence`() async throws {
    let player = Player()
    let controller = PiPController(player: player)
    let stream = controller.timebaseCorrections
    var iterator = stream.makeAsyncIterator()

    controller.syncTimebase(playing: false, reason: .playbackStateTransition)
    let firstTime = try #require(await iterator.next())
    let firstRate = try #require(await iterator.next())
    controller.syncTimebase(playing: false, reason: .initialSynchronization)
    let secondTime = try #require(await iterator.next())
    let secondRate = try #require(await iterator.next())

    #expect(firstTime.reason == .playbackStateTransition)
    #expect(firstRate.reason == .playbackStateTransition)
    #expect(secondTime.reason == .initialSynchronization)
    #expect(secondRate.reason == .initialSynchronization)
    #expect(firstRate.sequence == firstTime.sequence + 1)
    #expect(secondTime.sequence == firstRate.sequence + 1)
    #expect(secondRate.sequence == secondTime.sequence + 1)
    #expect(firstTime.playbackGeneration == 0)
    #expect(firstTime.correctedTimebaseSeconds == firstTime.mediaTimeSeconds)
    #expect(firstTime.correctedTimebaseRate == nil)
    #expect(firstRate.previousTimebaseRate != nil)
    #expect(firstRate.correctedTimebaseRate == 0)
    #expect(firstRate.systemUptime >= firstTime.systemUptime)
    #expect(secondRate.systemUptime >= firstRate.systemUptime)
    _ = try JSONEncoder().encode([firstTime, firstRate, secondTime, secondRate])
  }

  @Test
  func `A rate-only write is independently recorded`() async throws {
    let player = Player()
    let controller = PiPController(player: player)
    var iterator = controller.timebaseCorrections.makeAsyncIterator()

    controller.setTimebaseRate(
      0.5,
      reason: .playbackRateTransition,
      mediaTimeSeconds: 12
    )
    let correction = try #require(await iterator.next())

    #expect(correction.reason == .playbackRateTransition)
    #expect(correction.correctedTimebaseRate == 0.5)
    #expect(correction.previousTimebaseRate != nil)
    #expect(correction.mediaTimeSeconds == 12)
  }
}
#endif
