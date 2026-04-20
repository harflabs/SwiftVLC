import SwiftUI
import SwiftVLC

private let readMe = """
`seek(by:)` jumps forward or backward by a `Duration` offset — no absolute time math \
required.
"""

struct RelativeSeekCase: View {
  @State private var player = Player()

  var body: some View {
    Form {
      Section { AboutView(readMe: readMe) }

      Section {
        VideoView(player)
          .aspectRatio(16 / 9, contentMode: .fit)
          .listRowInsets(EdgeInsets())
      } footer: {
        PlayPauseFooter(player: player)
      }

      Section("Position") {
        SeekBar(player: player)
      }

      Section("Skip") {
        HStack(spacing: 12) {
          skip(-30)
          skip(-10)
          skip(+10)
          skip(+30)
        }
      }
    }
    .showcaseFormStyle()
    .navigationTitle("Relative seek")
    .task { try? player.play(url: TestMedia.bigBuckBunny) }
    .onDisappear { player.stop() }
  }

  private func skip(_ seconds: Int) -> some View {
    Button {
      player.seek(by: .seconds(seconds))
    } label: {
      Text(seconds > 0 ? "+\(seconds)s" : "\(seconds)s")
        .frame(maxWidth: .infinity)
    }
  }
}
