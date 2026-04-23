@testable import SwiftVLC
import Testing

extension Integration {
  struct VLCInstanceTests {
    @Test
    func `Shared instance returns the same object`() {
      #expect(VLCInstance.shared === VLCInstance.shared)
    }

    @Test
    func `Version string is non-empty and contains a dot`() {
      let version = VLCInstance.shared.version
      #expect(!version.isEmpty)
      #expect(version.contains("."))
    }

    @Test
    func `Version starts with 4`() {
      #expect(VLCInstance.shared.version.hasPrefix("4"))
    }

    @Test
    func `ABI version is positive`() {
      #expect(VLCInstance.shared.abiVersion > 0)
    }

    @Test
    func `Compiler string is non-empty`() {
      #expect(!VLCInstance.shared.compiler.isEmpty)
    }

    @Test
    func `Init with default arguments succeeds`() throws {
      let instance = try VLCInstance()
      #expect(!instance.version.isEmpty)
    }

    @Test
    func `Init with custom arguments succeeds`() throws {
      let instance = try VLCInstance(arguments: ["--no-video-title-show", "--verbose=0"])
      #expect(!instance.version.isEmpty)
    }

    @Test
    func `Init with empty arguments succeeds`() throws {
      let instance = try VLCInstance(arguments: [])
      #expect(!instance.version.isEmpty)
    }

    @Test
    func `Multiple instances are independent`() throws {
      let a = try VLCInstance(arguments: ["--no-video-title-show"])
      let b = try VLCInstance(arguments: ["--no-video-title-show"])
      #expect(a !== b)
      #expect(a.version == b.version)
    }

    @Test
    func `Default arguments contains expected values`() {
      let args = VLCInstance.defaultArguments
      #expect(args.count == 2)
      #expect(args.contains("--no-video-title-show"))
      #expect(args.contains("--no-snapshot-preview"))
      // --no-stats is intentionally absent: it would zero every stats
      // counter every app ever reads. Opt in by passing it explicitly.
      #expect(!args.contains("--no-stats"))
    }

    @Test
    func `Audio outputs returns non-empty list`() {
      let outputs = VLCInstance.shared.audioOutputs()
      #expect(!outputs.isEmpty)
    }
  }
}
