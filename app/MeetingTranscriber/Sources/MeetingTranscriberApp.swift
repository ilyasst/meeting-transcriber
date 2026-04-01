import Combine
import SwiftUI
import UniformTypeIdentifiers

extension Notification.Name {
    static let autoWatchStart = Notification.Name("autoWatchStart")
    static let showSpeakerNaming = Notification.Name("showSpeakerNaming")
}

@main
struct MeetingTranscriberApp: App {
    @State private var appState = AppState(notifier: NotificationManager.shared)
    @State private var iconAnimationFrame = 0
    @Environment(\.openWindow)
    private var openWindow
    private let iconTimer = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()

    init() {
        AppPaths.migrateIfNeeded()
        NotificationManager.shared.setUp()
        DualSourceRecorder.cleanupTempFiles()
        // Auto-watch: schedule on main run loop after app finishes launching
        if CommandLine.arguments.contains("--auto-watch")
            || UserDefaults.standard.bool(forKey: "autoWatch") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                NotificationCenter.default.post(name: .autoWatchStart, object: nil)
            }
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(
                status: appState.currentStatus,
                isWatching: appState.isWatching,
                pipelineQueue: appState.pipelineQueue,
                updateChecker: appState.updateChecker,
                onStartStop: appState.toggleWatching,
                onRecordApp: { bringWindowToFront(id: "record-app") },
                onStopManualRecording: appState.watchLoop?.isManualRecording == true ? {
                    appState.stopManualRecording()
                } : nil,
                onOpenLastProtocol: openLastProtocol,
                onOpenProtocol: { url in NSWorkspace.shared.open(url) },
                onOpenProtocolsFolder: openProtocolsFolder,
                onOpenSettings: {
                    bringWindowToFront(id: "settings")
                },
                onNameSpeakers: {
                    bringWindowToFront(id: "speaker-naming")
                },
                onProcessFiles: processAudioFiles,
                onDismissJob: { id in appState.pipelineQueue.removeJob(id: id) },
                onQuit: quit,
            )
        } label: { // swiftlint:disable:this closure_body_length
            Label {
                Text(appState.currentStateLabel)
            } icon: {
                Image(nsImage: MenuBarIcon.image(
                    badge: appState.currentBadge,
                    animationFrame: iconAnimationFrame,
                ))
            }
            .onReceive(iconTimer) { _ in
                // Always tick so currentBadge is re-read every 0.4s.
                // Non-animated badges ignore animationFrame (cached frame 0).
                iconAnimationFrame = (iconAnimationFrame + 1) % MenuBarIcon.frameCount
            }
            .onReceive(NotificationCenter.default.publisher(for: .autoWatchStart)) { _ in
                if !appState.isWatching {
                    appState.toggleWatching()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .showSpeakerNaming)) { _ in
                bringWindowToFront(id: "speaker-naming")
            }
            .onOpenURL { url in
                handleURL(url)
            }
            .task {
                switch appState.settings.transcriptionEngine {
                case .whisperKit:
                    appState.whisperKit.modelVariant = appState.settings.whisperKitModel
                    appState.whisperKit.language = appState.settings.whisperLanguageOrNil
                    await appState.whisperKit.loadModel()

                case .parakeet:
                    await appState.parakeetEngine.loadModel()

                case .qwen3:
                    if #available(macOS 15, *) {
                        appState.qwen3Engine.language = appState.settings.qwen3LanguageOrNil
                        await appState.qwen3Engine.loadModel()
                    }
                }
            }
            .task {
                appState.updateChecker.startPeriodicChecks(settings: appState.settings)
            }
        }

        Window("Name Speakers", id: "speaker-naming") {
            if let data = appState.pipelineQueue.pendingSpeakerNaming {
                SpeakerNamingView(data: data) { result in
                    appState.pipelineQueue.completeSpeakerNaming(result: result)
                    closeWindow(id: "speaker-naming")
                }
            } else {
                Text("No speaker data available.")
                    .padding()
            }
        }
        .windowResizability(.contentSize)

        Window("Settings", id: "settings") {
            SettingsView(
                settings: appState.settings,
                whisperKitEngine: appState.whisperKit,
                parakeetEngine: appState.parakeetEngine,
                qwen3Engine: {
                    if #available(macOS 15, *) {
                        return appState.qwen3Engine
                    }
                    return nil
                }(),
                updateChecker: appState.updateChecker,
            )
        }
        .windowResizability(.contentSize)

        Window("Record App", id: "record-app") {
            AppPickerView(
                onStartRecording: { pid, appName, title in
                    appState.startManualRecording(pid: pid, appName: appName, title: title)
                    closeWindow(id: "record-app")
                },
                onCancel: { closeWindow(id: "record-app") },
            )
        }
        .windowResizability(.contentSize)
    }

    // MARK: - UI Actions

    private func processAudioFiles() {
        let panel = NSOpenPanel()
        panel.title = "Select Audio or Video Files"
        var types: [UTType] = [
            .wav, .mp3, .aiff, .mpeg4Audio,
            .mpeg4Movie, .quickTimeMovie,
        ] + [UTType("public.flac")].compactMap(\.self)
        if FFmpegHelper.isAvailable {
            types += FFmpegHelper.ffmpegOnlyTypes
        }
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        appState.enqueueFiles(panel.urls)
    }

    private func openLastProtocol() {
        if let job = appState.pipelineQueue.completedJobs.last,
           let path = job.protocolPath ?? job.transcriptPath {
            NSWorkspace.shared.open(path)
        }
    }

    private func bringWindowToFront(id: String) {
        openWindow(id: id)
        NSApp.activate(ignoringOtherApps: true)
        // Ensure the window is brought to front even if already open
        DispatchQueue.main.async {
            for window in NSApp.windows where window.identifier?.rawValue == id {
                window.makeKeyAndOrderFront(nil)
            }
        }
    }

    private func closeWindow(id: String) {
        for window in NSApp.windows where window.identifier?.rawValue == id {
            window.close()
        }
    }

    private func openProtocolsFolder() {
        let protocols = appState.settings.effectiveOutputDir
        let accessing = protocols.startAccessingSecurityScopedResource()
        defer { if accessing { protocols.stopAccessingSecurityScopedResource() } }
        try? FileManager.default.createDirectory(at: protocols, withIntermediateDirectories: true)
        NSWorkspace.shared.open(protocols)
    }

    private func quit() {
        appState.watchLoop?.stop()
        NSApplication.shared.terminate(nil)
    }

    // MARK: - URL Scheme Handler (meeting-transcriber://)

    /// Handles URLs opened via the `meeting-transcriber://` scheme.
    ///
    /// Supported URLs:
    ///   meeting-transcriber://watch/start                        — enable auto-watch
    ///   meeting-transcriber://watch/stop                         — disable auto-watch
    ///   meeting-transcriber://record?app=Zoom                    — start manual recording of a named app
    ///   meeting-transcriber://process?file=<path>                — enqueue an audio/video file
    ///   meeting-transcriber://process?file=<path>&output=<dir>   — enqueue file, save results to custom dir
    ///   meeting-transcriber://process?folder=<path>              — enqueue all audio/video files in a folder
    ///   meeting-transcriber://process?folder=<path>&output=<dir> — enqueue folder, save results to custom dir
    private func handleURL(_ url: URL) {
        guard url.scheme == "meeting-transcriber" else { return }
        let host = url.host ?? ""
        let path = url.path
        let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []

        switch host {
        case "watch":
            switch path {
            case "/start":
                if !appState.isWatching { appState.toggleWatching() }
            case "/stop":
                if appState.isWatching { appState.toggleWatching() }
            default:
                break
            }

        case "record":
            if let appName = queryItems.first(where: { $0.name == "app" })?.value {
                let running = NSWorkspace.shared.runningApplications
                if let match = running.first(where: {
                    $0.localizedName?.localizedCaseInsensitiveContains(appName) == true
                }) {
                    let pid = match.processIdentifier
                    let name = match.localizedName ?? appName
                    let title = queryItems.first(where: { $0.name == "title" })?.value ?? name
                    appState.startManualRecording(pid: pid, appName: name, title: title)
                }
            }

        case "process":
            let outputDir = queryItems.first(where: { $0.name == "output" })
                .flatMap { $0.value }
                .map { URL(fileURLWithPath: $0, isDirectory: true) }

            if let filePath = queryItems.first(where: { $0.name == "file" })?.value {
                let fileURL = URL(fileURLWithPath: filePath)
                appState.enqueueFiles([fileURL], outputDir: outputDir)
            } else if let folderPath = queryItems.first(where: { $0.name == "folder" })?.value {
                let folderURL = URL(fileURLWithPath: folderPath, isDirectory: true)
                let files = audioVideoFiles(in: folderURL)
                if !files.isEmpty {
                    appState.enqueueFiles(files, outputDir: outputDir)
                }
            }

        default:
            break
        }
    }

    /// Returns all audio/video files directly inside `folder` (non-recursive).
    private func audioVideoFiles(in folder: URL) -> [URL] {
        let supported: Set<String> = ["wav", "mp3", "m4a", "aiff", "aif", "mp4", "mov", "flac",
                                      "mkv", "webm", "ogg"]
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: .skipsHiddenFiles
        ) else { return [] }
        return contents
            .filter { supported.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    // MARK: - Pure Helpers (testable without @main)

    /// Whether auto-watch should be enabled based on CLI flags or user settings.
    static func shouldAutoWatch(
        commandLineArgs: [String] = CommandLine.arguments,
        autoWatchSetting: Bool = UserDefaults.standard.bool(forKey: "autoWatch"),
    ) -> Bool {
        commandLineArgs.contains("--auto-watch") || autoWatchSetting
    }

    /// Returns the protocol path from the last completed job, if any.
    static func lastCompletedProtocolPath(completedJobs: [PipelineJob]) -> URL? {
        completedJobs.last?.protocolPath
    }
}
