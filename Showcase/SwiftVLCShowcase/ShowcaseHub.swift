import SwiftUI

struct ShowcaseHub: View {
  @State private var showingPlayer = false

  var body: some View {
    NavigationStack {
      #if os(tvOS)
      tvOSGrid
      #else
      demoList
      #endif
    }
    #if !os(tvOS)
    .fullScreenCover(isPresented: $showingPlayer) {
      PolishedPlayerDemo()
    }
    #endif
  }

  // MARK: - iOS / macOS — Clean list

  #if !os(tvOS)
  private var demoList: some View {
    List {
      ForEach(ShowcaseItem.available) { item in
        if item == .polishedPlayer {
          Button {
            showingPlayer = true
          } label: {
            demoLabel(item)
          }
        } else {
          NavigationLink(value: item) {
            demoLabel(item)
          }
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

  private func demoLabel(_ item: ShowcaseItem) -> some View {
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
  #endif

  // MARK: - tvOS — Focus-driven grid

  #if os(tvOS)
  private var tvOSGrid: some View {
    ScrollView {
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 400))], spacing: 48) {
        ForEach(ShowcaseItem.available) { item in
          NavigationLink(value: item) {
            VStack(spacing: 16) {
              Image(systemName: item.systemImage)
                .font(.system(size: 48))
                .foregroundStyle(item.accentColor)
              Text(item.title)
                .font(.title3)
              Text(item.subtitle)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(32)
            .background(.regularMaterial, in: .rect(cornerRadius: 20))
          }
          .buttonStyle(.card)
        }
      }
      .padding(48)
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
