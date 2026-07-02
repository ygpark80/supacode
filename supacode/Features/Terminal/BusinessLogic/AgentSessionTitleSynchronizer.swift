import Darwin
import Foundation
import SupacodeSettingsShared

@MainActor
final class AgentSessionTitleSynchronizer {
  private struct TitleProvider {
    let sessionURL: (pid_t) -> URL
    let readTitle: (URL) -> String?
  }

  private let sleep: @Sendable (Duration) async throws -> Void
  private let providers: [SkillAgent: TitleProvider]
  private var tasks: [UUID: Task<Void, Never>] = [:]
  private var sessions: [UUID: Session] = [:]

  private static let pollInterval: Duration = .seconds(1)

  private struct Session: Equatable {
    let agent: SkillAgent
    let pid: pid_t
  }

  private struct ClaudeSessionFile: Decodable {
    let name: String?
  }

  init(sleep: @escaping @Sendable (Duration) async throws -> Void) {
    self.sleep = sleep
    self.providers = [
      .claude: TitleProvider(
        sessionURL: Self.claudeSessionURL(pid:),
        readTitle: Self.readClaudeSessionTitle(at:)
      )
    ]
  }

  deinit {
    for task in tasks.values { task.cancel() }
  }

  func update(
    from event: AgentHookEvent,
    surfaceExists: (UUID) -> Bool,
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
      session: Session(agent: agent, pid: pid),
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
    let sessionURL = provider.sessionURL(session.pid)
    let sleep = sleep
    tasks[surfaceID] = Task { [weak self] in
      var lastTitle: String?
      while !Task.isCancelled {
        guard Self.isProcessAlive(session.pid) else { break }
        let title = provider.readTitle(sessionURL)
        if title != lastTitle {
          lastTitle = title
          applyTitle(title, surfaceID, session.agent)
        }
        try? await sleep(Self.pollInterval)
      }

      guard !Task.isCancelled else { return }
      self?.finish(surfaceID: surfaceID, session: session, applyTitle: applyTitle)
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

  private func finish(surfaceID: UUID, session: Session, applyTitle: (String?, UUID, SkillAgent) -> Void) {
    guard sessions[surfaceID] == session else { return }
    tasks.removeValue(forKey: surfaceID)
    sessions.removeValue(forKey: surfaceID)
    applyTitle(nil, surfaceID, session.agent)
  }

  private static func claudeSessionURL(pid: pid_t) -> URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appending(path: ".claude/sessions", directoryHint: .isDirectory)
      .appending(path: "\(pid).json", directoryHint: .notDirectory)
  }

  private static func readClaudeSessionTitle(at url: URL) -> String? {
    guard let data = try? Data(contentsOf: url),
      let session = try? JSONDecoder().decode(ClaudeSessionFile.self, from: data)
    else {
      return nil
    }
    let title = session.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return title.isEmpty ? nil : title
  }

  private static func isProcessAlive(_ pid: pid_t) -> Bool {
    kill(pid, 0) == 0 || errno == EPERM
  }
}
