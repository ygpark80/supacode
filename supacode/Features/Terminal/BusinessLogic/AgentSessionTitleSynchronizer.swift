import Darwin
import Foundation
import SupacodeSettingsShared

@MainActor
final class AgentSessionTitleSynchronizer {
  private nonisolated struct TitleProvider: Sendable {
    let readTitle: @Sendable (Session) -> String?
  }

  private let sleep: @Sendable (Duration) async throws -> Void
  private let providers: [SkillAgent: TitleProvider]
  private var tasks: [UUID: Task<Void, Never>] = [:]
  private var sessions: [UUID: Session] = [:]

  private static let pollInterval: Duration = .seconds(1)
  /// Supacode can itself be launched from inside an agent terminal while testing.
  /// Ghostty child shells inherit the app process environment, so remove only
  /// session-scoped variables known to misattribute nested agent session titles.
  /// Do not strip broad prefixes such as `ANTHROPIC_` or `OPENAI_`: those can be
  /// auth/config inputs the user expects child shells to keep.
  private nonisolated static let inheritedSessionVariablesByAgent: [(agent: SkillAgent, variables: [String])] = [
    (
      .codex,
      [
        "CODEX_CI",
        "CODEX_THREAD_ID",
      ]
    )
  ]

  private nonisolated struct Session: Equatable, Sendable {
    let agent: SkillAgent
    let pid: pid_t
    let sessionID: String?
  }

  private nonisolated struct SessionEventData: Decodable {
    let sessionID: String?

    private enum CodingKeys: String, CodingKey {
      case sessionID = "session_id"
    }
  }

  private nonisolated struct ClaudeSessionRegistry: Decodable {
    let sessionId: String?
  }

  private nonisolated struct ClaudeAiTitleEntry: Decodable {
    let type: String
    let aiTitle: String?
    let sessionId: String?
  }

  private nonisolated struct CodexSessionIndexRecord: Decodable {
    let id: String
    let threadName: String?

    private enum CodingKeys: String, CodingKey {
      case id
      case threadName = "thread_name"
    }
  }

  private nonisolated struct CodexRolloutEvent: Decodable {
    let type: String
    let payload: CodexRolloutPayload?
  }

  private nonisolated struct CodexRolloutPayload: Decodable {
    let type: String?
    let threadName: String?

    private enum CodingKeys: String, CodingKey {
      case type
      case threadName = "thread_name"
    }
  }

  private nonisolated struct CodexSnapshotCandidate {
    let url: URL
    let timestamp: Int64
    let threadID: String
  }

  init(sleep: @escaping @Sendable (Duration) async throws -> Void) {
    self.sleep = sleep
    self.providers = [
      .claude: TitleProvider(
        readTitle: Self.readClaudeSessionTitle(session:)
      ),
      .codex: TitleProvider(
        readTitle: Self.readCodexSessionTitle(session:)
      ),
    ]
  }

  deinit {
    for task in tasks.values { task.cancel() }
  }

  nonisolated static func sanitizeInheritedSessionEnvironment() {
    for key in inheritedSessionVariablesByAgent.flatMap(\.variables) {
      unsetenv(key)
    }
  }

  nonisolated static func readCodexSessionTitle(
    surfaceID: UUID,
    sinceMilliseconds: Int64
  ) -> String? {
    let databaseURL = codexDatabaseURL()
    guard FileManager.default.fileExists(atPath: databaseURL.path(percentEncoded: false)) else {
      return nil
    }
    guard let threadID = codexThreadID(surfaceID: surfaceID, sinceMilliseconds: sinceMilliseconds) else {
      return nil
    }
    return readCodexSessionTitle(threadID: threadID, databaseURL: databaseURL)
  }

  func update(
    from event: AgentHookEvent,
    surfaceExists: (UUID) -> Bool,
    applyTitle: @escaping @MainActor (String?, UUID, SkillAgent) -> Void
  ) {
    guard let agent = SkillAgent(rawValue: event.agent) else { return }

    if event.eventName == .sessionEnd {
      stop(surfaceID: event.surfaceID, clearingTitle: true, applyTitle: applyTitle)
      return
    }

    guard let pid = event.pid else { return }
    let sessionID = event.decodeData(SessionEventData.self)?.sessionID
    start(
      surfaceID: event.surfaceID,
      session: Session(
        agent: agent,
        pid: pid,
        sessionID: Self.normalizedTitle(sessionID)
      ),
      provider: providers[agent],
      surfaceExists: surfaceExists,
      applyTitle: applyTitle
    )
  }

