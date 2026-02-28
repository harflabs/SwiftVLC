@testable import SwiftVLC
import Testing

@Suite("AudioOutput", .tags(.integration))
struct AudioOutputTests {
  @Test("AudioOutput id is name")
  func audioOutputId() {
    let output = AudioOutput(name: "auhal", outputDescription: "CoreAudio")
    #expect(output.id == "auhal")
  }

  @Test("AudioOutput is Hashable")
  func audioOutputHashable() {
    let a = AudioOutput(name: "auhal", outputDescription: "CoreAudio")
    let b = AudioOutput(name: "auhal", outputDescription: "CoreAudio")
    #expect(a == b)
  }

  @Test("AudioDevice id is deviceId")
  func audioDeviceId() {
    let device = AudioDevice(deviceId: "default", deviceDescription: "Default")
    #expect(device.id == "default")
  }

  @Test("AudioDevice is Hashable")
  func audioDeviceHashable() {
    let a = AudioDevice(deviceId: "default", deviceDescription: "Default")
    let b = AudioDevice(deviceId: "default", deviceDescription: "Default")
    #expect(a == b)
  }

  @Test("Instance audio outputs are non-empty")
  func instanceOutputsNonEmpty() {
    let outputs = VLCInstance.shared.audioOutputs()
    #expect(!outputs.isEmpty)
  }

  @Test("Audio output names are non-empty")
  func namesNonEmpty() {
    let outputs = VLCInstance.shared.audioOutputs()
    for output in outputs {
      #expect(!output.name.isEmpty)
      #expect(!output.outputDescription.isEmpty)
    }
  }

  @Test("AudioOutput is Sendable")
  func audioOutputSendable() {
    let output = AudioOutput(name: "test", outputDescription: "Test")
    let sendable: any Sendable = output
    _ = sendable
  }
}
