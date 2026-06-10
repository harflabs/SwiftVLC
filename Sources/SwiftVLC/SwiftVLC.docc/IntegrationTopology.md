# Integration topology

How to consume SwiftVLC from a layered, multi-module app without
duplicating the libVLC runtime.

## One libVLC per process

SwiftVLC's `libvlc` binary dependency is a large static archive: the
whole libVLC core, every plugin, and their Objective-C support classes,
all linked into whichever image consumes it. A static archive has no
identity at load time — if two images in the same app each link it, the
process carries two complete libVLC runtimes. That is undefined
behavior, not just wasted size:

- The Objective-C runtime sees every libVLC class twice and picks one
  arbitrarily (`Class X is implemented in both …` at launch).
- Each copy registers its own plugin registry and global state, so
  callbacks can cross between the two half-initialized runtimes.

The libvlc archive must therefore exist **exactly once** among the
images a process loads.

## The supported layered topology

SwiftVLC's library product is *automatic*-type. A single app target that
depends on SwiftVLC directly links everything statically into the app
executable — one copy, nothing to configure. Keep doing that for simple
apps; the automatic product type is deliberate.

The rule only bites when SwiftVLC sits below several modules. The
supported shape is:

1. **One dynamic intermediary framework** (yours), in **its own
   package**, declares the SwiftVLC package dependency and re-exports
   whatever surface the rest of the app needs. Because the framework is
   dynamic, the libvlc archive is linked into *it* and into nothing
   else.
2. **Static feature libraries**, in a separate package, depend on that
   framework's dynamic *product* — never on the SwiftVLC package. They
   may use SwiftVLC types freely through the intermediary's
   `@_exported import SwiftVLC`.
3. **The app** links the feature libraries plus the dynamic framework.
   It must not declare its own SwiftVLC package dependency either.

```
App ──▶ FeatureA (static) ─┐
    ──▶ FeatureB (static) ─┼──▶ MediaCore (dynamic) ──▶ SwiftVLC ──▶ libvlc
    ──▶ MediaCore ─────────┘
```

If any feature library or the app adds its own SwiftVLC dependency, the
automatic product is statically linked a second time and the
single-copy guarantee is gone.

The wrapper's own package matters: the static feature targets and the
dynamic wrapper **cannot live in the same package**. Inside one
package, feature targets can only depend on the wrapper *target*, which
Xcode then needs both statically (for the features) and dynamically
(for the product) — that either fails outright ("linked as a static
library … but cannot be built dynamically because there is a package
product with the same name") or, with a differently named product,
produces an empty stub framework the app cannot link. A cross-package
dependency on the dynamic *product* links it dynamically, which is the
whole point.

## The executable proof

`Fixtures/DynamicHost` in the repository is this exact topology, kept
buildable as a regression fixture: a `MediaCoreKit` package whose
dynamic `MediaCore` product owns the SwiftVLC dependency, a `MediaKit`
package with static `FeatureA`/`FeatureB` products that consume it, and
iOS + tvOS host apps linking all three.

```sh
Fixtures/DynamicHost/verify.sh            # build + single-copy audit
Fixtures/DynamicHost/verify.sh --launch   # additionally run the iOS app
                                          # in a simulator (local only)
```

The script builds both apps for the iOS and tvOS simulators, then runs
`nm` over the app executable and every dynamic framework the app loads,
counting which images define `_libvlc_new`. It passes only when exactly
one image defines it — `MediaCore.framework/MediaCore` — and the app
executable defines none. With `--launch` it also boots a simulator and
checks the app's runtime output: both feature libraries observe the
same ``VLCInstance/shared`` object, and the launch log contains no
duplicate Objective-C class warnings. CI runs the build-and-audit half
on every pull request that touches `Package.swift` or `Sources/`.