  func cancel(surfaceIDs: Set<UUID>, applyTitle: (String?, UUID, SkillAgent) -> Void) {
    for surfaceID in surfaceIDs {
      stop(surfaceID: surfaceID, clearingTitle: true, applyTitle: applyTitle)
    }
  }

  private func start(
    surfaceID: UUID,
    session: Session,
    provider: TitleProvider?,
    surfaceExists: (UUID) -> Bool,
    applyTitle: @escaping @MainActor (String?, UUID, SkillAgent) -> Void
  ) {
    guard surfaceExists(surfaceID) else { return }
    if sessions[surfaceID] == session, tasks[surfaceID] != nil {
      return
    }

    stop(surfaceID: surfaceID, clearingTitle: false, applyTitle: applyTitle)
    sessions[surfaceID] = session
    let fallbackTitle = Self.fallbackTitle(for: session, surfaceID: surfaceID)
    applyTitle(fallbackTitle, surfaceID, session.agent)
    let sleep = sleep
    tasks[surfaceID] = Task.detached { [weak self] in
      var lastTitle: String? = fallbackTitle
      while !Task.isCancelled {
        guard Self.isProcessAlive(session.pid) else { break }
        let title = provider?.readTitle(session) ?? fallbackTitle
        if title != lastTitle {
          lastTitle = title
          await applyTitle(title, surfaceID, session.agent)
        }
        try? await sleep(Self.pollInterval)
      }

      guard !Task.isCancelled else { return }
      await self?.finish(surfaceID: surfaceID, session: session, applyTitle: applyTitle)
    }
  }

  private func stop(surfaceID: UUID, clearingTitle: Bool, applyTitle: (String?, UUID, SkillAgent) -> Void) {
    tasks.removeValue(forKey: surfaceID)?.cancel()
    let session = sessions.removeValue(forKey: surfaceID)
    if clearingTitle {
      if let session {
        applyTitle(nil, surfaceID, session.agent)
      }
    }
  }

  private func finish(
    surfaceID: UUID,
    session: Session,
    applyTitle: @MainActor @Sendable (String?, UUID, SkillAgent) -> Void
  ) {
    guard sessions[surfaceID] == session else { return }
    tasks.removeValue(forKey: surfaceID)
    sessions.removeValue(forKey: surfaceID)
    applyTitle(nil, surfaceID, session.agent)
  }

