import SwiftUI

/// Interactive `Slider` on iOS / iPadOS / macOS. Read-only value on tvOS,
/// where neither `Slider` nor `Stepper` is available.
struct CompatSlider<Value: BinaryFloatingPoint>: View where Value.Stride: BinaryFloatingPoint {
  @Binding var value: Value
  let range: ClosedRange<Value>
  var step: Value.Stride = 0.01

  var body: some View {
    #if os(tvOS)
    Text(String(format: "%.2f", Double(value)))
      .monospacedDigit()
      .foregroundStyle(.secondary)
    #else
    Slider(value: $value, in: range, step: step)
    #endif
  }
}
