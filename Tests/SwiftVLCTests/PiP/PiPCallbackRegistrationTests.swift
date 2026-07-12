#if os(iOS) || os(macOS)
@testable import SwiftVLC
import AVFoundation
import CoreMedia
import Foundation
import Synchronization
import Testing

private enum DirectPiPCallbackOperation: Equatable {
  case install(UInt)
  case clear(UInt)
}

@MainActor
private final class DirectPiPCallbackRecorder {
  private(set) var operations: [DirectPiPCallbackOperation] = []
  private(set) var installedHandles: [UInt] = []
  private(set) var installedOpaques: [UInt] = []
  private(set) var clearedHandles: [UInt] = []

  var api: DirectPiPVideoCallbackAPI {
    DirectPiPVideoCallbackAPI(
      install: { [weak self] handle, opaque in
        let address = UInt(bitPattern: handle)
        self?.operations.append(.install(address))
        self?.installedHandles.append(address)
        self?.installedOpaques.append(UInt(bitPattern: opaque))
      },
      clear: { [weak self] handle in
        let address = UInt(bitPattern: handle)
        self?.operations.append(.clear(address))
        self?.clearedHandles.append(address)
      }
    )
  }
}

extension Integration {
  /// Deterministic coverage for direct `PiPController` vmem registration.
  /// The tests inject native install/clear operations, so ownership races are
  /// asserted as exact handle/generation transitions rather than inferred
  /// from a real vout's timing.
  @Suite(.tags(.mainActor, .async), .serialized)
  @MainActor struct PiPCallbackRegistrationTests {
    @Test
    func `Older PiPController deinit leaves newer controller registered`() async {
      let player = Player(instance: TestInstance.makeAudioOnly())
      var first: PiPController? = PiPController(player: player)
      weak let firstProbe = first
      let firstGeneration = player.directPiPVideoCallbackGeneration

      var successor: PiPController? = PiPController(player: player)
      weak let successorProbe = successor
      let successorGeneration = player.directPiPVideoCallbackGeneration
      #expect(successorGeneration > firstGeneration)

      first = nil

      #expect(firstProbe == nil)
      #expect(successorProbe != nil)
      #expect(player.directPiPVideoCallbackRegistration != nil)
      #expect(player.directPiPVideoCallbackGeneration == successorGeneration)

      successor = nil

      #expect(successorProbe == nil)
      #expect(player.directPiPVideoCallbackRegistration == nil)
      #expect(player.directPiPVideoCallbackGeneration > successorGeneration)
      await player.shutdown()
    }

    @Test
    func `Superseded controller and its late cleanup cannot clear successor callbacks`() async throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      let recorder = DirectPiPCallbackRecorder()
      let handle = UInt(bitPattern: player.pointer)
      let firstRenderer = PixelBufferRenderer(displayLayer: AVSampleBufferDisplayLayer())

      let first = DirectPiPVideoCallbackRegistration(
        renderer: firstRenderer,
        api: recorder.api
      )
      player.claimDirectPiPVideoCallbacks(first)
      let firstGeneration = try #require(first.currentGeneration)
      let firstOpaque = try #require(first.currentOpaqueForTesting)
      weak let firstContext = first.currentContextForTesting

