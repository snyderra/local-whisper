import AppKit
import Foundation

/// First-run and self-heal for bundled installs: keep exactly one UI
/// instance alive and keep the LaunchAgent pointing at this bundle.
@MainActor
enum FirstRunManager {
    /// True when no other instance of this app is running. When another
    /// instance exists (e.g. launchd kickstarted a second copy right after
    /// the agent install below, or the user double-clicked while the agent
    /// copy runs), activate it and let the caller exit 0 — launchd's
    /// SuccessfulExit=false keepalive treats that as "do not restart".
    static func ensurePrimaryInstance() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return true }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        guard let other = others.first else { return true }
        other.activate()
        return false
    }

    /// Install or heal the LaunchAgent so login autostart points at this
    /// bundle. Never captures a Gatekeeper-translocated path — the plist
    /// would be worthless after the randomized mount disappears.
    static func ensureLaunchAgent() {
        guard ServiceManager.isBundledRuntime else { return }
        let bundlePath = Bundle.main.bundlePath
        if bundlePath.contains("/AppTranslocation/") {
            presentTranslocationAlert()
            return
        }
        let expectedProgram = bundlePath + "/Contents/MacOS/LocalWhisperUI"
        if currentAgentProgram() == expectedProgram { return }
        installAgent()
    }

    /// Called by a deferring duplicate instance (drag-upgrade, login race):
    /// when the running service's version differs from this bundle on disk,
    /// restart the whole launchd job from disk so both UI and service come
    /// back on the new version. Heals manual Finder upgrades, not just
    /// Sparkle ones. Returns true when a kickstart was triggered.
    static func reconcileStaleService() -> Bool {
        guard
            let myVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
            !myVersion.isEmpty
        else { return false }
        let running = runningServiceVersion()
        guard !running.isEmpty, running != myVersion else { return false }
        NSLog("Stale service %@ (bundle is %@); kickstarting the job", running, myVersion)
        let kick = Process()
        kick.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        kick.arguments = ["kickstart", "-k", "gui/\(getuid())/com.local-whisper"]
        do {
            try kick.run()
            kick.waitUntilExit()
            return kick.terminationStatus == 0
        } catch {
            return false
        }
    }

    private static func runningServiceVersion() -> String {
        let wh = (Bundle.main.resourcePath ?? "") + "/bin/wh"
        guard FileManager.default.isExecutableFile(atPath: wh) else { return "" }
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: wh)
        probe.arguments = ["_service_version"]
        let pipe = Pipe()
        probe.standardOutput = pipe
        probe.standardError = FileHandle.nullDevice
        do {
            try probe.run()
        } catch {
            return ""
        }
        probe.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static var agentPlistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.local-whisper.plist")
    }

    private static func currentAgentProgram() -> String? {
        guard let data = try? Data(contentsOf: agentPlistURL),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
            let dict = plist as? [String: Any],
            let args = dict["ProgramArguments"] as? [String]
        else { return nil }
        return args.first
    }

    private static func installAgent() {
        // Delegate to the Python implementation — single source of truth
        // for plist content, shared with `wh setup` and `wh doctor --fix`.
        let wh = (Bundle.main.resourcePath ?? "") + "/bin/wh"
        guard FileManager.default.isExecutableFile(atPath: wh) else { return }
        let install = Process()
        install.executableURL = URL(fileURLWithPath: wh)
        install.arguments = ["_agent", "install"]
        install.standardOutput = FileHandle.nullDevice
        install.standardError = FileHandle.nullDevice
        do {
            try install.run()
            install.waitUntilExit()
            NSLog("LaunchAgent install finished (status %d)", install.terminationStatus)
        } catch {
            NSLog("LaunchAgent install failed: %@", error.localizedDescription)
        }
    }

    private static func presentTranslocationAlert() {
        let alert = NSAlert()
        alert.messageText = "Move Local Whisper to Applications"
        alert.informativeText =
            "Local Whisper is running from a temporary location, so it cannot "
            + "start automatically at login yet. Move it to the Applications "
            + "folder and open it again."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
