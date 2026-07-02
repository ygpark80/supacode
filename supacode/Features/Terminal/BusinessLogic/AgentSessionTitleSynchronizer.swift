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
    guard let workingDirectory = session.workingDirectory,
      !workingDirectory.isEmpty
    else {
      return nil
    }
    let databaseURL = FileManager.default.homeDirectoryForCurrentUser
      .appending(path: ".codex/state_5.sqlite", directoryHint: .notDirectory)
    guard FileManager.default.fileExists(atPath: databaseURL.path(percentEncoded: false)) else {
      return nil
    }
    let sql = """
      select title from threads
      where archived = 0 and cwd = \(sqlString(workingDirectory))
      order by updated_at_ms desc
      limit 1;
      """
    guard let output = runSQLite(databaseURL: databaseURL, sql: sql) else { return nil }
    let title = output.trimmingCharacters(in: .whitespacesAndNewlines)
    return title.isEmpty ? nil : title
  }

  private nonisolated static func runSQLite(databaseURL: URL, sql: String) -> String? {
    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/sqlite3")
    process.arguments = ["-readonly", databaseURL.path(percentEncoded: false), sql]
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
