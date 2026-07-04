import SupacodeSettingsShared
import Testing

struct SkillAgentTests {
  @Test func infersClaudeFromTitleVariants() {
    #expect(SkillAgent.agent(fromTerminalTitle: "Claude Code") == .claude)
    #expect(SkillAgent.agent(fromTerminalTitle: "Claude Code /Users/x/proj") == .claude)
    #expect(SkillAgent.agent(fromTerminalTitle: "Claude Code ~/proj") == .claude)
    #expect(SkillAgent.agent(fromTerminalTitle: "✻ Claude Code") == .claude)
    #expect(SkillAgent.agent(fromTerminalTitle: "* Claude Code") == .claude)
  }

  @Test func infersOpencodeFromTitlePrefixes() {
    #expect(SkillAgent.agent(fromTerminalTitle: "OC | build") == .opencode)
    #expect(SkillAgent.agent(fromTerminalTitle: "OpenCode | build") == .opencode)
  }

  // A shell / working-directory title is the "no agent is running" signal that
  // clears the pane icon when an agent exits — it must resolve to nil.
  @Test func plainShellTitleInfersNoAgent() {
    #expect(SkillAgent.agent(fromTerminalTitle: "supacode") == nil)
    #expect(SkillAgent.agent(fromTerminalTitle: "~/Projects/supacode") == nil)
    #expect(SkillAgent.agent(fromTerminalTitle: "-zsh") == nil)
    #expect(SkillAgent.agent(fromTerminalTitle: "Codexish other") == nil)
  }

  @Test func blankOrMissingTitleInfersNoAgent() {
    #expect(SkillAgent.agent(fromTerminalTitle: nil) == nil)
    #expect(SkillAgent.agent(fromTerminalTitle: "") == nil)
    #expect(SkillAgent.agent(fromTerminalTitle: "   ") == nil)
  }

  @Test func trimsSurroundingWhitespaceBeforeInferring() {
    #expect(SkillAgent.agent(fromTerminalTitle: "  Claude Code  ") == .claude)
  }
}
