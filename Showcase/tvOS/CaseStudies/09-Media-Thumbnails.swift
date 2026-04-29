import SwiftUI
import SwiftVLC
import UIKit

struct TVThumbnailsCase: View {
  @State private var media: Media?
  @State private var thumbnail: UIImage?
  @State private var offset: Double = 5
  @State private var isGenerating = false

  var body: some View {
    TVShowcaseContent(
      title: "Thumbnails",
      summary: "Generate PNG thumbnail data from Media without playing it.",
      usage: "Choose an offset with focused controls and generate a PNG thumbnail without starting playback."
    ) {
      TVSection(title: "Preview") {
        if let thumbnail {
          Image(uiImage: thumbnail)
            .resizable()
            .aspectRatio(16 / 9, contentMode: .fit)
            .frame(maxHeight: 320)
            .clipShape(.rect(cornerRadius: 8))
        } else if isGenerating {
          ProgressView("Generating...")
        } else {
          TVPlaceholderRow(text: "Generate a frame from the selected offset.")
        }

        TVSlider(
          "Offset",
          value: $offset,
          in: 0...60,
          step: 1
        ) { "\(Int($0)) seconds" }
        HStack {
          Text("Offset")
          Spacer()
          Text("\(Int(offset)) seconds")
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
        Button("Generate", systemImage: "sparkles") { Task { await generateButtonTapped() } }
          .disabled(isGenerating)
      }
    } sidebar: {
      TVSection(title: "Source", isFocusable: true) {
        TVMetricGrid {
          TVMetricRow(title: "File", value: TVTestMedia.demo.lastPathComponent)
          TVMetricRow(title: "Offset", value: "\(Int(offset)) seconds")
          TVMetricRow(title: "Generating", value: isGenerating ? "Yes" : "No")
        }
      }
      TVLibrarySurface(symbols: ["Media(url:)", "media.thumbnail(at:width:height:)"])
    }
    .task { media = try? Media(url: TVTestMedia.demo) }
  }

  private func generateButtonTapped() async {
    guard let media else { return }
    isGenerating = true
    defer { isGenerating = false }

    if
      let data = try? await media.thumbnail(at: .seconds(offset), width: 640, height: 360),
      let image = UIImage(data: data) {
      thumbnail = image
    }
  }
}
