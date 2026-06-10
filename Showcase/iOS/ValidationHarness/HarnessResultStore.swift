import Foundation
import SwiftUI
import UIKit

/// Persists one PASS/FAIL/observation result per harness screen in
/// `UserDefaults`, exportable as pretty-printed JSON for the release
/// validation report.
@MainActor
@Observable
final class HarnessResultStore {
  enum Status: String, Codable {
    case pass
    case fail
    case observation
  }

  struct Result: Codable {
    var status: Status
    var note: String
    var recordedAt: Date
  }

  static let shared = HarnessResultStore()

  private(set) var results: [String: Result] = [:]

  private static let defaultsKey = "ValidationHarness.results"

  init() {
    guard let data = UserDefaults.standard.data(forKey: Self.defaultsKey) else { return }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    results = (try? decoder.decode([String: Result].self, from: data)) ?? [:]
  }

  func record(_ status: Status, note: String, for screenID: String) {
    results[screenID] = Result(status: status, note: note, recordedAt: .now)
    persist()
  }

  func clear(_ screenID: String) {
    results[screenID] = nil
    persist()
  }

  var export: String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    guard
      let data = try? encoder.encode(results),
      let json = String(data: data, encoding: .utf8)
    else { return "{}" }
    return json
  }

  private func persist() {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    guard let data = try? encoder.encode(results) else { return }
    UserDefaults.standard.set(data, forKey: Self.defaultsKey)
  }
}

/// Standard result-recording section appended to every harness screen.
struct ResultRecorderSection: View {
  let screenID: String

  @State private var note = ""

  private var store: HarnessResultStore {
    .shared
  }

  var body: some View {
    Section("Result") {
      if let result = store.results[screenID] {
        VStack(alignment: .leading, spacing: 4) {
          Text(result.status.rawValue.uppercased())
            .font(.headline)
            .foregroundStyle(color(for: result.status))
          Text(result.recordedAt.formatted(date: .abbreviated, time: .standard))
            .font(.caption)
            .foregroundStyle(.secondary)
          if !result.note.isEmpty {
            Text(result.note)
              .font(.caption)
          }
        }
      } else {
        Text("No result recorded")
          .foregroundStyle(.secondary)
      }

      TextField("Notes", text: $note, axis: .vertical)

      HStack {
        recordButton("PASS", status: .pass, tint: .green)
        recordButton("FAIL", status: .fail, tint: .red)
        recordButton("OBSERVATION", status: .observation, tint: .orange)
      }

      HStack {
        Button("Clear", role: .destructive) {
          store.clear(screenID)
          note = ""
        }
        .buttonStyle(.borderless)

        Spacer()

        Button("Copy export") {
          UIPasteboard.general.string = store.export
        }
        .buttonStyle(.borderless)

        ShareLink(item: store.export) {
          Label("Share export", systemImage: "square.and.arrow.up")
        }
        .buttonStyle(.borderless)
      }
    }
    .onAppear {
      note = store.results[screenID]?.note ?? ""
    }
  }

  private func recordButton(_ title: String, status: HarnessResultStore.Status, tint: Color) -> some View {
    Button(title) {
      store.record(status, note: note, for: screenID)
    }
    .buttonStyle(.bordered)
    .tint(tint)
    .frame(maxWidth: .infinity)
  }

  private func color(for status: HarnessResultStore.Status) -> Color {
    switch status {
    case .pass: .green
    case .fail: .red
    case .observation: .orange
    }
  }
}
