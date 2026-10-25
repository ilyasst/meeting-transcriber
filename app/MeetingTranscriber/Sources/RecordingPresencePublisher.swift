import Foundation
import os.log

private let presenceLogger = Logger(subsystem: AppPaths.logSubsystem, category: "RecordingPresence")

/// A small, atomic state document for a single capture. It never contains audio or names.
@MainActor
final class RecordingPresencePublisher {
    private struct Document: Encodable {
        let schema: String
        let schema_version: Int // swiftlint:disable:this identifier_name
        let filename: String
        let status: String
        let started_at: String // swiftlint:disable:this identifier_name
        let updated_at: String // swiftlint:disable:this identifier_name
    }

    private let scope: URL
    private let file: URL
    private let filename: String
    private let startedAt: Date
    private let clock: () -> Date
    private var lastUpdate: Date
    private var ended = false
    private var heartbeatTask: Task<Void, Never>?
    private let accessing: Bool
    private let formatter = ISO8601DateFormatter()

    init(
        scope: URL,
        directory: URL,
        filename: String,
        clock: @escaping () -> Date = Date.init,
        sessionID: String = UUID().uuidString,
        automaticHeartbeat: Bool = true,
    ) {
        precondition(!filename.isEmpty && !filename.contains("/") && !filename.contains("\\") && filename.count <= 255)
        precondition(!sessionID.isEmpty && sessionID.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") })
        self.scope = scope
        self.file = directory.appendingPathComponent("\(sessionID).json")
        self.filename = filename
        self.clock = clock
        self.startedAt = clock()
        self.lastUpdate = startedAt
        self.accessing = scope.startAccessingSecurityScopedResource()
        heartbeat()
        if automaticHeartbeat {
            heartbeatTask = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(30)) } catch { return }
                    guard !Task.isCancelled else { return }
                    self?.heartbeat()
                }
            }
        }
    }

    deinit {
        heartbeatTask?.cancel()
        if accessing { scope.stopAccessingSecurityScopedResource() }
    }

    func heartbeat() {
        guard !ended else { return }
        publish(status: "recording", filename: filename)
    }

    func stopped(filename finalFilename: String) {
        guard !ended else { return }
        ended = true
        heartbeatTask?.cancel()
        publish(status: "stopped", filename: finalFilename)
    }

    func cancelled() {
        guard !ended else { return }
        ended = true
        heartbeatTask?.cancel()
        do {
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        } catch {
            presenceLogger.warning("Presence cleanup unavailable")
        }
    }

    private func publish(status: String, filename: String) {
        lastUpdate = max(lastUpdate, clock())
        let document = Document(
            schema: "shalashaska.recorder-presence", schema_version: 1,
            filename: filename, status: status,
            started_at: formatter.string(from: startedAt), updated_at: formatter.string(from: lastUpdate),
        )
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(document).write(to: file, options: .atomic)
        } catch {
            presenceLogger.warning("Presence publication unavailable")
        }
    }
}
