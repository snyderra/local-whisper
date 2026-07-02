import AppKit
import Foundation

/// Supervises the bundled Python service when the app is the top-level
/// bundle (`LWBundledRuntime` in Info.plist). Mirrors launchd's
/// `KeepAlive={SuccessfulExit=false}` contract: restart on crash with a
/// throttle, never restart on exit 0 — the service deliberately exits 0
/// (e.g. when the mic permission is missing, or another instance holds the
/// single-instance lock) precisely so supervisors do not hot-loop.
@MainActor
final class ServiceManager {
    static let shared = ServiceManager()

    private var process: Process?
    private var logHandle: FileHandle?
    private var stopRequested = false
    private var restartDelay: TimeInterval = 10

    /// True when this app embeds the Python runtime (dmg build). The dev
    /// bundle built by setup.sh has no LWBundledRuntime key, so the legacy
    /// python-as-parent topology stays untouched there.
    static var isBundledRuntime: Bool {
        guard Bundle.main.object(forInfoDictionaryKey: "LWBundledRuntime") as? Bool == true else {
            return false
        }
        return FileManager.default.fileExists(atPath: whScriptPath)
    }

    private static var resourcesPath: String {
        Bundle.main.resourcePath ?? (Bundle.main.bundlePath + "/Contents/Resources")
    }
    private static var pythonPath: String { resourcesPath + "/python/bin/python3.12" }
    private static var whScriptPath: String { resourcesPath + "/bin/wh.py" }

    func start() {
        guard Self.isBundledRuntime, process == nil, !stopRequested else { return }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let whisperDir = home + "/.whisper"
        try? FileManager.default.createDirectory(
            atPath: whisperDir, withIntermediateDirectories: true)

        let service = Process()
        service.executableURL = URL(fileURLWithPath: Self.pythonPath)
        // -B: never write .pyc — writes inside Resources would invalidate
        // the bundle's code signature.
        service.arguments = ["-s", "-E", "-B", Self.whScriptPath, "_run"]

        var env = ProcessInfo.processInfo.environment
        // Bundle bin first so parakeet-mlx's bare `ffmpeg` lookup hits the
        // bundled binary; ~/.whisper/bin kept for the tier-1 vendored link.
        env["PATH"] = "\(Self.resourcesPath)/bin:\(home)/.whisper/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["HF_HUB_CACHE"] = whisperDir + "/models"
        env["HF_HUB_DISABLE_TELEMETRY"] = "1"
        env["LOCAL_WHISPER_UI_PARENT"] = "1"
        service.environment = env

        // Same log target the LaunchAgent plist used, so `wh log` keeps working.
        let logPath = whisperDir + "/service.log"
        if !FileManager.default.fileExists(atPath: logPath) {
            FileManager.default.createFile(atPath: logPath, contents: nil)
        }
        if let handle = FileHandle(forWritingAtPath: logPath) {
            handle.seekToEndOfFile()
            service.standardOutput = handle
            service.standardError = handle
            logHandle = handle
        }

        service.terminationHandler = { proc in
            Task { @MainActor in
                ServiceManager.shared.handleTermination(of: proc)
            }
        }

        do {
            try service.run()
            process = service
            NSLog("Local Whisper service started (pid %d)", service.processIdentifier)
        } catch {
            NSLog("Local Whisper service failed to launch: %@", error.localizedDescription)
            scheduleRestart()
        }
    }

    func stop() {
        stopRequested = true
        guard let service = process, service.isRunning else { return }
        let pid = service.processIdentifier
        service.terminate() // SIGTERM; the service shuts down gracefully
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
            if service.isRunning {
                kill(pid, SIGKILL)
            }
        }
    }

    private func handleTermination(of proc: Process) {
        try? logHandle?.close()
        logHandle = nil
        process = nil
        if stopRequested { return }
        if proc.terminationReason == .exit && proc.terminationStatus == 0 {
            NSLog("Local Whisper service exited cleanly; not restarting")
            return
        }
        NSLog(
            "Local Whisper service died (status %d); restarting in %.0fs",
            proc.terminationStatus, restartDelay)
        scheduleRestart()
    }

    private func scheduleRestart() {
        let delay = restartDelay
        restartDelay = min(restartDelay * 2, 120)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !stopRequested else { return }
            start()
        }
    }
}
