import SwiftUI
import SwiftVLC

struct ContentView: View {
  @State private var urlString = "https://pub-79c73cda2d324e97b277e8a2f351acac.r2.dev/media/TOS.mkv"
  @State private var isPlayerPresented = false
  @State private var errorMessage: String?

  var body: some View {
    #if os(tvOS)
    tvLanding
    #else
    mobileLanding
    #endif
  }

  // MARK: - iOS / macOS Landing

  #if !os(tvOS)
  @ViewBuilder
  private var mobileLanding: some View {
    ZStack {
      Color.black.ignoresSafeArea()

      VStack(spacing: 32) {
        Spacer()

        Image(systemName: "play.rectangle.fill")
          .font(.system(size: 72))
          .foregroundStyle(.white.opacity(0.3))

        Text("SwiftVLC")
          .font(.largeTitle.weight(.bold))
          .foregroundStyle(.white)

        VStack(spacing: 12) {
          TextField("Media URL", text: $urlString)
          #if os(iOS)
            .textFieldStyle(.roundedBorder)
            .textInputAutocapitalization(.never)
          #else
            .textFieldStyle(.roundedBorder)
          #endif
            .autocorrectionDisabled()
            .frame(maxWidth: 500)
            .onSubmit { launchPlayer() }

          HStack(spacing: 16) {
            Button { launchPlayer() } label: {
              Label("Play", systemImage: "play.fill")
                .font(.headline)
                .frame(maxWidth: 200)
            }
            .buttonStyle(.borderedProminent)
            .tint(.blue)

            #if os(macOS)
            Button("Open File...") { openFile() }
              .buttonStyle(.bordered)
            #endif
          }
        }

        if let errorMessage {
          Text(errorMessage)
            .font(.caption)
            .foregroundStyle(.white)
            .padding(8)
            .background(.red.opacity(0.8), in: RoundedRectangle(cornerRadius: 8))
            .onTapGesture { self.errorMessage = nil }
        }

        Spacer()
      }
      .padding()
    }
    .preferredColorScheme(.dark)
    #if os(iOS)
      .fullScreenCover(isPresented: $isPlayerPresented) {
        iOSPlayerView()
      }
    #elseif os(macOS)
      .sheet(isPresented: $isPlayerPresented) {
        MacOSPlayerView()
          .frame(minWidth: 800, minHeight: 500)
      }
    #endif
  }
  #endif

  // MARK: - tvOS Landing

  #if os(tvOS)
  private var tvLanding: some View {
    ZStack {
      Color.black.ignoresSafeArea()

      VStack(spacing: 40) {
        Spacer()

        Image(systemName: "play.rectangle.fill")
          .font(.system(size: 100))
          .foregroundStyle(.white.opacity(0.3))

        Text("SwiftVLC")
          .font(.system(size: 60, weight: .bold))
          .foregroundStyle(.white)

        Button {
          launchPlayer()
        } label: {
          Label("Play", systemImage: "play.fill")
            .font(.title2)
            .frame(width: 300)
        }
        .buttonStyle(.borderedProminent)

        if let errorMessage {
          Text(errorMessage)
            .font(.title3)
            .foregroundStyle(.white)
            .padding()
            .background(.red.opacity(0.8), in: RoundedRectangle(cornerRadius: 12))
        }

        Spacer()
      }
    }
    .fullScreenCover(isPresented: $isPlayerPresented) {
      TVPlayerView()
    }
  }
  #endif

  // MARK: - Actions

  private func launchPlayer() {
    guard URL(string: urlString) != nil else {
      errorMessage = "Invalid URL"
      return
    }
    errorMessage = nil
    isPlayerPresented = true
  }

  #if os(macOS)
  private func openFile() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.movie, .audio, .mpeg4Movie, .quickTimeMovie]
    panel.allowsMultipleSelection = false
    if panel.runModal() == .OK, let url = panel.url {
      urlString = url.absoluteString
      launchPlayer()
    }
  }
  #endif
}
