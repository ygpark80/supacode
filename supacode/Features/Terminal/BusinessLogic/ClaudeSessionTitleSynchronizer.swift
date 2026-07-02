import Darwin
import Foundation
import SupacodeSettingsShared

@MainActor
final class ClaudeSessionTitleSynchronizer {
  private let sleep: @Sendable (Duration) async throws -> Void
  private var tasks: [UUID: Task<Void, Never>] = [:]
  private var pids: [UUID: pid_t] = [:]

  private static let pollInterval: Duration = .seconds(1)

  private struct SessionFile: Decodable {
    let name: String?
  }

  init(sleep: @escaping @Sendable (Duration) async throws -> Void) {
    self.sleep = sleep
  }

  deinit {
    for task in tasks.values { task.cancel() }
  }

  func update(
    from event: AgentHookEvent,
    surfaceExists: (UUID) -> Bool,
    applyTitle: @escaping @MainActor (String?, UUID) -> Void
  ) {
    guard event.agent == SkillAgent.claude.rawValue else { return }

    if event.eventName == .sessionEnd {
      stop(surfaceID: event.surfaceID, clearingTitle: true, applyTitle: applyTitle)
      return
    }

    guard let pid = event.pid else { return }
    start(surfaceID: event.surfaceID, pid: pid, surfaceExists: surfaceExists, applyTitle: applyTitle)
  }

  func cancel(surfaceIDs: Set<UUID>, applyTitle: (String?, UUID) -> Void) {
    for surfaceID in surfaceIDs {
      stop(surfaceID: surfaceID, clearingTitle: true, applyTitle: applyTitle)
    }
  }

  private func start(
    surfaceID: UUID,
    pid: pid_t,
    surfaceExists: (UUID) -> Bool,
    applyTitle: @escaping @MainActor (String?, UUID) -> Void
  ) {
    guard surfaceExists(surfaceID) else { return }
    if pids[surfaceID] == pid, tasks[surfaceID] != nil {
      return
    }

    stop(surfaceID: surfaceID, clearingTitle: false, applyTitle: applyTitle)
    pids[surfaceID] = pid
    let sessionURL = Self.sessionURL(pid: pid)
    let sleep = sleep
    tasks[surfaceID] = Task { [weak self] in
      var lastTitle: String?
      while !Task.isCancelled {
        guard Self.isProcessAlive(pid) else { break }
        let title = Self.readTitle(at: sessionURL)
        if title != lastTitle {
          lastTitle = title
          applyTitle(title, surfaceID)
        }
        try? await sleep(Self.pollInterval)
      }

      guard !Task.isCancelled else { return }
      self?.finish(surfaceID: surfaceID, pid: pid, applyTitle: applyTitle)
    }
  }

  private func stop(surfaceID: UUID, clearingTitle: Bool, applyTitle: (String?, UUID) -> Void) {
    tasks.removeValue(forKey: surfaceID)?.cancel()
    pids.removeValue(forKey: surfaceID)
    if clearingTitle {
      applyTitle(nil, surfaceID)
    }
  }

  private func finish(surfaceID: UUID, pid: pid_t, applyTitle: (String?, UUID) -> Void) {
    guard pids[surfaceID] == pid else { return }
    tasks.removeValue(forKey: surfaceID)
    pids.removeValue(forKey: surfaceID)
    applyTitle(nil, surfaceID)
  }

  private static func sessionURL(pid: pid_t) -> URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appending(path: ".claude/sessions", directoryHint: .isDirectory)
      .appending(path: "\(pid).json", directoryHint: .notDirectory)
  }

  private static func readTitle(at url: URL) -> String? {
    guard let data = try? Data(contentsOf: url),
      let session = try? JSONDecoder().decode(SessionFile.self, from: data)
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
