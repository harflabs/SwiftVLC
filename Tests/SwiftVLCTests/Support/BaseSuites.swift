import Testing

/// Test suites requiring a real libVLC instance — anything that
/// creates `VLCInstance`, `Player`, `Media`, discoverers, etc. Inherits
/// the `.integration` tag and a one-minute ceiling; override with a
/// suite-level `.timeLimit` trait if a test legitimately needs longer.
///
/// Child suites nest inside an `extension Integration` block, e.g.:
/// ```swift
/// extension Integration {
///   @Suite struct MediaTests { ... }
/// }
/// ```
/// Swift Testing propagates the `.tags` and `.timeLimit` traits from
/// this parent — but not actor isolation, so `@MainActor` must stay on
/// the child suite when needed.
@Suite(.tags(.integration), .timeLimit(.minutes(1)))
struct Integration {}

/// Pure-Swift logic tests — switch-to-string mappings, bitfield
/// encodings, pure enum cases, anything that runs without opening a
/// libVLC instance. Execution is in milliseconds; the one-minute
/// ceiling is only there to catch runaways.
@Suite(.tags(.logic), .timeLimit(.minutes(1)))
struct Logic {}
