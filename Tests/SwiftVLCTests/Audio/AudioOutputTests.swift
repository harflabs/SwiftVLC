@testable import SwiftVLC
import Testing

@Suite(.tags(.integration), .timeLimit(.minutes(1)))
struct AudioOutputTests {
  @Test
  func `AudioOutput id is name`() {
    let output = AudioOutput(name: "auhal", outputDescription: "CoreAudio")
    #expect(output.id == "auhal")
  }

  @Test
  func `AudioOutput is Hashable`() {
    let a = AudioOutput(name: "auhal", outputDescription: "CoreAudio")
    let b = AudioOutput(name: "auhal", outputDescription: "CoreAudio")
    #expect(a == b)
  }

  @Test
  func `AudioDevice id is deviceId`() {
    let device = AudioDevice(deviceId: "default", deviceDescription: "Default")
    #expect(device.id == "default")
  }

  @Test
  func `AudioDevice is Hashable`() {
    let a = AudioDevice(deviceId: "default", deviceDescription: "Default")
    let b = AudioDevice(deviceId: "default", deviceDescription: "Default")
    #expect(a == b)
  }

  @Test
  func `Instance audio outputs are non-empty`() {
    let outputs = VLCInstance.shared.audioOutputs()
    #expect(!outputs.isEmpty)
  }

  @Test
  func `Audio output names are non-empty`() {
    let outputs = VLCInstance.shared.audioOutputs()
    for output in outputs {
      #expect(!output.name.isEmpty)
      #expect(!output.outputDescription.isEmpty)
    }
  }

  @Test
  func `AudioOutput is Sendable`() {
    let output = AudioOutput(name: "test", outputDescription: "Test")
    let sendable: any Sendable = output
    _ = sendable
  }
}
