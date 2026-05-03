@testable import SwiftVLC
import Foundation
import Testing

/// Compares two strings and emits a readable unified-diff issue on
/// mismatch. A no-dependency stand-in for snapshot-testing libraries:
/// the "expected" string lives inline in the test, the helper pretty-
/// prints the diff so test failures are actionable.
///
/// Updates are manual — change the expected string in source. Manual
/// updates keep snapshots audited by humans and avoid the
/// auto-record-mode footgun of accidentally capturing broken behavior
/// as the new ground truth.
///
/// - Parameters:
///   - actual: The string captured at runtime.
///   - expected: The expected snapshot, written inline as a multi-line
///     string literal.
///   - comment: Optional context shown alongside the diff.
func expectStringMatch(
  _ actual: String,
  _ expected: String,
  _ comment: Comment? = nil,
  sourceLocation: SourceLocation = #_sourceLocation
) {
  guard actual != expected else { return }
  let diff = renderUnifiedDiff(expected: expected, actual: actual)
  let prefix = comment.map { "\($0): " } ?? ""
  Issue.record(
    Comment(rawValue: "\(prefix)snapshot mismatch:\n\(diff)"),
    sourceLocation: sourceLocation
  )
}

/// Renders a unified-diff-style listing of the difference between two
/// multi-line strings. Lines unchanged are prefixed with two spaces;
/// removed lines (present in expected, absent in actual) are prefixed
/// with `-`; added lines (present in actual, absent in expected) are
/// prefixed with `+`.
///
/// The implementation walks both line lists and matches positions by
/// the longest common subsequence — same algorithm as `git diff`'s
/// `--minimal` mode. Output cap: 200 rendered lines so a wholly-broken
/// snapshot doesn't flood the test log.
func renderUnifiedDiff(expected: String, actual: String) -> String {
  let expectedLines = expected.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
  let actualLines = actual.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

  let lcs = longestCommonSubsequence(expectedLines, actualLines)
  var out: [String] = []
  var i = 0
  var j = 0
  var k = 0
  while i < expectedLines.count || j < actualLines.count {
    if
      k < lcs.count, i < expectedLines.count, expectedLines[i] == lcs[k],
      j < actualLines.count, actualLines[j] == lcs[k] {
      out.append("  \(lcs[k])")
      i += 1; j += 1; k += 1
    } else if i < expectedLines.count, k >= lcs.count || expectedLines[i] != lcs[k] {
      out.append("- \(expectedLines[i])")
      i += 1
    } else if j < actualLines.count, k >= lcs.count || actualLines[j] != lcs[k] {
      out.append("+ \(actualLines[j])")
      j += 1
    }
  }

  if out.count > 200 {
    let head = out.prefix(180)
    let tail = out.suffix(15)
    return (head + ["… [\(out.count - 195) lines elided] …"] + tail).joined(separator: "\n")
  }
  return out.joined(separator: "\n")
}

/// Standard O(mn) longest-common-subsequence algorithm. Adequate for
/// snapshots that rarely exceed a few dozen lines.
private func longestCommonSubsequence(_ a: [String], _ b: [String]) -> [String] {
  let m = a.count
  let n = b.count
  if m == 0 || n == 0 { return [] }
  var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
  for i in 1...m {
    for j in 1...n {
      if a[i - 1] == b[j - 1] {
        dp[i][j] = dp[i - 1][j - 1] + 1
      } else {
        dp[i][j] = Swift.max(dp[i - 1][j], dp[i][j - 1])
      }
    }
  }
  var result: [String] = []
  var i = m
  var j = n
  while i > 0, j > 0 {
    if a[i - 1] == b[j - 1] {
      result.append(a[i - 1])
      i -= 1; j -= 1
    } else if dp[i - 1][j] > dp[i][j - 1] {
      i -= 1
    } else {
      j -= 1
    }
  }
  return result.reversed()
}