      // A vmem output copies its opaque when it opens. Replacing the native
      // variables does not update that already-open copy. Negotiate this vout
      // while the first controller owns the slot, then prove the resulting
      // child opaque dynamically routes display to a successor.
      var opaqueSlot: UnsafeMutableRawPointer? = firstOpaque
      var chroma = [CChar](repeating: 0, count: 4)
      var width: UInt32 = 96
      var height: UInt32 = 54
      var pitch: UInt32 = 0
      var lines: UInt32 = 0
      let bufferCount = withUnsafeMutablePointer(to: &opaqueSlot) { opaquePointer in
        chroma.withUnsafeMutableBufferPointer { chromaBuffer in
          withUnsafeMutablePointer(to: &width) { widthPointer in
            withUnsafeMutablePointer(to: &height) { heightPointer in
              withUnsafeMutablePointer(to: &pitch) { pitchPointer in
                withUnsafeMutablePointer(to: &lines) { linesPointer in
                  pixelBufferFormatCallback(
                    opaque: opaquePointer,
                    chroma: chromaBuffer.baseAddress,
                    width: widthPointer,
                    height: heightPointer,
                    pitches: pitchPointer,
                    lines: linesPointer
                  )
                }
              }
            }
          }
        }
      }
      #expect(bufferCount > 0)
      let voutOpaque = try #require(opaqueSlot)
      weak var voutContext: PixelBufferRendererVoutCallbackContext?
      voutContext = pixelBufferVoutCallbackContext(from: voutOpaque)
      #expect(voutOpaque != firstOpaque)
      let voutDimensions = try {
        let context = try #require(voutContext)
        return context.decodeRenderer.state.withLock { ($0.width, $0.height) }
      }()
      #expect(voutDimensions == (96, 54))
      #expect(firstRenderer.state.withLock { ($0.width, $0.height) } == (0, 0))

      let successorRenderer = PixelBufferRenderer(displayLayer: AVSampleBufferDisplayLayer())
      successorRenderer.setRenderSize(CMVideoDimensions(width: 48, height: 28))
      let successor = DirectPiPVideoCallbackRegistration(renderer: successorRenderer, api: recorder.api)
      player.claimDirectPiPVideoCallbacks(successor)
      let successorGeneration = try #require(successor.currentGeneration)
      let successorOpaque = try #require(successor.currentOpaqueForTesting)
      weak let successorContext = successor.currentContextForTesting

      #expect(successorGeneration > firstGeneration)
      #expect(recorder.installedHandles == [handle])
      #expect(Set(recorder.installedOpaques).count == 1)
      #expect(successorOpaque == firstOpaque)
      #expect(firstContext === successorContext)
      #expect(recorder.clearedHandles.isEmpty)
      #expect(recorder.operations == [.install(handle)])
      #expect(player.directPiPVideoCallbackRegistration === successor)
      #expect(successorRenderer.state.withLock { ($0.width, $0.height) } == (0, 0))

      var plane: UnsafeMutableRawPointer?
      let picture = withUnsafeMutablePointer(to: &plane) {
        pixelBufferLockCallback(opaque: voutOpaque, planes: $0)
      }
      #expect(picture != nil)
      pixelBufferUnlockCallback(opaque: voutOpaque, picture: picture, planes: nil)
      pixelBufferDisplayCallback(opaque: voutOpaque, picture: picture)
      #expect(firstRenderer.state.withLock { $0.renderPool } == nil)
      #expect(
        successorRenderer.state.withLock { ($0.renderPoolWidth, $0.renderPoolHeight) }
          == (48, 28)
      )

      // Stale controller teardown owns neither the Player registry nor the
      // native variables anymore.
      player.relinquishDirectPiPVideoCallbacks(first)

      #expect(recorder.clearedHandles.isEmpty)
      #expect(player.directPiPVideoCallbackRegistration === successor)
      #expect(player.directPiPVideoCallbackGeneration == successorGeneration)
      #expect(firstContext != nil)

      player.relinquishDirectPiPVideoCallbacks(successor)
      #expect(recorder.clearedHandles == [handle])
      #expect(recorder.operations == [.install(handle), .clear(handle)])

