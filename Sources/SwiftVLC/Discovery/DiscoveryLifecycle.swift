import CoreFoundation
import Dispatch
import Foundation

/// Serializes libVLC discovery lifecycle calls with deferred native release.
///
/// Both media and renderer discovery can enter the same process-wide UPnP
/// implementation. Their native release functions may wait for worker threads,
/// so running a new lifecycle call while an earlier deferred release is still
/// draining can race libupnp's process-global state.
enum DiscoveryLifecycle {
  /// Where one discovery service's native start, stop, and release run.
  enum Lane: Sendable {
    /// The shared serial queue. Correct for every service that owns its
    /// worker threads, and required for the ones that share libupnp.
    case serialQueue
    /// A dedicated thread with a running run loop.
    ///
    /// libVLC's Bonjour module creates `NSNetServiceBrowser` objects on
    /// whichever thread starts it, and Foundation delivers their results
    /// through that thread's run loop. Started from a task or a dispatch
    /// queue the browser is bound to a run loop nobody runs: discovery
    /// "succeeds" and then never reports a device. The module's teardown also
    /// mutates the same unsynchronised state its delegate callbacks do, so it
    /// has to run on the callback thread too.
    case runLoopThread
  }

  private static let queue = DispatchQueue(
    label: "swiftvlc.discovery.lifecycle",
    qos: .utility
  )

  /// Module names (libVLC matches them case-insensitively) backed by
  /// `modules/services_discovery/bonjour.m`. `mdns` is its alias on Apple
  /// platforms, where the microdns module is not built.
  private static let runLoopBoundModules: Set<String> = [
    "bonjour", "mdns", "bonjour_renderer", "mdns_renderer"
  ]

  static func lane(forServiceNamed name: String) -> Lane {
    // A service name may carry a libVLC option block: "module{key=value}".
    let module = name.prefix { $0 != "{" }.lowercased()
    return runLoopBoundModules.contains(module) ? .runLoopThread : .serialQueue
  }

  static func sync<T>(on lane: Lane = .serialQueue, _ operation: () -> T) -> T {
    switch lane {
    case .serialQueue: queue.sync(execute: operation)
    case .runLoopThread: DiscoveryRunLoopThread.shared.sync(operation)
    }
  }

  static func async(on lane: Lane = .serialQueue, _ operation: @escaping @Sendable () -> Void) {
    switch lane {
    case .serialQueue: queue.async(execute: operation)
    case .runLoopThread: DiscoveryRunLoopThread.shared.async(operation)
    }
  }
}

/// The one thread whose run loop hosts every Bonjour browser libVLC creates.
///
/// A private thread rather than the main thread: callers on the main thread
/// then wait only for the native call itself, exactly as they do on the
/// serial queue, and a caller elsewhere cannot deadlock against a main thread
/// that happens to be waiting for it.
private final class DiscoveryRunLoopThread: Sendable {
  static let shared = DiscoveryRunLoopThread()

  private final class Slot<Value>: @unchecked Sendable {
    var value: Value?
  }

  private nonisolated(unsafe) let runLoop: CFRunLoop

  private init() {
    let ready = DispatchSemaphore(value: 0)
    let started = Slot<CFRunLoop>()
    let thread = Thread {
      let current = CFRunLoopGetCurrent()
      // A run loop with no sources returns immediately. This source never
      // fires; it only keeps the loop alive between browsers.
      var context = CFRunLoopSourceContext()
      let keepAlive = CFRunLoopSourceCreate(nil, 0, &context)
      CFRunLoopAddSource(current, keepAlive, .defaultMode)
      started.value = current
      ready.signal()
      while true {
        CFRunLoopRun()
      }
    }
    thread.name = "swiftvlc.discovery.runloop"
    // Callers block on this thread, the main thread among them; a lower
    // quality of service would invert their priority.
    thread.qualityOfService = .userInitiated
    thread.start()
    ready.wait()
    runLoop = started.value!
  }

  func async(_ operation: @escaping @Sendable () -> Void) {
    CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue, operation)
    CFRunLoopWakeUp(runLoop)
  }

  func sync<T>(_ operation: () -> T) -> T {
    // A libVLC discovery callback runs on this thread; a consumer that
    // stops its discoverer from inside one must not wait for itself.
    if CFEqual(CFRunLoopGetCurrent(), runLoop) {
      return operation()
    }
    return withoutActuallyEscaping(operation) { operation in
      // The run loop keeps its block alive for a moment after the block has
      // signalled, and the caller may leave this scope in that moment. The
      // block therefore reaches the operation only through `work`, and drops
      // it before signalling: nothing of the non-escaping closure can still
      // be referenced when the scope ends.
      let work = Slot<() -> T>()
      work.value = operation
      let result = Slot<T>()
      let finished = DispatchSemaphore(value: 0)
      async {
        result.value = work.value?()
        work.value = nil
        finished.signal()
      }
      finished.wait()
      return result.value!
    }
  }
}
