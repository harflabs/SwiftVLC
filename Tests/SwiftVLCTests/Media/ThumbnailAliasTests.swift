@testable import SwiftVLC
import Foundation
import Testing

extension Integration {
  @Suite(.tags(.media, .async), .timeLimit(.minutes(1)))
  struct ThumbnailAliasTests {
    @Test
    func `Native media aliases return their own requested thumbnail dimensions`() async throws {
      let list = MediaList()
      try list.append(Media(url: TestMedia.twosecURL))
      let first = try #require(list[0])
      let second = try #require(list[0])
      #expect(first !== second)
      #expect(first.pointer == second.pointer)
      let instance = try VLCInstance(arguments: VLCInstance.defaultArguments + ["--no-audio", "--codec=avcodec"])
      async let small = first.thumbnail(at: .milliseconds(100), width: 64, height: 36, instance: instance)
      async let large = second.thumbnail(at: .milliseconds(500), width: 128, height: 72, instance: instance)
      let (smallPNG, largePNG) = try await (small, large)
      try #require(smallPNG.count >= 24 && largePNG.count >= 24)
      #expect(smallPNG[16..<20].reduce(UInt32(0)) { $0 << 8 | UInt32($1) } == 64)
      #expect(largePNG[16..<20].reduce(UInt32(0)) { $0 << 8 | UInt32($1) } == 128)
      #expect(smallPNG != largePNG)
    }
  }
}
