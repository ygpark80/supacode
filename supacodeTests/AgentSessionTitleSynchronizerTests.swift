import Foundation
import Testing

@testable import supacode

struct AgentSessionTitleSynchronizerTests {
  // Real Claude Code transcript shape: interleaved records, the title lives in
  // `{"type":"ai-title","aiTitle":...,"sessionId":...}` — NOT in sessions/<pid>.json.
  private static let sessionID = "ed0ad8b8-5294-408c-8a23-a21335664881"

  @Test func returnsNewestAiTitleForSession() {
    let jsonl = """
      {"type":"user","sessionId":"\(Self.sessionID)"}
      {"type":"ai-title","aiTitle":"first draft","sessionId":"\(Self.sessionID)"}
      {"type":"assistant","sessionId":"\(Self.sessionID)"}
      {"type":"ai-title","aiTitle":"ygpark80/supacode #1 계속하기","sessionId":"\(Self.sessionID)"}
      """
    #expect(
      AgentSessionTitleSynchronizer.parseLatestClaudeAiTitle(fromJSONL: jsonl, sessionID: Self.sessionID)
        == "ygpark80/supacode #1 계속하기"
    )
  }

  @Test func ignoresAiTitleFromOtherSessions() {
    let other = "00000000-0000-0000-0000-000000000000"
    let jsonl = """
      {"type":"ai-title","aiTitle":"mine","sessionId":"\(Self.sessionID)"}
      {"type":"ai-title","aiTitle":"someone else's newer title","sessionId":"\(other)"}
      """
    #expect(
      AgentSessionTitleSynchronizer.parseLatestClaudeAiTitle(fromJSONL: jsonl, sessionID: Self.sessionID)
        == "mine"
    )
  }

  @Test func returnsNilWhenNoAiTitle() {
    let jsonl = """
      {"type":"user","sessionId":"\(Self.sessionID)"}
      {"type":"assistant","sessionId":"\(Self.sessionID)"}
      """
    #expect(
      AgentSessionTitleSynchronizer.parseLatestClaudeAiTitle(fromJSONL: jsonl, sessionID: Self.sessionID) == nil
    )
  }

  @Test func laterBlankTitleDoesNotClobberEarlierTitle() {
    let jsonl = """
      {"type":"ai-title","aiTitle":"good title","sessionId":"\(Self.sessionID)"}
      {"type":"ai-title","aiTitle":"   ","sessionId":"\(Self.sessionID)"}
      """
    #expect(
      AgentSessionTitleSynchronizer.parseLatestClaudeAiTitle(fromJSONL: jsonl, sessionID: Self.sessionID)
        == "good title"
    )
  }

  @Test func skipsMalformedAndUnrelatedLines() {
    let jsonl = """
      not json at all
      {"type":"system"}
      {"type":"ai-title","aiTitle":"real","sessionId":"\(Self.sessionID)"}
      {"broken":
      """
    #expect(
      AgentSessionTitleSynchronizer.parseLatestClaudeAiTitle(fromJSONL: jsonl, sessionID: Self.sessionID)
        == "real"
    )
  }
}
