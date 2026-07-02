import Foundation
import Observation

struct WorktreeSurfaceTitle: Equatable {
  enum Source: Int, CaseIterable, Hashable {
    case paneOverride
    case agentSession
    case terminal
  }

  let source: Source
  let value: String
}

/// Per-surface observable kept off `GhosttySurfaceState` so the Ghostty bridge
/// remains a pure mirror of `ghostty_action_*` payloads.
@MainActor
@Observable
final class WorktreeSurfaceState {
  /// Mirror of `WorktreeTerminalState.hasUnseenNotification(forSurfaceID:)`.
  var hasUnseenNotification: Bool = false

  /// Ordered title candidates from user overrides, agent integrations, and the terminal.
  private(set) var titles: [WorktreeSurfaceTitle] = []

  @discardableResult
  func setTitle(_ title: String?, source: WorktreeSurfaceTitle.Source) -> Bool {
    let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let normalized = trimmed.isEmpty ? nil : trimmed
    let nextTitles: [WorktreeSurfaceTitle]
    if let normalized {
      var titlesBySource = Dictionary(uniqueKeysWithValues: titles.map { ($0.source, $0.value) })
      titlesBySource[source] = normalized
      nextTitles = Self.orderedTitles(from: titlesBySource)
    } else {
      nextTitles = titles.filter { $0.source != source }
    }
    guard titles != nextTitles else { return false }
    titles = nextTitles
    return true
  }

  func preferredTitle(
    sources: [WorktreeSurfaceTitle.Source] = WorktreeSurfaceTitle.Source.allCases,
    fallback: String? = nil
  ) -> String? {
    let allowed = Set(sources)
    if let title = titles.first(where: { allowed.contains($0.source) })?.value {
      return title
    }
    let fallback = fallback?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return fallback.isEmpty ? nil : fallback
  }

  private static func orderedTitles(
    from titlesBySource: [WorktreeSurfaceTitle.Source: String]
  ) -> [WorktreeSurfaceTitle] {
    WorktreeSurfaceTitle.Source.allCases.compactMap { source in
      titlesBySource[source].map { WorktreeSurfaceTitle(source: source, value: $0) }
    }
  }
}
