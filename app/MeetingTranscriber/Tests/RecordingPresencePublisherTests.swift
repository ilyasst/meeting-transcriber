@testable import MeetingTranscriber
import XCTest

@MainActor
final class RecordingPresencePublisherTests: XCTestCase {
    func testLifecycleKeepsIdentityAndTerminalState() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var now = Date(timeIntervalSince1970: 1_893_556_800)
        let publisher = RecordingPresencePublisher(
            scope: root, directory: root, filename: "fixture_mix.wav", clock: { now },
            sessionID: "synthetic-session", automaticHeartbeat: false,
        )
        let file = root.appendingPathComponent("synthetic-session.json")
        let first = try document(file)
        XCTAssertEqual(first["schema"] as? String, "shalashaska.recorder-presence")
        XCTAssertEqual(first["schema_version"] as? Int, 1)
        XCTAssertEqual(first["status"] as? String, "recording")
        now.addTimeInterval(30)
        publisher.heartbeat()
        publisher.stopped(filename: "fixture_mix.wav")
        publisher.heartbeat()
        publisher.cancelled()
        let final = try document(file)
        XCTAssertEqual(final["status"] as? String, "stopped")
        XCTAssertEqual(final["started_at"] as? String, first["started_at"] as? String)
        XCTAssertNotEqual(final["updated_at"] as? String, first["updated_at"] as? String)
        XCTAssertEqual(final["filename"] as? String, "fixture_mix.wav")
        XCTAssertEqual(Set(final.keys), ["schema", "schema_version", "filename", "status", "started_at", "updated_at"])
    }

    func testCancellationCannotBeOverwrittenByHeartbeat() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let publisher = RecordingPresencePublisher(
            scope: root, directory: root, filename: "fixture_mix.wav",
            sessionID: "synthetic-session", automaticHeartbeat: false,
        )
        publisher.cancelled()
        publisher.heartbeat()
        publisher.stopped(filename: "fixture_mix.wav")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("synthetic-session.json").path))
    }

    func testPublicationFailureDoesNotThrowOrPreventRetry() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root)
        let publisher = RecordingPresencePublisher(
            scope: root, directory: root, filename: "fixture_mix.wav",
            sessionID: "synthetic-session", automaticHeartbeat: false,
        )
        try FileManager.default.removeItem(at: root)
        publisher.heartbeat()
        XCTAssertEqual(try document(root.appendingPathComponent("synthetic-session.json"))["status"] as? String, "recording")
    }

    func testClockRollbackDoesNotCreateAnUpdateBeforeStart() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var now = Date(timeIntervalSince1970: 1_893_556_800)
        let publisher = RecordingPresencePublisher(
            scope: root, directory: root, filename: "fixture_mix.wav", clock: { now },
            sessionID: "synthetic-session", automaticHeartbeat: false,
        )
        now.addTimeInterval(-60)
        publisher.heartbeat()
        let data = try document(root.appendingPathComponent("synthetic-session.json"))
        XCTAssertEqual(data["started_at"] as? String, data["updated_at"] as? String)
    }

    func testManualCapturePublishesImmediatelyAndKeepsItsSelectedDestination() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let recorder = MockRecorder()
        recorder.presenceFilename = "fixture_mix.wav"
        recorder.mixPath = root.appendingPathComponent("fixture_mix.wav")
        try Data().write(to: XCTUnwrap(recorder.mixPath))
        var selected = root.appendingPathComponent("recordings")
        let loop = WatchLoop(
            detector: makeSilentDetector(), recorderFactory: { recorder },
            recordOnly: { true }, recordOnlyDestination: { .unscoped(selected) }, pidAliveCheck: { _ in true },
        )
        loop.permissionChecker = { HealthCheckResult(screenRecording: .healthy, microphone: .healthy) }
        try await loop.startManualRecording(pid: 9999, appName: "Fixture", title: "Synthetic capture")
        let directory = root.appendingPathComponent("intake/recorder-presence")
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        XCTAssertEqual(try document(file)["status"] as? String, "recording")
        selected = root.appendingPathComponent("other/recordings")
        loop.stopManualRecording()
        XCTAssertEqual(try document(file)["status"] as? String, "stopped")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("recordings/fixture_mix.wav").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: selected.path))
    }

    func testAutomaticCapturePublishesStoppedForTheSameRecording() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let recorder = MockRecorder()
        recorder.presenceFilename = "fixture_mix.wav"
        recorder.mixPath = root.appendingPathComponent("fixture_mix.wav")
        try Data().write(to: XCTUnwrap(recorder.mixPath))
        let detector = PowerAssertionDetector()
        detector.assertionProvider = { [:] }
        let loop = WatchLoop(
            detector: detector, recorderFactory: { recorder }, pollInterval: 0.01, endGracePeriod: 0.01,
            recordOnly: { true }, recordOnlyDestination: { .unscoped(root.appendingPathComponent("recordings")) },
        )
        try await loop.handleMeeting(DetectedMeeting(pattern: .teams, windowTitle: "Synthetic capture", ownerName: "Fixture", windowPID: 9999))
        let directory = root.appendingPathComponent("intake/recorder-presence")
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        let result = try document(file)
        XCTAssertEqual(result["status"] as? String, "stopped")
        XCTAssertEqual(result["filename"] as? String, "fixture_mix.wav")
    }

    func testFailedFinalizationRemovesTheActiveSignal() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = MockRecorder()
        recorder.presenceFilename = "fixture_mix.wav"
        let loop = WatchLoop(
            detector: makeSilentDetector(), recorderFactory: { recorder },
            recordOnly: { true }, recordOnlyDestination: { .unscoped(root.appendingPathComponent("recordings")) },
            pidAliveCheck: { _ in true },
        )
        loop.permissionChecker = { HealthCheckResult(screenRecording: .healthy, microphone: .healthy) }
        try await loop.startManualRecording(pid: 9999, appName: "Fixture", title: "Synthetic capture")
        loop.stopManualRecording()
        let directory = root.appendingPathComponent("intake/recorder-presence")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).isEmpty)
    }

    private func document(_ url: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }
}
