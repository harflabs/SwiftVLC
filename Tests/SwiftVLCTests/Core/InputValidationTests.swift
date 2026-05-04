@testable import SwiftVLC
import Testing

extension Logic {
  struct InputValidationTests {
    @Test
    func `checkedInt32 accepts exact Int32 range values`() throws {
      #expect(try checkedInt32(Int(Int32.min), parameter: "value") == Int32.min)
      #expect(try checkedInt32(Int(Int32.max), parameter: "value") == Int32.max)
    }

    @Test
    func `checkedNonnegativeInt32 rejects negative values`() {
      #expect(throws: VLCError.self) {
        _ = try checkedNonnegativeInt32(-1, parameter: "index")
      }
    }

    @Test
    func `checkedUInt32 accepts unsigned range endpoints`() throws {
      #expect(try checkedUInt32(0, parameter: "width") == 0)
      #expect(try checkedUInt32(Int(UInt32.max), parameter: "width") == UInt32.max)
    }
  }
}
