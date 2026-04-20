import SwiftUI

extension Text {
  /// Renders a string with lightweight inline styles:
  /// `*bold*`, `_italic_`, and `` `code` ``.
  init(template: String, _ style: Font.TextStyle = .body) {
    enum Mark: Hashable { case bold, italic, code }
    var parts: [Text] = []
    var buffer = ""
    var marks: Set<Mark> = []

    func flush() {
      var text = Text(buffer)
      if marks.contains(.code) { text = text.font(.system(style, design: .monospaced)) }
      if marks.contains(.italic) { text = text.italic() }
      if marks.contains(.bold) { text = text.bold() }
      parts.append(text)
      buffer.removeAll()
    }

    for character in template {
      switch character {
      case "*": flush(); marks.formSymmetricDifference([.bold])
      case "_": flush(); marks.formSymmetricDifference([.italic])
      case "`": flush(); marks.formSymmetricDifference([.code])
      default: buffer.append(character)
      }
    }
    flush()
    self = parts.reduce(Text(verbatim: ""), +)
  }
}