      // An already-open vout keeps its per-vout opaque after the media-player
      // callback variables are cleared. A dormant slot keeps that decode
      // storage valid while dropping only display output; a sequential
      // successor then reuses the same handle-level routing opaque.
      var dormantPlane: UnsafeMutableRawPointer?
      let dormantPicture = withUnsafeMutablePointer(to: &dormantPlane) {
        pixelBufferLockCallback(opaque: voutOpaque, planes: $0)
      }
      #expect(dormantPicture != nil)
      #expect(dormantPlane != nil)
      pixelBufferUnlockCallback(
        opaque: voutOpaque,
        picture: dormantPicture,
        planes: nil
      )
      pixelBufferDisplayCallback(opaque: voutOpaque, picture: dormantPicture)
      #expect(firstContext != nil)
      // After this vout's cleanup there can be no later lock from that vout;
      // a racing future vout runs format first and recreates the decode pool.
      pixelBufferCleanupCallback(opaque: voutOpaque)
      #expect(voutContext == nil)
      let third = DirectPiPVideoCallbackRegistration(
        renderer: PixelBufferRenderer(displayLayer: AVSampleBufferDisplayLayer()),
        api: recorder.api
      )
      player.claimDirectPiPVideoCallbacks(third)
      #expect(third.currentOpaqueForTesting == firstOpaque)
      #expect(third.currentContextForTesting === firstContext)
      #expect(
        recorder.operations == [.install(handle), .clear(handle), .install(handle)]
      )
      player.relinquishDirectPiPVideoCallbacks(third)

      await player.shutdown()
      #expect(player.directPiPVideoCallbackSlot == nil)
      #expect(
        recorder.operations
          == [.install(handle), .clear(handle), .install(handle), .clear(handle)]
      )
      #expect(firstContext == nil)
      #expect(successorContext == nil)
    }

    @Test
    func `Dormant slot is retired instead of copied to a replacement handle`() async throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      let recorder = DirectPiPCallbackRecorder()
      let registration = DirectPiPVideoCallbackRegistration(
        renderer: PixelBufferRenderer(displayLayer: AVSampleBufferDisplayLayer()),
        api: recorder.api
      )
      player.claimDirectPiPVideoCallbacks(registration)

      let oldPointer = player.pointer
      let oldHandle = UInt(bitPattern: oldPointer)
      let oldLifetime = player.nativeHandleLifetime
      weak let oldContext = registration.currentContextForTesting
      player.relinquishDirectPiPVideoCallbacks(registration)

      #expect(player.directPiPVideoCallbackRegistration == nil)
      #expect(player.directPiPVideoCallbackSlot != nil)
      #expect(recorder.operations == [.install(oldHandle), .clear(oldHandle)])

      player.setDrawable(NSObject())
      player.stop()
      try player.prepareDrawableForPlayback()

      #expect(player.pointer != oldPointer)
      #expect(player.directPiPVideoCallbackSlot == nil)
      #expect(recorder.operations == [.install(oldHandle), .clear(oldHandle)])

      try #require(
        await poll(timeout: .seconds(5)) { oldLifetime.isReleased },
        "offloaded release did not finish for the dormant callback slot"
      )
      #expect(oldContext == nil)
      await player.shutdown()
    }

    @Test
    func `Native handle replacement installs successor generation before clearing old handle`() async throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      let recorder = DirectPiPCallbackRecorder()
      let registration = DirectPiPVideoCallbackRegistration(
        renderer: PixelBufferRenderer(displayLayer: AVSampleBufferDisplayLayer()),
        api: recorder.api
      )
      player.claimDirectPiPVideoCallbacks(registration)

      let oldPointer = player.pointer
      let oldLifetime = player.nativeHandleLifetime
      let oldHandle = UInt(bitPattern: oldPointer)
      let oldGeneration = try #require(registration.currentGeneration)
      weak let oldContext = registration.currentContextForTesting

      player.setDrawable(NSObject())
      player.stop()
      try player.prepareDrawableForPlayback()

      let newPointer = player.pointer
      let newHandle = UInt(bitPattern: newPointer)
      let newGeneration = try #require(registration.currentGeneration)
      #expect(newPointer != oldPointer)
      #expect(newGeneration > oldGeneration)
      #expect(recorder.installedHandles == [oldHandle, newHandle])
      #expect(Set(recorder.installedOpaques).count == 2)
      #expect(recorder.clearedHandles == [oldHandle])
      #expect(
        recorder.operations == [.install(oldHandle), .install(newHandle), .clear(oldHandle)]
      )
      #expect(registration.currentLifetime === player.nativeHandleLifetime)

      player.relinquishDirectPiPVideoCallbacks(registration)
      #expect(recorder.clearedHandles == [oldHandle, newHandle])

      await player.shutdown()
      try #require(
        await poll(timeout: .seconds(5)) { oldLifetime.isReleased },
        "offloaded release did not finish for the replaced native handle"
      )
      #expect(oldContext == nil)
    }

    @Test
    func `Player shutdown retires callbacks on the handle being released`() async {
      let player = Player(instance: TestInstance.makeAudioOnly())
      let recorder = DirectPiPCallbackRecorder()
      let registration = DirectPiPVideoCallbackRegistration(
        renderer: PixelBufferRenderer(displayLayer: AVSampleBufferDisplayLayer()),
        api: recorder.api
      )
      player.claimDirectPiPVideoCallbacks(registration)
      let handle = UInt(bitPattern: player.pointer)
      weak let context = registration.currentContextForTesting

      await player.shutdown()

      #expect(recorder.operations == [.install(handle), .clear(handle)])
      #expect(player.directPiPVideoCallbackRegistration == nil)
      #expect(registration.currentGeneration == nil)
      #expect(context == nil)
    }

    @Test
    func `Retired future-vout opaque stays alive until every native owner releases`() throws {
      let recorder = DirectPiPCallbackRecorder()
      let pointer = try #require(OpaquePointer(bitPattern: 0xD1CE_CAFE))
      let lifetime = NativePlayerHandleLifetime(pointer: pointer)
      let listPlayerLease = lifetime.acquireNativeOwnerLease()
      var opaque: UnsafeMutableRawPointer?
      weak var context: PixelBufferRendererCallbackContext?
      do {
        let renderer = PixelBufferRenderer(displayLayer: AVSampleBufferDisplayLayer())
        let slot = DirectPiPVideoCallbackSlot(
          lifetime: lifetime,
          decodeRenderer: renderer,
          api: recorder.api
        )
        slot.activate(renderer: renderer)
        opaque = slot.opaque
        context = slot.context
        slot.retire()
      }
      let retainedOpaque = try #require(opaque)

      #expect(context != nil)
      #expect(context?.retirementRequestedForTesting == true)
      #expect(context?.nativePlayerHandleReleasedForTesting == false)

      // Model another callback arriving after retirement but before vout
      // cleanup and exact native-handle release. Its plane remains valid even
      // though the display target has been removed.
      var opaqueSlot: UnsafeMutableRawPointer? = retainedOpaque
      var chroma: [CChar] = Array(repeating: 0, count: 4)
      var width: UInt32 = 96
      var height: UInt32 = 54
      var pitch: UInt32 = 0
      var lines: UInt32 = 0
      let bufferCount = withUnsafeMutablePointer(to: &opaqueSlot) { opaquePointer in
        chroma.withUnsafeMutableBufferPointer { chromaBuffer in
          pixelBufferFormatCallback(
            opaque: opaquePointer,
            chroma: chromaBuffer.baseAddress,
            width: &width,
            height: &height,
            pitches: &pitch,
            lines: &lines
          )
        }
      }
      #expect(bufferCount > 0)
      let voutOpaque = try #require(opaqueSlot)
      #expect(voutOpaque != retainedOpaque)
      var plane: UnsafeMutableRawPointer?
      let lateLock = withUnsafeMutablePointer(to: &plane) {
        pixelBufferLockCallback(opaque: voutOpaque, planes: $0)
      }
      #expect(lateLock != nil)
      #expect(plane != nil)
      pixelBufferUnlockCallback(opaque: voutOpaque, picture: lateLock, planes: nil)
      pixelBufferDisplayCallback(opaque: voutOpaque, picture: lateLock)
      pixelBufferCleanupCallback(opaque: voutOpaque)
      #expect(context != nil)

      // SwiftVLC releasing its own reference is insufficient: a
      // MediaListPlayer still owns the same handle and can drive a vout.
      lifetime.initialOwnerDidRelease()
      #expect(context != nil)
      #expect(context?.nativePlayerHandleReleasedForTesting == false)

      listPlayerLease.endAfterNativeOwnerRelease()

      #expect(context == nil)
      #expect(recorder.clearedHandles == [UInt(bitPattern: pointer)])
    }
  }
}
#endif
