import AppKit
import SwiftUI
import SwiftVLC

struct MacThumbnailsCase: View {
  @State private var media: Media?
  @State private var thumbnail: NSImage?
  @State private var offset: Double = 5
  @State private var isGenerating = false

  var body: some View {
    MacShowcaseContent(
      title: "Thumbnails",
      summary: "Generate PNG thumbnail data from Media without playing it.",
      usage: "Choose an offset and generate a PNG thumbnail without starting playback."
    ) {
      MacSection(title: "Preview") {
        if let thumbnail {
          Image(nsImage: thumbnail)
            .resizable()
            .aspectRatio(16 / 9, contentMode: .fit)
            .frame(maxHeight: 320)
            .clipShape(.rect(cornerRadius: 8))
        } else if isGenerating {
          ProgressView("Generating...")
        } else {
          MacPlaceholderRow(text: "Generate a frame from the selected offset.")
        }

        Slider(value: $offset, in: 0...60, step: 1)
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
      MacSection(title: "Source") {
        MacMetricGrid {
          MacMetricRow(title: "File", value: MacTestMedia.demo.lastPathComponent)
          MacMetricRow(title: "Offset", value: "\(Int(offset)) seconds")
          MacMetricRow(title: "Generating", value: isGenerating ? "Yes" : "No")
        }
      }
      MacLibrarySurface(symbols: ["Media(url:)", "media.thumbnail(at:width:height:)"])
    }
    .task { media = try? Media(url: MacTestMedia.demo) }
  }

  private func generateButtonTapped() async {
    guard let media else { return }
    isGenerating = true
    defer { isGenerating = false }

    if
      let data = try? await media.thumbnail(at: .seconds(offset), width: 640, height: 360),
      let image = NSImage(data: data) {
      thumbnail = image
    }
  }
}
