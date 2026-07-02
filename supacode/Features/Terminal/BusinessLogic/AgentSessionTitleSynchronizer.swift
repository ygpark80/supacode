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

  private nonisolated struct Session: Equatable, Sendable {
    let agent: SkillAgent
    let pid: pid_t
    let workingDirectory: String?
  }

  private nonisolated struct ClaudeSessionFile: Decodable {
    let name: String?
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

  func update(
    from event: AgentHookEvent,
    surfaceExists: (UUID) -> Bool,
    workingDirectory: (UUID) -> String?,
    applyTitle: @escaping @MainActor (String?, UUID, SkillAgent) -> Void
  ) {
    guard let agent = SkillAgent(rawValue: event.agent),
      let provider = providers[agent]
    else {
      return
    }

    if event.eventName == .sessionEnd {
      stop(surfaceID: event.surfaceID, clearingTitle: true, applyTitle: applyTitle)
      return
    }

    guard let pid = event.pid else { return }
    start(
      surfaceID: event.surfaceID,
      session: Session(agent: agent, pid: pid, workingDirectory: workingDirectory(event.surfaceID)),
      provider: provider,
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
    provider: TitleProvider,
    surfaceExists: (UUID) -> Bool,
    applyTitle: @escaping @MainActor (String?, UUID, SkillAgent) -> Void
  ) {
    guard surfaceExists(surfaceID) else { return }
    if sessions[surfaceID] == session, tasks[surfaceID] != nil {
      return
    }

    stop(surfaceID: surfaceID, clearingTitle: false, applyTitle: applyTitle)
    sessions[surfaceID] = session
    let sleep = sleep
    tasks[surfaceID] = Task.detached { [weak self] in
      var lastTitle: String?
      while !Task.isCancelled {
        guard Self.isProcessAlive(session.pid) else { break }
        let title = provider.readTitle(session)
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

  private nonisolated static func readClaudeSessionTitle(session: Session) -> String? {
    guard let data = try? Data(contentsOf: claudeSessionURL(pid: session.pid)),
      let session = try? JSONDecoder().decode(ClaudeSessionFile.self, from: data)
    else {
      return nil
    }
    let title = session.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return title.isEmpty ? nil : title
  }

  private nonisolated static func readCodexSessionTitle(session: Session) -> String? {
    let databaseURL = FileManager.default.homeDirectoryForCurrentUser
      .appending(path: ".codex/state_5.sqlite", directoryHint: .notDirectory)
    guard FileManager.default.fileExists(atPath: databaseURL.path(percentEncoded: false)) else {
      return nil
    }

    if let threadID = codexThreadID(pid: session.pid) {
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
    } else if let workingDirectory = session.workingDirectory,
      !workingDirectory.isEmpty
    {
      return readCodexSQLiteTitle(
        databaseURL: databaseURL,
        sql: """
          select title from threads
          where archived = 0 and cwd = \(sqlString(workingDirectory))
          order by updated_at_ms desc
          limit 1;
          """
      )
    } else {
      return nil
    }
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

  private nonisolated static func codexThreadID(pid: pid_t) -> String? {
    guard let output = runProcess(executableURL: URL(filePath: "/bin/ps"), arguments: ["eww", "-p", "\(pid)"]) else {
      return nil
    }
    let prefix = "CODEX_THREAD_ID="
    return output.split(whereSeparator: \.isWhitespace)
      .first { $0.hasPrefix(prefix) }
      .map { String($0.dropFirst(prefix.count)) }
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
