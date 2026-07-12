#if os(iOS) || os(macOS)
@testable import SwiftVLC
import SwiftUI
import Testing

extension Integration {
  @Suite(.tags(.mainActor))
  @MainActor struct PiPControllerBindingPublicationTests {
    @Test
    func `binding publication drops superseded controller work`() async {
      let player = Player(instance: TestInstance.shared)
      let coordinator = PiPVideoView(player).makeCoordinator()
      let storage = Box<PiPController?>(nil)
      let binding = Binding<PiPController?>(
        get: { storage.value },
        set: { storage.value = $0 }
      )
      let first = PiPController(player: player)
      let second = PiPController(player: player)

      coordinator.publishController(first, to: binding)
      coordinator.publishController(second, to: binding)
      await coordinator.waitForControllerBindingPublication()

      #expect(storage.value === second)
    }

    @Test
    func `unchanged binding publication performs no additional writes`() async {
      let player = Player(instance: TestInstance.shared)
      let coordinator = PiPVideoView(player).makeCoordinator()
      let storage = Box<PiPController?>(nil)
      let writeCount = Box(0)
      let binding = Binding<PiPController?>(
        get: { storage.value },
        set: {
          writeCount.value += 1
          storage.value = $0
        }
      )
      let controller = PiPController(player: player)

      coordinator.publishController(controller, to: binding)
      await coordinator.waitForControllerBindingPublication()
      #expect(storage.value === controller)
      #expect(writeCount.value == 1)

      coordinator.publishController(controller, to: binding)
      await coordinator.waitForControllerBindingPublication()
      #expect(storage.value === controller)
      #expect(writeCount.value == 1)
    }

    /// `Binding` exposes no storage identity. A replacement sink can already
    /// contain the controller, which is observationally identical to SwiftUI
    /// handing the publisher another wrapper around the unchanged sink. The
    /// publisher therefore keeps ownership of the sink it demonstrably wrote
    /// and treats the prepopulated sink as externally owned.
    @Test
    func `prepopulated replacement preserves demonstrable sink ownership`() async {
      let player = Player(instance: TestInstance.shared)
      let coordinator = PiPVideoView(player).makeCoordinator()
      let firstStorage = Box<PiPController?>(nil)
      let secondStorage = Box<PiPController?>(nil)
      let firstWriteCount = Box(0)
      let secondWriteCount = Box(0)
      let firstBinding = Binding<PiPController?>(
        get: { firstStorage.value },
        set: {
          firstWriteCount.value += 1
          firstStorage.value = $0
        }
      )
      let secondBinding = Binding<PiPController?>(
        get: { secondStorage.value },
        set: {
          secondWriteCount.value += 1
          secondStorage.value = $0
        }
      )
      let controller = PiPController(player: player)

      coordinator.publishController(controller, to: firstBinding)
      await coordinator.waitForControllerBindingPublication()
      #expect(firstStorage.value === controller)

      // Model a genuinely different sink that was prepopulated elsewhere.
      secondStorage.value = controller
      coordinator.publishController(controller, to: secondBinding)
      await coordinator.waitForControllerBindingPublication()
      #expect(firstWriteCount.value == 1)
      #expect(secondWriteCount.value == 0)

      coordinator.clearControllerBinding()
      await coordinator.waitForControllerBindingPublication()

      #expect(firstStorage.value == nil)
      #expect(secondStorage.value === controller)
      #expect(firstWriteCount.value == 2)
      #expect(secondWriteCount.value == 0)
    }

