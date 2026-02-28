import SwiftUI

struct ShowcaseHub: View {
  var body: some View {
    NavigationStack {
      #if os(tvOS)
      tvOSGrid
      #else
      demoList
      #endif
    }
  }

  // MARK: - iOS / macOS — Clean list

  #if !os(tvOS)
  private var demoList: some View {
    List {
      ForEach(ShowcaseItem.available) { item in
        NavigationLink(value: item) {
          Label {
            VStack(alignment: .leading, spacing: 2) {
              Text(item.title)
              Text(item.subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          } icon: {
            Image(systemName: item.systemImage)
              .font(.body)
              .foregroundStyle(.white)
              .frame(width: 40, height: 40)
              .background(item.accentColor.gradient, in: .rect(cornerRadius: 10))
          }
          .padding(.vertical, 4)
        }
      }
    }
    #if os(iOS)
    .listStyle(.insetGrouped)
    #endif
    .navigationTitle("SwiftVLC Showcase")
    .navigationDestination(for: ShowcaseItem.self) { item in
      destinationView(for: item)
    }
  }
  #endif

  // MARK: - tvOS — Focus-driven grid

  #if os(tvOS)
  private var tvOSGrid: some View {
    ScrollView {
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 300))], spacing: 40) {
        ForEach(ShowcaseItem.available) { item in
          NavigationLink(value: item) {
            VStack(spacing: 12) {
              Image(systemName: item.systemImage)
                .font(.largeTitle)
                .foregroundStyle(item.accentColor)
              Text(item.title)
                .font(.headline)
              Text(item.subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding()
            .padding()
            .background(.regularMaterial, in: .rect(cornerRadius: 16))
          }
          .buttonStyle(.card)
        }
      }
      .padding()
    }
    .navigationTitle("SwiftVLC Showcase")
    .navigationDestination(for: ShowcaseItem.self) { item in
      destinationView(for: item)
    }
  }
  #endif

  // MARK: - Destination

  @ViewBuilder
  private func destinationView(for item: ShowcaseItem) -> some View {
    switch item {
    case .polishedPlayer:
      PolishedPlayerDemo()
    case .pictureInPicture:
      #if !os(tvOS)
      PiPDemo()
      #else
      EmptyView()
      #endif
    case .audioPlayer:
      #if !os(tvOS)
      AudioPlayerDemo()
      #else
      EmptyView()
      #endif
    case .playlist:
      PlaylistDemo()
    case .debugConsole:
      #if !os(tvOS)
      DebugConsoleDemo()
      #else
      EmptyView()
      #endif
    }
  }
}
