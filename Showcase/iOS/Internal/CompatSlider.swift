import SwiftUI

struct CompatSlider<Value: BinaryFloatingPoint>: View where Value.Stride: BinaryFloatingPoint {
  @Binding var value: Value
  let range: ClosedRange<Value>
  var step: Value.Stride = 0.01

  var body: some View {
    Slider(value: $value, in: range, step: step)
  }
}
