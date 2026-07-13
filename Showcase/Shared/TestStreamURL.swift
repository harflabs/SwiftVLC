import Foundation
import SwiftUI

enum TestStreamURL {
  static let defaultsKey = "ShowcaseTestStreamURL"

  static var storedString: String {
    UserDefaults.standard.string(forKey: defaultsKey) ?? ""
  }

  static var overrideURL: URL? {
    validatedURL(from: storedString)?.url
  }

  static func resolve(fallback: @autoclosure () -> URL) -> URL {
    LaunchArguments.fixtureURLValue ?? overrideURL ?? fallback()
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
        Text("The override is used throughout this Showcase for bundled media and public test streams. HTTP, HLS, RTSP, UDP, and other VLC-supported URL schemes are accepted.")
      }

      Section("Current Source") {
        if let url = TestStreamURL.overrideURL {
          LabeledContent("Override", value: url.absoluteString)
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
    UserDefaults.standard.set(validated.string, forKey: TestStreamURL.defaultsKey)
    dismiss()
  }

  private func useDefaultsButtonTapped() {
    UserDefaults.standard.removeObject(forKey: TestStreamURL.defaultsKey)
    dismiss()
  }
}
