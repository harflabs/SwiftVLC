import SwiftUI

struct ShowcaseHub: View {
  #if os(macOS)
  @State private var selection: ShowcaseItem? = .polishedPlayer
  #endif

  var body: some View {
    #if os(macOS)
    macOSSplitView
    #elseif os(tvOS)
    NavigationStack { tvOSGrid }
    #else
    NavigationStack { demoList }
    #endif
  }

  // MARK: - macOS — Sidebar + Detail

  #if os(macOS)
  private var macOSSplitView: some View {
    NavigationSplitView {
      List(ShowcaseItem.available, selection: $selection) { item in
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
            .frame(width: 32, height: 32)
            .background(item.accentColor.gradient, in: .rect(cornerRadius: 8))
        }
        .padding(.vertical, 4)
        .tag(item)
      }
      .navigationTitle("SwiftVLC")
    } detail: {
      if let selection {
        destinationView(for: selection)
      } else {
        ContentUnavailableView("Select a Demo", systemImage: "play.rectangle.fill")
      }
    }
  }
  #endif

  // MARK: - iOS — Clean list

  #if os(iOS)
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
    .listStyle(.insetGrouped)
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
