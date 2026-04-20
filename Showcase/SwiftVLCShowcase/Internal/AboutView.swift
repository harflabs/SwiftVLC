import SwiftUI

struct AboutView: View {
  let readMe: String

  var body: some View {
    #if os(tvOS)
    Text(template: readMe)
      .font(.callout)
    #else
    DisclosureGroup("About") {
      Text(template: readMe)
        .font(.callout)
    }
    #endif
  }
}
