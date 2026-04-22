@testable import SwiftVLC
import Synchronization
import Testing

/// Covers `DialogID`'s storage / consume / dismiss path.
///
/// libVLC never exposes dialog pointers to us directly outside of real
/// auth / cert / progress prompts, which are effectively impossible to
/// trigger from unit tests. Instead, these tests fabricate a "dialog"
/// pointer from a known-invalid address and rely on
/// `DialogIDStorage`'s one-shot consumption contract: the storage
/// hands the pointer back exactly once, then nil-s itself out.
///
/// Each test takes a unique address from the shared counter so
/// parallel test runs can't collide on the `DialogIDStorage` registry.
/// The pointers are never dereferenced — only used as identity keys
/// and consumption tokens.
@Suite(.tags(.logic))
struct DialogIDTests {
  /// A fresh DialogID reports itself valid until it's consumed.
  @Test
  func `New DialogID is valid before consume`() {
    let ptr = SyntheticDialogPointer.next()
    let id = DialogID(pointer: ptr)
    #expect(id._isValidForTesting)
    // Consuming clears it.
    _ = id._consumeForTesting()
    #expect(!id._isValidForTesting)
  }

  /// `_consumeForTesting` returns the stored pointer on the first call
  /// and nil on subsequent calls. This is the invariant the `consume`
  /// closure relies on: libVLC callbacks never get a second shot at
  /// the same dialog pointer.
  @Test
  func `Consume is one-shot`() {
    let ptr = SyntheticDialogPointer.next()
    let id = DialogID(pointer: ptr)

    let first = id._consumeForTesting()
    #expect(first == ptr)

    let second = id._consumeForTesting()
    #expect(second == nil, "Second consume must return nil")
  }

  /// After consumption, `dismiss()` must return `false` without
  /// calling libVLC — the storage short-circuits because the pointer
  /// is nil.
  @Test
  func `Dismiss after consume returns false without calling libVLC`() {
    let ptr = SyntheticDialogPointer.next()
    let id = DialogID(pointer: ptr)
    _ = id._consumeForTesting()

    #expect(id.dismiss() == false, "Dismiss on already-consumed dialog must be a no-op")
  }

  /// Two DialogIDs constructed from the same underlying pointer share
  /// one `DialogIDStorage`. This is the crux of the registry — if a
  /// single libVLC dialog triggers multiple Swift-side wrappers (e.g.
  /// login + subsequent progress), they all see the same consumption
  /// state.
  @Test
  func `Identical pointers resolve to shared storage`() {
    let ptr = SyntheticDialogPointer.next()
    let first = DialogID(pointer: ptr)
    let second = DialogID(pointer: ptr)

    // Both see the pointer.
    #expect(first._isValidForTesting)
    #expect(second._isValidForTesting)

    // Consuming one consumes the other.
    _ = first._consumeForTesting()
    #expect(!second._isValidForTesting, "Shared storage should have been consumed")
  }

  /// Distinct pointers resolve to distinct storage entries — no
  /// cross-contamination in the registry.
  @Test
  func `Distinct pointers resolve to distinct storage`() {
    let ptrA = SyntheticDialogPointer.next()
    let ptrB = SyntheticDialogPointer.next()
    let idA = DialogID(pointer: ptrA)
    let idB = DialogID(pointer: ptrB)

    _ = idA._consumeForTesting()
    #expect(!idA._isValidForTesting)
    #expect(idB._isValidForTesting, "Consuming A must not affect B")
  }
}

/// Vends process-unique `OpaquePointer` values for use as dialog
/// registry keys. Each `next()` returns a distinct address so parallel
/// tests don't collide on `DialogIDStorage`'s shared registry. Addresses
/// are deliberately nondereferenceable — only identity matters.
private enum SyntheticDialogPointer {
  private static let counter = Mutex(0xDEAD_BEEF)

  static func next() -> OpaquePointer {
    let address = counter.withLock { value -> Int in
      value += 16
      return value
    }
    return OpaquePointer(bitPattern: address)!
  }
}
