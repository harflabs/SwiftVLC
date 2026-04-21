@testable import SwiftVLC
import Testing

/// Pin every reclassification rule and every passthrough case so that drift
/// in upstream libVLC's message strings (or accidental over-broad rules in
/// the filter) is caught at unit-test time.
///
/// Rules match the message shape, not the `module` field — libVLC 4.0
/// reports `module = "libvlc"` for every entry through
/// `libvlc_log_get_context`, so module-based rules would never fire. See
/// `LogNoiseFilter` for the rationale.
@Suite(.tags(.logic))
struct LogNoiseFilterTests {
  // MARK: - Reclassification rules

  @Test
  func `Quoted-FOURCC 'is not supported' at error is demoted to warning`() {
    let result = LogNoiseFilter.reclassify(
      level: .error,
      module: "libvlc",
      message: "'DIV2' is not supported"
    )
    #expect(result == .warning)
  }

  @Test
  func `Reclassification covers every quoted FOURCC libVLC may emit`() {
    // The actual format is "'%4.4s' is not supported" — any 4-byte codec.
    let codecs = ["DIV2", "MJPG", "WMV1", "WMV2", "FLV1", "RV10", "MPG1", "AAC "]
    for codec in codecs {
      let result = LogNoiseFilter.reclassify(
        level: .error,
        module: "libvlc",
        message: "'\(codec)' is not supported"
      )
      #expect(result == .warning, "codec \(codec) was not reclassified")
    }
  }

  @Test
  func `'Failed to create video converter' at error is demoted to warning`() {
    let result = LogNoiseFilter.reclassify(
      level: .error,
      module: "libvlc",
      message: "Failed to create video converter"
    )
    #expect(result == .warning)
  }

  @Test
  func `'buffer deadlock prevented' at error is demoted to warning`() {
    let result = LogNoiseFilter.reclassify(
      level: .error,
      module: "libvlc",
      message: "buffer deadlock prevented"
    )
    #expect(result == .warning)
  }

  @Test
  func `'provided view container is nil' at error is demoted to warning`() {
    let result = LogNoiseFilter.reclassify(
      level: .error,
      module: "libvlc",
      message: "provided view container is nil"
    )
    #expect(result == .warning)
  }

  @Test
  func `'Creating UIView window provider failed' at error is demoted to warning`() {
    let result = LogNoiseFilter.reclassify(
      level: .error,
      module: "libvlc",
      message: "Creating UIView window provider failed"
    )
    #expect(result == .warning)
  }

  @Test
  func `Module field is irrelevant — rule fires regardless`() {
    // libVLC 4.0 reports the umbrella "libvlc" for every entry; future
    // versions or our own shim may surface the per-module name. Rules
    // depend on the message shape, not the module.
    let modules: [String?] = ["libvlc", "videotoolbox", "core", nil]
    for module in modules {
      let result = LogNoiseFilter.reclassify(
        level: .error,
        module: module,
        message: "'DIV2' is not supported"
      )
      #expect(result == .warning, "module \(module ?? "nil") was not reclassified")
    }
  }

  // MARK: - Passthrough — only .error is eligible

  @Test(
    arguments: [LogLevel.debug, .notice, .warning] as [LogLevel]
  )
  func `Lower-than-error levels pass through untouched`(level: LogLevel) {
    let result = LogNoiseFilter.reclassify(
      level: level,
      module: "libvlc",
      message: "'DIV2' is not supported"
    )
    #expect(result == level)
  }

  // MARK: - Passthrough — terminal "no decoder" error from the cascade

  @Test
  func `Core decoder's terminal 'Codec' error is NOT demoted`() {
    // src/input/decoder.c:2307 emits this when the entire cascade has
    // exhausted every candidate decoder. Genuinely fatal — must remain at
    // .error. Distinct shape from videotoolbox: starts with "Codec ", has
    // a description in parentheses, and ends with a period.
    let result = LogNoiseFilter.reclassify(
      level: .error,
      module: "libvlc",
      message: "Codec `DIV2' (Microsoft variant of MPEG-4 part 2) is not supported."
    )
    #expect(result == .error)
  }

  @Test
  func `Plain 'is not supported' without quote prefix is NOT demoted`() {
    // Some other libVLC modules emit "X is not supported" without leading
    // quote (e.g. "Profile(N) is not supported" from VAAPI). Those are
    // genuinely informative errors — must not be silently demoted.
    let messages = [
      "Profile(42) is not supported",
      "Hardware acceleration is not supported",
      "this format is not supported"
    ]
    for message in messages {
      let result = LogNoiseFilter.reclassify(
        level: .error,
        module: "libvlc",
        message: message
      )
      #expect(result == .error, "message '\(message)' was incorrectly demoted")
    }
  }

  // MARK: - Passthrough — only the exact converter message is rule-2

  @Test
  func `Different converter messages are NOT demoted`() {
    // The rule pins exact equality so adjacent wording changes don't
    // silently sweep up real failures.
    let messages = [
      "Failed to create video converter for stream 1",
      "Failed to create audio video converter",
      "Couldn't create video converter"
    ]
    for message in messages {
      let result = LogNoiseFilter.reclassify(
        level: .error,
        module: "libvlc",
        message: message
      )
      #expect(result == .error, "message '\(message)' was incorrectly demoted")
    }
  }

  // MARK: - Edge cases

  @Test
  func `Empty message passes through at error`() {
    let result = LogNoiseFilter.reclassify(
      level: .error,
      module: "libvlc",
      message: ""
    )
    #expect(result == .error)
  }
}
