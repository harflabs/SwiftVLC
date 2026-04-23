import Testing

/// Test suites requiring a real libVLC instance — anything that
/// creates `VLCInstance`, `Player`, `Media`, discoverers, etc. Inherits
/// the `.integration` tag, a one-minute ceiling, and serial execution;
/// override the time limit with a suite-level `.timeLimit` trait if a
/// test legitimately needs longer.
///
/// `.serialized` is required because libVLC's upstream UPnP
/// renderer-discovery plugin (libupnp) isn't thread-safe against
/// concurrent instance teardowns elsewhere in the same process: a
/// parallel run occasionally SIGSEGVs inside `libupnp`'s shutdown path
/// while an unrelated suite is initializing its own discoverer. The
/// trait propagates to every nested `@Suite` in `extension Integration`,
/// so all integration tests run one at a time. Pure-Swift logic tests
/// under `Logic` are unaffected and still parallelize.
///
/// Child suites nest inside an `extension Integration` block, e.g.:
/// ```swift
/// extension Integration {
///   @Suite struct MediaTests { ... }
/// }
/// ```
/// Swift Testing propagates the `.tags`, `.timeLimit`, and `.serialized`
/// traits from this parent — but not actor isolation, so `@MainActor`
/// must stay on the child suite when needed.
@Suite(.tags(.integration), .timeLimit(.minutes(1)), .serialized)
struct Integration {}

/// Pure-Swift logic tests — switch-to-string mappings, bitfield
/// encodings, pure enum cases, anything that runs without opening a
/// libVLC instance. Execution is in milliseconds; the one-minute
/// ceiling is only there to catch runaways.
@Suite(.tags(.logic), .timeLimit(.minutes(1)))
struct Logic {}