  private nonisolated static func claudeSessionURL(pid: pid_t) -> URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appending(path: ".claude/sessions", directoryHint: .isDirectory)
      .appending(path: "\(pid).json", directoryHint: .notDirectory)
  }

  /// Claude Code stores the human-facing session title as `ai-title` records in the
  /// transcript `~/.claude/projects/<encoded-cwd>/<sessionId>.jsonl`, NOT as a `name`
  /// field in `sessions/<pid>.json` (that file is a process registry with no title).
  private nonisolated static func readClaudeSessionTitle(session: Session) -> String? {
    guard let sessionID = claudeSessionID(session: session),
      let transcriptURL = claudeTranscriptURL(sessionID: sessionID)
    else {
      return nil
    }
    let output =
      runProcess(
        executableURL: URL(filePath: "/usr/bin/tail"),
        arguments: ["-n", "500", transcriptURL.path(percentEncoded: false)]
      )
      ?? (try? String(contentsOf: transcriptURL, encoding: .utf8))
    guard let output else { return nil }
    return parseLatestClaudeAiTitle(fromJSONL: output, sessionID: sessionID)
  }

  private nonisolated static func claudeSessionID(session: Session) -> String? {
    if let sessionID = session.sessionID { return sessionID }
    guard let data = try? Data(contentsOf: claudeSessionURL(pid: session.pid)),
      let registry = try? JSONDecoder().decode(ClaudeSessionRegistry.self, from: data)
    else {
      return nil
    }
    return normalizedTitle(registry.sessionId)
  }

  /// The project dir name encodes cwd, so locate the transcript by the unique
  /// `<sessionID>.jsonl` filename instead of reconstructing the encoding.
  private nonisolated static func claudeTranscriptURL(sessionID: String) -> URL? {
    let projectsRoot = FileManager.default.homeDirectoryForCurrentUser
      .appending(path: ".claude/projects", directoryHint: .isDirectory)
    guard
      let projectDirs = try? FileManager.default.contentsOfDirectory(
        at: projectsRoot,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
      )
    else {
      return nil
    }
    let fileName = "\(sessionID).jsonl"
    for dir in projectDirs {
      let candidate = dir.appending(path: fileName, directoryHint: .notDirectory)
      if FileManager.default.fileExists(atPath: candidate.path(percentEncoded: false)) {
        return candidate
      }
    }
    return nil
  }

  /// Newest non-blank `ai-title` for the session wins. Pure + unit-tested.
  nonisolated static func parseLatestClaudeAiTitle(fromJSONL contents: String, sessionID: String) -> String? {
    let decoder = JSONDecoder()
    var title: String?
    for line in contents.split(separator: "\n", omittingEmptySubsequences: true) {
      guard let data = String(line).data(using: .utf8),
        let entry = try? decoder.decode(ClaudeAiTitleEntry.self, from: data),
        entry.type == "ai-title",
        entry.sessionId == sessionID
      else {
        continue
      }
      // A later blank title must not clobber a good earlier one.
      if let normalized = normalizedTitle(entry.aiTitle) {
        title = normalized
      }
    }
    return title
  }

  private nonisolated static func readCodexSessionTitle(session: Session) -> String? {
    let databaseURL = codexDatabaseURL()
    guard FileManager.default.fileExists(atPath: databaseURL.path(percentEncoded: false)) else {
      return nil
    }

    if let threadID = session.sessionID ?? codexThreadID(pid: session.pid) {
      return readCodexSessionTitle(threadID: threadID, databaseURL: databaseURL)
    } else {
      return nil
    }
  }

  private nonisolated static func codexDatabaseURL() -> URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appending(path: ".codex/state_5.sqlite", directoryHint: .notDirectory)
  }

  private nonisolated static func readCodexSessionTitle(threadID: String, databaseURL: URL) -> String? {
    if let title = readCodexSessionIndexTitle(threadID: threadID) {
      return title
    }
    if let rolloutURL = codexRolloutURL(databaseURL: databaseURL, threadID: threadID),
      let title = readCodexRolloutTitle(rolloutURL: rolloutURL)
    {
      return title
    }
    return readCodexSQLiteTitle(
      databaseURL: databaseURL,
      sql: """
        select title from threads
        where id = \(sqlString(threadID))
        limit 1;
        """
    )
  }

  private nonisolated static func readCodexSQLiteTitle(databaseURL: URL, sql: String) -> String? {
    guard let output = runSQLite(databaseURL: databaseURL, sql: sql) else { return nil }
    let title = output.trimmingCharacters(in: .whitespacesAndNewlines)
    return title.isEmpty ? nil : title
  }

  private nonisolated static func codexRolloutURL(databaseURL: URL, threadID: String) -> URL? {
    let sql = """
      select rollout_path from threads
      where id = \(sqlString(threadID))
      limit 1;
      """
    guard let output = runSQLite(databaseURL: databaseURL, sql: sql) else { return nil }
    let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !path.isEmpty else { return nil }
    return URL(filePath: path)
  }

  private nonisolated static func readCodexSessionIndexTitle(threadID: String) -> String? {
    let indexURL = FileManager.default.homeDirectoryForCurrentUser
      .appending(path: ".codex/session_index.jsonl", directoryHint: .notDirectory)
    guard let contents = try? String(contentsOf: indexURL, encoding: .utf8) else { return nil }
    let decoder = JSONDecoder()
    var title: String?
    for line in contents.split(separator: "\n", omittingEmptySubsequences: true) {
      guard let data = String(line).data(using: .utf8),
        let record = try? decoder.decode(CodexSessionIndexRecord.self, from: data),
        record.id == threadID
      else {
        continue
      }
      title = normalizedTitle(record.threadName)
    }
    return title
  }

  private nonisolated static func readCodexRolloutTitle(rolloutURL: URL) -> String? {
    guard FileManager.default.fileExists(atPath: rolloutURL.path(percentEncoded: false)) else {
      return nil
    }
    let output =
      runProcess(
        executableURL: URL(filePath: "/usr/bin/tail"),
        arguments: ["-n", "2000", rolloutURL.path(percentEncoded: false)]
      )
      ?? (try? String(contentsOf: rolloutURL, encoding: .utf8))
    guard let output else { return nil }

    let decoder = JSONDecoder()
    var title: String?
    for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
      guard let data = String(line).data(using: .utf8),
        let event = try? decoder.decode(CodexRolloutEvent.self, from: data),
        event.type == "event_msg",
        event.payload?.type == "thread_name_updated"
      else {
        continue
      }
      title = normalizedTitle(event.payload?.threadName)
    }
    return title
  }

  private nonisolated static func normalizedTitle(_ title: String?) -> String? {
    let title = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return title.isEmpty ? nil : title
  }

  private nonisolated static func fallbackTitle(for session: Session, surfaceID: UUID) -> String {
    "Session \(shortIdentifier(session.sessionID ?? surfaceID.uuidString))"
  }

  private nonisolated static func shortIdentifier(_ value: String) -> String {
    let compact =
      value
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .filter { $0.isLetter || $0.isNumber }
    let source = compact.isEmpty ? value.replacingOccurrences(of: "-", with: "") : String(compact)
    return String(source.prefix(8)).uppercased()
  }

  private nonisolated static func codexThreadID(pid: pid_t) -> String? {
    guard let output = runProcess(executableURL: URL(filePath: "/bin/ps"), arguments: ["eww", "-p", "\(pid)"]) else {
      return nil
    }
    let prefix = "CODEX_THREAD_ID="
    return output.split(whereSeparator: \.isWhitespace)
      .first { $0.hasPrefix(prefix) }
      .map { String($0.dropFirst(prefix.count)) }
  }

  private nonisolated static func codexThreadID(surfaceID: UUID, sinceMilliseconds: Int64) -> String? {
    let directoryURL = FileManager.default.homeDirectoryForCurrentUser
      .appending(path: ".codex/shell_snapshots", directoryHint: .isDirectory)
    guard
      let urls = try? FileManager.default.contentsOfDirectory(
        at: directoryURL,
        includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
        options: [.skipsHiddenFiles]
      )
    else {
      return nil
    }

    let surfaceToken = "SUPACODE_SURFACE_ID=\(surfaceID.uuidString)"
    let candidates = urls.compactMap { url -> CodexSnapshotCandidate? in
      guard url.pathExtension == "sh" else { return nil }
      guard let threadID = url.lastPathComponent.split(separator: ".").first.map(String.init) else { return nil }
      let timestamp =
        codexSnapshotTimestampMilliseconds(url: url)
        ?? codexFileModificationMilliseconds(url: url)
        ?? 0
      guard timestamp >= sinceMilliseconds else { return nil }
      return CodexSnapshotCandidate(url: url, timestamp: timestamp, threadID: threadID)
    }
    .sorted { $0.timestamp > $1.timestamp }

    for candidate in candidates {
      guard let contents = try? String(contentsOf: candidate.url, encoding: .utf8) else { continue }
      if contents.range(of: surfaceToken, options: .caseInsensitive) != nil {
        return candidate.threadID
      }
    }
    return nil
  }

  private nonisolated static func codexSnapshotTimestampMilliseconds(url: URL) -> Int64? {
    let parts = url.deletingPathExtension().lastPathComponent.split(separator: ".")
    guard parts.count >= 2, let nanoseconds = Int64(parts[1]) else { return nil }
    return nanoseconds / 1_000_000
  }

  private nonisolated static func codexFileModificationMilliseconds(url: URL) -> Int64? {
    guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
      let date = values.contentModificationDate
    else {
      return nil
    }
    return Int64(date.timeIntervalSince1970 * 1000)
  }

  private nonisolated static func runSQLite(databaseURL: URL, sql: String) -> String? {
    runProcess(
      executableURL: URL(filePath: "/usr/bin/sqlite3"),
      arguments: ["-readonly", databaseURL.path(percentEncoded: false), sql]
    )
  }

  private nonisolated static func runProcess(executableURL: URL, arguments: [String]) -> String? {
    let process = Process()
    process.executableURL = executableURL
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    do {
      try process.run()
      process.waitUntilExit()
    } catch {
      return nil
    }
    guard process.terminationStatus == 0 else { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8)
  }

  private nonisolated static func sqlString(_ value: String) -> String {
    "'\(value.replacingOccurrences(of: "'", with: "''"))'"
  }

  private nonisolated static func isProcessAlive(_ pid: pid_t) -> Bool {
    kill(pid, 0) == 0 || errno == EPERM
  }
}