    @Test
    func `fresh unchanged binding wrappers retain constant storage`() async {
      let player = Player(instance: TestInstance.shared)
      let publication = PiPControllerBindingPublication()
      let storage = Box<PiPController?>(nil)
      let writeCount = Box(0)
      let controller = PiPController(player: player)
      let makeBinding = {
        Binding<PiPController?>(
          get: { storage.value },
          set: {
            writeCount.value += 1
            storage.value = $0
          }
        )
      }

      publication.publish(controller, to: makeBinding())
      await publication.waitForPendingPublication()

      for _ in 0..<10000 {
        publication.publish(controller, to: makeBinding())
      }
      await publication.waitForPendingPublication()

      #expect(storage.value === controller)
      #expect(writeCount.value == 1)
      #expect(publication.retainedBindingCountForTesting == 1)

      publication.clear()
      await publication.waitForPendingPublication()
      #expect(storage.value == nil)
      #expect(writeCount.value == 2)
      #expect(publication.retainedBindingCountForTesting == 0)
    }

    @Test
    func `replacing or removing a binding clears the prior sink`() async {
      let player = Player(instance: TestInstance.shared)
      let coordinator = PiPVideoView(player).makeCoordinator()
      let firstStorage = Box<PiPController?>(nil)
      let secondStorage = Box<PiPController?>(nil)
      let firstBinding = Binding<PiPController?>(
        get: { firstStorage.value },
        set: { firstStorage.value = $0 }
      )
      let secondBinding = Binding<PiPController?>(
        get: { secondStorage.value },
        set: { secondStorage.value = $0 }
      )
      let first = PiPController(player: player)
      let second = PiPController(player: player)

      coordinator.publishController(first, to: firstBinding)
      await coordinator.waitForControllerBindingPublication()
      #expect(firstStorage.value === first)

      coordinator.publishController(second, to: secondBinding)
      await coordinator.waitForControllerBindingPublication()
      #expect(firstStorage.value == nil)
      #expect(secondStorage.value === second)

      coordinator.publishController(second, to: nil)
      await coordinator.waitForControllerBindingPublication()
      #expect(secondStorage.value == nil)
    }

    @Test
    func `removed binding no longer retains its detached controller`() async {
      let player = Player(instance: TestInstance.shared)
      let coordinator = PiPVideoView(player).makeCoordinator()
      let storage = Box<PiPController?>(nil)
      let binding = Binding<PiPController?>(
        get: { storage.value },
        set: { storage.value = $0 }
      )
      var controller: PiPController? = PiPController(player: player)
      let detachedController = WeakBox(controller)

      coordinator.publishController(controller, to: binding)
      await coordinator.waitForControllerBindingPublication()
      controller = nil
      #expect(
        detachedController.value != nil,
        "The binding should be the remaining owner before removal"
      )

      coordinator.publishController(nil, to: nil)
      await coordinator.waitForControllerBindingPublication()

      #expect(storage.value == nil)
      #expect(detachedController.value == nil)
    }

    /// A deferred dismantle from an old representable may run after its
    /// successor has published into the same binding. Clearing is ownership
    /// conditional so the stale teardown cannot erase the successor.
    @Test
    func `stale binding clear preserves a successor controller`() async {
      let player = Player(instance: TestInstance.shared)
      let oldCoordinator = PiPVideoView(player).makeCoordinator()
      let successorCoordinator = PiPVideoView(player).makeCoordinator()
      let storage = Box<PiPController?>(nil)
      let binding = Binding<PiPController?>(
        get: { storage.value },
        set: { storage.value = $0 }
      )
      let oldController = PiPController(player: player)
      let successor = PiPController(player: player)

      oldCoordinator.publishController(oldController, to: binding)
      await oldCoordinator.waitForControllerBindingPublication()
      successorCoordinator.publishController(successor, to: binding)
      await successorCoordinator.waitForControllerBindingPublication()

      // Model the old representable's dismantle task running last.
      oldCoordinator.clearControllerBinding()
      await oldCoordinator.waitForControllerBindingPublication()

      #expect(storage.value === successor)
    }
  }
}

private final class Box<T> {
  var value: T

  init(_ initial: T) {
    value = initial
  }
}

private final class WeakBox<T: AnyObject> {
  weak var value: T?

  init(_ value: T?) {
    self.value = value
  }
}
#endif
