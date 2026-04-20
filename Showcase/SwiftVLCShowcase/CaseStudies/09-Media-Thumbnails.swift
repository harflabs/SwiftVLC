import SwiftUI
import SwiftVLC

private let readMe = """
`media.thumbnail(at:width:height:)` returns PNG `Data` for any offset in the stream \
without playing. Useful for scrubber previews and chapter pickers.
"""

struct ThumbnailsCase: View {
  @State private var media: Media?
  @State private var thumbnail: PlatformImage?
  @State private var offset: Double = 30
  @State private var isGenerating = false

  var body: some View {
    Form {
      Section { AboutView(readMe: readMe) }

      Section {
        if let thumbnail {
          Image(platformImage: thumbnail)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .listRowInsets(EdgeInsets())
        } else if isGenerating {
          ProgressView("Generating…")
            .frame(maxWidth: .infinity)
            .padding()
        } else {
          Text("Tap Generate to render a frame at the chosen offset.")
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding()
        }
      }

      Section("Offset") {
        CompatSlider(value: $offset, range: 0...60, step: 1)
        LabeledContent("At", value: "\(Int(offset))s")
      }

      Section {
        Button("Generate", systemImage: "sparkles") {
          Task { await refresh() }
        }
        .frame(maxWidth: .infinity)
        .disabled(isGenerating)
      }
    }
    .navigationTitle("Thumbnails")
    .task {
      media = try? Media(url: TestMedia.bigBuckBunny)
    }
  }

  private func refresh() async {
    guard let media else { return }
    isGenerating = true
    defer { isGenerating = false }

    if
      let data = try? await media.thumbnail(
        at: .seconds(offset), width: 640, height: 360
      ) {
      thumbnail = PlatformImage(data: data)
    }
  }
}
