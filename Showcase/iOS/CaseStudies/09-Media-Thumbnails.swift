import SwiftUI
import SwiftVLC

private let readMe = """
`media.thumbnail(at:width:height:)` returns PNG `Data` for any offset in the stream \
without playing. Useful for scrubber previews and chapter pickers.
"""

struct ThumbnailsCase: View {
  @State private var media: Media?
  @State private var thumbnail: PlatformImage?
  @State private var offset: Double = 5
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
            .accessibilityIdentifier(AccessibilityID.Thumbnails.thumbnailImage)
        } else if isGenerating {
          ProgressView("Generating…")
            .frame(maxWidth: .infinity)
            .padding()
            .accessibilityIdentifier(AccessibilityID.Thumbnails.progressIndicator)
        } else {
          Text("Tap Generate to render a frame at the chosen offset.")
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding()
            .accessibilityIdentifier(AccessibilityID.Thumbnails.emptyPlaceholder)
        }
      }

      Section("Offset") {
        CompatSlider(value: $offset, range: 0...60, step: 1)
          .accessibilityIdentifier(AccessibilityID.Thumbnails.offsetSlider)
        HStack {
          Text("At")
          Spacer()
          Text("\(Int(offset))s")
            .foregroundStyle(.secondary)
            .accessibilityIdentifier(AccessibilityID.Thumbnails.offsetLabel)
        }
      }

      Section {
        Button("Generate", systemImage: "sparkles") {
          Task { await refresh() }
        }
        .accessibilityIdentifier(AccessibilityID.Thumbnails.generateButton)
        .frame(maxWidth: .infinity)
        .disabled(isGenerating)
      }
    }
    .showcaseFormStyle()
    .navigationTitle("Thumbnails")
    .task { task() }
  }

  private func task() {
    media = try? Media(url: TestMedia.demo)
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
