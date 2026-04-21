/// Reclassifies upstream libVLC log entries whose declared severity is
/// incongruent with how the surrounding cascade actually works.
///
/// libVLC's decoder, video output, and demuxer subsystems pick a working
/// module by *probing*: each candidate's `Open()` is called in turn, and a
/// failure simply means "try the next one". A handful of upstream modules
/// log those expected probe failures at `LIBVLC_ERROR`, so a subscriber
/// filtering at ``LogLevel/error`` sees false alarms even when playback is
/// healthy. This filter demotes those specific messages to
/// ``LogLevel/warning`` so ``LogLevel/error`` retains its meaning ("playback
/// actually broke") for downstream consumers.
///
/// The terminal failures emitted by the cascade itself ("no suitable decoder
/// for ...", "Codec 'XXXX' (description) is not supported.") use distinct
/// wording and are untouched by this filter — they remain at
/// ``LogLevel/error``.
///
/// **Why not match on the module field?** libVLC 4.0's
/// `libvlc_log_get_context` reports the umbrella library name (`"libvlc"`)
/// rather than the per-module identifier (e.g. `"videotoolbox"`) — the
/// per-module info lives in `file` / `psz_object_type` instead. Rather than
/// widen our C shim, the rules below pin tight message-shape patterns that
/// only the noisy emitters ever produce.
///
/// **Performance**: pure function, no allocations, called once per log entry
/// from the libVLC log thread. The early `level == .error` short-circuit
/// means non-error entries (the vast majority) pay one comparison and
/// return. Each rule runs at most one prefix + suffix check or one equality
/// check on the message string. See `LogNoiseFilterTests` for the pinned
/// rules.
///
/// Each rule documents the upstream source location and the structural
/// reason the rule exists. When bumping `VLC_HASH` in
/// `scripts/build-libvlc.sh`, re-verify that those locations and message
/// strings still apply; the unit tests catch wording drift.
///
/// The right long-term home for these severity corrections is upstream VLC.
/// Until those land, this filter is how SwiftVLC consumers get a clean
/// error level.
enum LogNoiseFilter {
  /// Returns the effective level for a libVLC log entry. Pure — safe to call
  /// from the C log callback thread.
  ///
  /// Returns `level` unchanged for any entry that doesn't match a rule below.
  /// Only entries that arrive at ``LogLevel/error`` are eligible for demotion;
  /// lower levels short-circuit immediately.
  static func reclassify(
    level: LogLevel,
    module _: String?,
    message: String
  ) -> LogLevel {
    guard level == .error else { return level }

    // VideoToolbox decoder probe rejection.
    //   vlc/modules/codec/videotoolbox/decoder.c:990
    //     msg_Err(p_dec, "'%4.4s' is not supported", ...);
    // produces strings of the form "'DIV2' is not supported" — opening with
    // a single-quoted four-character FOURCC. The terminal "no decoder
    // found" error in `src/input/decoder.c:2307` uses a different shape
    // ("Codec 'XXXX' (description) is not supported."), so this strict
    // prefix + suffix match unambiguously identifies the probe.
    if message.hasPrefix("'") && message.hasSuffix("' is not supported") {
      return .warning
    }

    // The probe failure above leaves the chroma converter unable to
    // negotiate an output format, which fires a follow-up "Failed to
    // create video converter" — same root cause, same severity correction.
    // Pinned to exact equality (not `contains`) so we don't accidentally
    // demote a longer message that mentions a converter as a side note.
    if message == "Failed to create video converter" {
      return .warning
    }

    // libVLC's input/decoder thread wakes its buffer predicate under
    // rapid seeks and detects a would-be deadlock between the demuxer,
    // the decoder, and the output — it breaks the deadlock defensively
    // (no actual hang, no data loss) and logs a `msg_Err`. The
    // successful recovery makes this informational; only real
    // unrecovered deadlocks would escalate via subsequent fatal errors
    // from `core`. Pinned to exact equality to avoid demoting unrelated
    // messages that happen to mention a buffer.
    if message == "buffer deadlock prevented" {
      return .warning
    }

    // libVLC's UIKit video-output module logs these two during the
    // transient window between `PiPVideoView.makeUIView` returning and
    // the layer host being attached. The module's cascade retries with
    // the correct view once the layer host arrives, so the initial
    // failures are structural (not actual failures). Observed every
    // time PiP / pixel-buffer consumers initialize; pinned to exact
    // equality.
    if message == "provided view container is nil" {
      return .warning
    }
    if message == "Creating UIView window provider failed" {
      return .warning
    }

    // UPnP renderer discovery fails on iOS simulator because the
    // simulator's network interface doesn't expose a multicast-capable
    // route. The discoverer probe fails with `UPNP_E_INVALID_INTERFACE`;
    // the cascade then reports no suitable module for `upnp_renderer`.
    // Neither is fatal — the simulator just has no UPnP network to
    // discover on. On real hardware with Wi-Fi / Ethernet available,
    // these messages don't fire.
    if message == "Initialization failed: UPNP_E_INVALID_INTERFACE" {
      return .warning
    }
    if message == "no suitable renderer discovery module for 'upnp_renderer'" {
      return .warning
    }

    return level
  }
}
