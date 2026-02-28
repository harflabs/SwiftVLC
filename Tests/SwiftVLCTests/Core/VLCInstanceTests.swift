@testable import SwiftVLC
import Testing

@Suite("VLCInstance", .tags(.integration))
struct VLCInstanceTests {
  @Test("Shared instance returns the same object")
  func sharedInstanceReturnsSameObject() {
    #expect(VLCInstance.shared === VLCInstance.shared)
  }

  @Test("Version string is non-empty and contains a dot")
  func versionStringIsNonEmptyAndContainsDot() {
    let version = VLCInstance.shared.version
    #expect(!version.isEmpty)
    #expect(version.contains("."))
  }

  @Test("Version starts with 4")
  func versionStartsWith4() {
    #expect(VLCInstance.shared.version.hasPrefix("4"))
  }

  @Test("ABI version is positive")
  func abiVersionIsPositive() {
    #expect(VLCInstance.shared.abiVersion > 0)
  }

  @Test("Compiler string is non-empty")
  func compilerIsNonEmpty() {
    #expect(!VLCInstance.shared.compiler.isEmpty)
  }

  @Test("Init with default arguments succeeds")
  func initWithDefaultArgumentsSucceeds() throws {
    let instance = try VLCInstance()
    #expect(!instance.version.isEmpty)
  }

  @Test("Init with custom arguments succeeds")
  func initWithCustomArgumentsSucceeds() throws {
    let instance = try VLCInstance(arguments: ["--no-video-title-show", "--verbose=0"])
    #expect(!instance.version.isEmpty)
  }

  @Test("Init with empty arguments succeeds")
  func initWithEmptyArgumentsSucceeds() throws {
    let instance = try VLCInstance(arguments: [])
    #expect(!instance.version.isEmpty)
  }

  @Test("Multiple instances are independent")
  func multipleInstancesAreIndependent() throws {
    let a = try VLCInstance(arguments: ["--no-video-title-show"])
    let b = try VLCInstance(arguments: ["--no-video-title-show"])
    #expect(a !== b)
    #expect(a.version == b.version)
  }

  @Test("Default arguments contains expected values")
  func defaultArgumentsContainsExpectedValues() {
    let args = VLCInstance.defaultArguments
    #expect(args.count == 3)
    #expect(args.contains("--no-video-title-show"))
    #expect(args.contains("--no-stats"))
    #expect(args.contains("--no-snapshot-preview"))
  }

  @Test("Audio outputs returns non-empty list")
  func audioOutputsReturnsNonEmptyList() {
    let outputs = VLCInstance.shared.audioOutputs()
    #expect(!outputs.isEmpty)
  }
}
