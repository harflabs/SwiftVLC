func checkedInt32(_ value: Int, parameter: String) throws(VLCError) -> Int32 {
  guard let value = Int32(exactly: value) else {
    throw .invalidInput("\(parameter) must fit in Int32")
  }
  return value
}

func checkedNonnegativeInt32(_ value: Int, parameter: String) throws(VLCError) -> Int32 {
  let value = try checkedInt32(value, parameter: parameter)
  guard value >= 0 else {
    throw .invalidInput("\(parameter) must be non-negative")
  }
  return value
}

func checkedUInt32(_ value: Int, parameter: String) throws(VLCError) -> UInt32 {
  guard let value = UInt32(exactly: value) else {
    throw .invalidInput("\(parameter) must be in 0...\(UInt32.max)")
  }
  return value
}
