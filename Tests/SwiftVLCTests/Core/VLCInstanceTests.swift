@testable import SwiftVLC
import Foundation
import Testing

extension Integration {
  struct VLCInstanceTests {
    @Test
    func `Shared instance returns the same object`() {
      #expect(VLCInstance.shared === VLCInstance.shared)
    }

    @Test
    func `Prewarm shared resolves the shared instance`() async {
      let instance = await VLCInstance.prepareShared()
      #expect(instance === VLCInstance.shared)
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
    func `Dialog registration claims exactly one slot until released`() throws {
      let instance = try VLCInstance(arguments: ["--quiet"])
      let firstBox = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)
      let secondBox = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)
      defer {
        firstBox.deallocate()
        secondBox.deallocate()
      }

      var installCount = 0
      var clearCount = 0
      let token = try #require(instance.claimDialogRegistration(box: firstBox) { _, box in
        installCount += 1
        #expect(box == firstBox)
      })

      let rejected = instance.claimDialogRegistration(box: secondBox) { _, _ in
        Issue.record("Second dialog registration must not install callbacks")
      }
      #expect(rejected == nil)

      let wrongRelease = instance.releaseDialogRegistration(token: UUID()) { _ in
        Issue.record("Wrong token must not clear callbacks")
      }
      #expect(wrongRelease == nil)

      let released = instance.releaseDialogRegistration(token: token) { _ in
        clearCount += 1
      }

      #expect(released == firstBox)
      #expect(installCount == 1)
      #expect(clearCount == 1)
    }

    @Test
    func `VLCInstance deinit clears an unreleased dialog registration`() throws {
      let leakedBox = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)
      defer { leakedBox.deallocate() }
      weak var weakInstance: VLCInstance?

      do {
        let instance = try VLCInstance(arguments: ["--quiet"])
        weakInstance = instance
        let token = instance.claimDialogRegistration(box: leakedBox) { _, box in
          #expect(box == leakedBox)
        }
        #expect(token != nil)
      }

      #expect(weakInstance == nil)
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
      #expect(!args.contains("--force-darwin-legacy-display"))
      #expect(!args.contains("--vout=macosx"))
      #expect(args.contains("--no-video-title-show"))
      #expect(args.contains("--no-snapshot-preview"))
      #expect(!args.contains("--text-renderer=freetype"))
      // --no-stats is intentionally absent: it would zero every stats
      // counter every app ever reads. Opt in by passing it explicitly.
      #expect(!args.contains("--no-stats"))
    }

    #if os(macOS)
    @Test
    func `Default instance uses PiP safe macOS display`() throws {
      let instance = try VLCInstance()
      #expect(instance.usesPiPSafeDarwinDisplay)
      #expect(!instance.arguments.contains("--force-darwin-legacy-display"))
      #expect(!instance.arguments.contains("--vout=macosx"))
    }

    @Test
    func `Custom instance with legacy macOS vout is PiP safe on macOS`() throws {
      let instance = try VLCInstance(arguments: ["--no-video-title-show", "--vout=macosx"])
      #expect(instance.usesPiPSafeDarwinDisplay)
    }

    @Test
    func `Custom instance accepts separated macOS vout option`() throws {
      let instance = try VLCInstance(arguments: ["--force-darwin-legacy-display", "--vout", "macosx"])
      #expect(instance.usesPiPSafeDarwinDisplay)
    }

    @Test
    func `Custom instance with no video is not PiP safe on macOS`() throws {
      let instance = try VLCInstance(arguments: ["--no-video-title-show", "--no-video"])
      #expect(!instance.usesPiPSafeDarwinDisplay)
    }

    @Test
    func `Custom instance with forced legacy display but no vout is not PiP safe on macOS`() throws {
      let instance = try VLCInstance(arguments: ["--force-darwin-legacy-display"])
      #expect(!instance.usesPiPSafeDarwinDisplay)
    }

    @Test
    func `Custom instance with CAOpenGLLayer vout is not PiP safe on macOS`() throws {
      let instance = try VLCInstance(arguments: ["--force-darwin-legacy-display", "--vout=caopengllayer"])
      #expect(!instance.usesPiPSafeDarwinDisplay)
    }

    @Test
    func `Default macOS instance does not support dynamic deinterlace changes`() throws {
      let instance = try VLCInstance(arguments: VLCInstance.defaultArguments)
      #expect(!instance.supportsDynamicDeinterlaceChanges)
    }

    @Test
    func `Software decoded macOS instance supports dynamic deinterlace changes`() throws {
      let instance = try VLCInstance(
        arguments: VLCInstance.defaultArguments + [
          "--codec=avcodec"
        ]
      )
      #expect(instance.supportsDynamicDeinterlaceChanges)
    }

    @Test
    func `VideoToolbox in separated codec list disables dynamic deinterlace changes`() throws {
      let instance = try VLCInstance(
        arguments: VLCInstance.defaultArguments + [
          "--codec",
          " avcodec, videotoolbox, "
        ]
      )
      #expect(!instance.supportsDynamicDeinterlaceChanges)
    }

    @Test
    func `No-video macOS instance supports deinterlace setter tests`() throws {
      let instance = try VLCInstance(arguments: VLCInstance.defaultArguments + ["--no-video"])
      #expect(instance.supportsDynamicDeinterlaceChanges)
    }
    #endif

    #if os(iOS)
    @Test
    func `Default instance uses PiP safe iOS display`() throws {
      let instance = try VLCInstance()
      #expect(instance.usesPiPSafeDarwinDisplay)
    }

    @Test
    func `Custom iOS instance with explicit sample-buffer vout is PiP safe`() throws {
      let instance = try VLCInstance(arguments: ["--no-video-title-show", "--vout=samplebufferdisplay"])
      #expect(instance.usesPiPSafeDarwinDisplay)
    }

    @Test
    func `Custom iOS instance with no video is not PiP safe`() throws {
      let instance = try VLCInstance(arguments: ["--no-video-title-show", "--no-video"])
      #expect(!instance.usesPiPSafeDarwinDisplay)
    }

    @Test
    func `Custom iOS instance with forced legacy display is not PiP safe`() throws {
      let instance = try VLCInstance(arguments: ["--force-darwin-legacy-display"])
      #expect(!instance.usesPiPSafeDarwinDisplay)
    }

    @Test
    func `Custom iOS instance with GLES vout is not PiP safe`() throws {
      let instance = try VLCInstance(arguments: ["--vout=gles2"])
      #expect(!instance.usesPiPSafeDarwinDisplay)
    }
    #endif

    @Test
    func `Audio outputs returns non-empty list`() {
      let outputs = VLCInstance.shared.audioOutputs()
      #expect(!outputs.isEmpty)
    }
  }
}
