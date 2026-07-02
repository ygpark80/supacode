import Foundation
import Observation
import SupacodeSettingsShared

struct WorktreeSurfaceTitle: Equatable {
  enum Source: Hashable {
    case paneOverride
    case agentSession(SkillAgent)
    case terminal

    var priority: Int {
      switch self {
      case .paneOverride: 0
      case .agentSession(.codex): 1
      case .agentSession: 1
      case .terminal: 2
      }
    }

    var sortKey: String {
      switch self {
      case .paneOverride: "paneOverride"
      case .agentSession(let agent): "agentSession:\(agent.rawValue)"
      case .terminal: "terminal"
      }
    }
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
    where include: (WorktreeSurfaceTitle.Source) -> Bool = { _ in true },
    fallback: String? = nil
  ) -> String? {
    if let title = titles.first(where: { include($0.source) })?.value {
      return title
    }
    let fallback = fallback?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return fallback.isEmpty ? nil : fallback
  }

  func title(for source: WorktreeSurfaceTitle.Source) -> String? {
    titles.first(where: { $0.source == source })?.value
  }

  private static func orderedTitles(
    from titlesBySource: [WorktreeSurfaceTitle.Source: String]
  ) -> [WorktreeSurfaceTitle] {
    titlesBySource
      .map { WorktreeSurfaceTitle(source: $0.key, value: $0.value) }
      .sorted {
        if $0.source.priority != $1.source.priority {
          return $0.source.priority < $1.source.priority
        }
        return $0.source.sortKey < $1.source.sortKey
      }
  }
}
