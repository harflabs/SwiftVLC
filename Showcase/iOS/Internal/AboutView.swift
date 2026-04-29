import SwiftUI

struct AboutView: View {
  let readMe: String

  var body: some View {
    DisclosureGroup("About") {
      Text(template: readMe)
        .font(.callout)
    }
  }
}
