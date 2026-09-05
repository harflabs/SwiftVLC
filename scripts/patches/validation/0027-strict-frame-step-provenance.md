# Strict frame-step patch provenance

Patch `0027-strict-frame-step-contract.patch` is the byte-exact frozen native
engine delta with SHA-256
`32ac1d2212b69e565d436b9b4d324ae597778c7a06746355f8e8ed897c31dfa8`
and stable patch ID `2ad767d22d2761b850e3281576076ac648fcb19e`.

It was authored and independently re-applied against the pinned post-0026
source. The final repository series was separately replayed from VLC commit
`c833c4be000b426d73ff4324bec574065f00e3df`, using the current patches
0001–0026, this exact 0027 artifact, patch 0028, and patch 0029. The resulting
tree passed `git apply --check` at every boundary and `git diff --check`.

The frozen engine validation covered:

- ten consecutive complete source-linked runs, each producing 53 correlated
  completions;
- a 70-run focused matrix spanning legacy filter pending/drop/expansion,
  cancel/rebind, committed-terminal stop/replacement/EOF durability, deferred
  listener reentry, and unknown-length timing;
- twenty output-boundary EOF barrier runs;
- the production archive probe;
- the immutable vmem setup/cleanup generation race;
- public ABI, source-structure mutations, and Apple Objective-C compilation.

The independently audited wrapper contract has no production P0/P1 finding.
For an accepted matching identifier, native cancellation returning false means
the output or terminal commit already owns the exact result. A later seek,
resume, stop, replacement, or teardown cannot relabel that result; it can only
deny it authority over the newer mutable Player timeline.

The host validation does not prove on-glass pixels. The candidate remains
subject to the physical-device identity contract in
`strict-frame-step-apple-device.md`, including missing-layer/reset/immediate
reuse and cancel-versus-commit races.

## Successor-composition validation (2026-09-01)

The strict frame-step surface introduced extension version 4, but its source
checker also runs against the final additive patch series. A shared fail-closed
resolver now proves every complete, unique and contiguous extension group from
version 4 through version 10, the exact literal version function, declarations,
implementations and exports. Version 9 additionally binds the exact immutable
PiP identity type and fresh-controller claim surface; version 10 binds the
ordered semantic subtitle-text snapshot callback. Patch 0033 remains modeled
separately as a required same-version refinement introduced at version 8, so
removing all of that patch cannot be mistaken for a valid downgrade from v9 or
v10; both successor versions inherit it even when a caller omits the historical
v8 opt-in flag.

The expected final version comes from the ordered patch manifest, not the
checked-in header or the source tree being inspected. The clean source-replay
gate applies every frozen patch at its boundary and runs the resolver's
negative-mutation suite. A clean native build repeats that proof and then
probes the assembled macOS archive for the exact runtime version and required
strong symbols. This keeps a newer header, an older archive and a partially
composed source tree from validating one another.
