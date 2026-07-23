import Foundation
import SwiftUI
import Synchronization

enum TestStreamURL {
  static let revisionDefaultsKey = "ShowcaseTestStreamRevision"
  private static let legacyDefaultsKey = "ShowcaseTestStreamURL"
  private static let storage = Mutex(Storage())

  static var storedString: String {
    storage.withLock { $0.value }
  }

  static var overrideURL: URL? {
    validatedURL(from: storedString)?.url
  }

  static func resolve(fallback: @autoclosure () -> URL) -> URL {
    LaunchArguments.fixtureURLValue ?? overrideURL ?? fallback()
  }

  static func startSession() {
    let isFirstStart = storage.withLock { storage -> Bool in
      guard !storage.didStart else { return false }
      storage.didStart = true
      storage.value = ""
      return true
    }
    guard isFirstStart else { return }
    UserDefaults.standard.removeObject(forKey: legacyDefaultsKey)
    UserDefaults.standard.removeObject(forKey: revisionDefaultsKey)
  }

  static func store(_ value: String) {
    storage.withLock { $0.value = value }
    publishChange()
  }

  static func clear() {
    storage.withLock { $0.value = "" }
    publishChange()
  }

  static func displayString(for url: URL) -> String {
    guard let scheme = url.scheme else { return "Configured stream" }
    guard let host = url.host, !host.isEmpty else { return "\(scheme.uppercased()) stream" }
    let displayHost = host.contains(":") ? "[\(host)]" : host
    let port = url.port.map { ":\($0)" } ?? ""
    let path = url.path.isEmpty || url.path == "/" ? "" : "/…"
    return "\(scheme)://\(displayHost)\(port)\(path)"
  }

  static func validatedURL(from value: String) -> (url: URL, string: String)? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard
      let url = URL(string: trimmed),
      let scheme = url.scheme,
      !scheme.isEmpty
    else { return nil }
    return (url, trimmed)
  }

  private static func publishChange() {
    UserDefaults.standard.set(UUID().uuidString, forKey: revisionDefaultsKey)
  }

  private struct Storage: Sendable {
    var value = ""
    var didStart = false
  }
}

struct TestStreamSettingsView: View {
  @Environment(\.dismiss) private var dismiss
  @State private var draftURL: String
  @State private var validationError: String?

  init() {
    _draftURL = State(initialValue: TestStreamURL.storedString)
  }

  var body: some View {
    Form {
      Section {
        HStack {
          TextField("https://example.com/live.m3u8", text: $draftURL)
            .font(.body.monospaced())
            .accessibilityIdentifier(AccessibilityID.TestStream.urlField)

          #if os(iOS) || os(macOS) || os(visionOS)
          PasteButton(payloadType: String.self) { values in
            guard let value = values.first else { return }
            draftURL = value.trimmingCharacters(in: .whitespacesAndNewlines)
            validationError = nil
          }
          .labelStyle(.iconOnly)
          .accessibilityLabel("Paste URL")
          .accessibilityIdentifier(AccessibilityID.TestStream.pasteButton)
          #endif
        }

        if let validationError {
          Label(validationError, systemImage: "exclamationmark.triangle.fill")
            .font(.footnote)
            .foregroundStyle(.red)
            .accessibilityIdentifier(AccessibilityID.TestStream.validationError)
        }
      } header: {
        Text("Stream URL")
      } footer: {
        Text("The override is used throughout this Showcase and kept only until the app closes. HTTP, HTTPS, UDP, and other URL schemes supported by the bundled libVLC are accepted. HLS works through its .m3u8 URL.")
      }

      Section("Current Source") {
        if let url = TestStreamURL.overrideURL {
          LabeledContent("Override", value: TestStreamURL.displayString(for: url))
            .accessibilityIdentifier(AccessibilityID.TestStream.currentValue)
        } else {
          LabeledContent("Source", value: "Default showcase media")
            .accessibilityIdentifier(AccessibilityID.TestStream.currentValue)
        }

        if TestStreamURL.overrideURL != nil {
          Button("Use Default Showcase Media", role: .destructive) {
            useDefaultsButtonTapped()
          }
          .accessibilityIdentifier(AccessibilityID.TestStream.clearButton)
        }
      }
    }
    .navigationTitle("Test Stream")
    .toolbar {
      ToolbarItem(placement: .cancellationAction) {
        Button("Cancel", role: .cancel) { dismiss() }
      }

      ToolbarItem(placement: .confirmationAction) {
        Button("Use Stream") { useStreamButtonTapped() }
          .disabled(draftURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          .accessibilityIdentifier(AccessibilityID.TestStream.applyButton)
      }
    }
  }

  private func useStreamButtonTapped() {
    guard let validated = TestStreamURL.validatedURL(from: draftURL) else {
      validationError = "Enter a complete URL that includes a scheme."
      return
    }
    TestStreamURL.store(validated.string)
    dismiss()
  }

  private func useDefaultsButtonTapped() {
    TestStreamURL.clear()
    dismiss()
  }
}
