import Observation

/// Per-surface observable kept off `GhosttySurfaceState` so the Ghostty bridge
/// remains a pure mirror of `ghostty_action_*` payloads.
@MainActor
@Observable
final class WorktreeSurfaceState {
  /// Mirror of `WorktreeTerminalState.hasUnseenNotification(forSurfaceID:)`.
  var hasUnseenNotification: Bool = false

  /// User- or integration-supplied pane label. Nil means follow the terminal
  /// title reported by Ghostty.
  var paneTitle: String?

  /// Session title reported by a coding-agent integration. Kept below a manual
  /// pane title and above the raw terminal title.
  var agentSessionTitle: String?

  /// Live terminal title reported by Ghostty. Used as the default pane label
  /// when no explicit pane title is set.
  var terminalTitle: String?
}
