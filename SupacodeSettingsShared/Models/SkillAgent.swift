import Foundation

public nonisolated enum SkillAgent: String, Equatable, Sendable, CaseIterable, Codable {
  case claude
  case codex
  case copilot
  case kimi
  case kiro
  case opencode
  // swiftlint:disable:next identifier_name
  case pi

  /// Path under the user's home where the agent stores its config
  /// (e.g. `.claude`, `.codex`, `.copilot`, `.kimi`, `.kiro`, `.pi/agent`, `.config/opencode`).
  public var configDirectoryName: String {
    switch self {
    case .claude: ".claude"
    case .codex: ".codex"
    case .copilot: ".copilot"
    case .kimi: ".kimi"
    case .kiro: ".kiro"
    case .opencode: ".config/opencode"
    case .pi: ".pi/agent"
    }
  }

  /// User-facing name (e.g. "Claude Code", "Codex").
  public var displayName: String {
    switch self {
    case .claude: "Claude Code"
    case .codex: "Codex"
    case .copilot: "Copilot CLI"
    case .kimi: "Kimi CLI"
    case .kiro: "Kiro"
    case .opencode: "OpenCode"
    case .pi: "Pi"
    }
  }

  /// Asset catalog name for the agent's logo mark.
  public var assetName: String {
    switch self {
    case .claude: "claude-code-mark"
    case .codex: "codex-mark"
    case .copilot: "copilot-mark"
    case .kimi: "kimi-mark"
    case .kiro: "kiro-mark"
    case .opencode: "opencode-mark"
    case .pi: "pi-mark"
    }
  }

  /// The agent inferred from a terminal's OSC title, or `nil` for a plain shell
  /// title. Title-setting agents (`claude`, `opencode`) can be tracked through
  /// this: the title reverts to the shell's when the agent exits, so a `nil`
  /// result is the authoritative "agent is no longer running" signal.
  public static func agent(fromTerminalTitle title: String?) -> SkillAgent? {
    guard let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
      return nil
    }
    if title.hasPrefix("OC |") || title.hasPrefix("OpenCode |") {
      return .opencode
    }
    if title == "Claude Code"
      || title.hasPrefix("Claude Code ")
      || title.hasPrefix("Claude Code /")
      || title.hasPrefix("✻ Claude Code")
      || title.hasPrefix("* Claude Code")
    {
      return .claude
    }
    return nil
  }
}
