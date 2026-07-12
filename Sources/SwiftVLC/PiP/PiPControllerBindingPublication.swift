#if os(iOS) || os(macOS)
import SwiftUI

/// Owns deferred writes to a representable's optional controller binding.
///
/// `Binding` exposes no public storage identity. This publisher therefore
/// owns only the sink it demonstrably wrote: if another binding already
/// contains the same controller, publication is a no-op and ownership does
/// not move. That rule both avoids nil/rewrite feedback for an unchanged sink
/// and keeps retained binding storage bounded. The ownership check also
/// prevents a late dismantle from erasing a newer representable's controller
/// in shared storage.
@MainActor
final class PiPControllerBindingPublication {
  private var generation: UInt64 = 0
  private var publicationTask: Task<Void, Never>?
  private var ownedBinding: Binding<PiPController?>?
  private weak var publishedController: PiPController?

  var currentBinding: Binding<PiPController?>? {
    ownedBinding
  }

  var retainedBindingCountForTesting: Int {
    ownedBinding == nil ? 0 : 1
  }

  func publish(
    _ controller: PiPController?,
    to newBinding: Binding<PiPController?>?
  ) {
    // SwiftUI can call update repeatedly with fresh wrappers around unchanged
    // storage. A distinct sink can also arrive prepopulated with the same
    // controller; public `Binding` cannot distinguish those cases. In both,
    // retain ownership of only the sink this publisher actually wrote.
    if
      publicationTask == nil,
      let controller,
      publishedController === controller,
      let newBinding,
      newBinding.wrappedValue === controller {
      return
    }

    generation &+= 1
    let publicationGeneration = generation
    publicationTask?.cancel()

    let previousBinding = ownedBinding
    let previousController = publishedController
    ownedBinding = newBinding
    publishedController = newBinding != nil ? controller : nil

    publicationTask = Task { @MainActor [weak previousController, weak controller] in
      guard
        !Task.isCancelled,
        self.generation == publicationGeneration
      else { return }

      if let previousBinding, let previousController {
        Self.clearBinding(previousBinding, ifOwnedBy: previousController)
      }
      newBinding?.wrappedValue = controller

      if self.generation == publicationGeneration {
        self.publicationTask = nil
      }
    }
  }

  func clear() {
    publish(nil, to: nil)
  }

  func waitForPendingPublication() async {
    await publicationTask?.value
  }

  static func clearBinding(
    _ binding: Binding<PiPController?>,
    ifOwnedBy controller: PiPController
  ) {
    guard binding.wrappedValue === controller else { return }
    binding.wrappedValue = nil
  }
}
#endif
