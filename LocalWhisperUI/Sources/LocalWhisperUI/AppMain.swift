import SwiftUI
import AppKit
import UserNotifications

// MARK: - Shared app state (singleton for delegate bridge)

@MainActor
let sharedAppState = AppState()

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate, @unchecked Sendable {
    private var overlayController: OverlayWindowController?
    private var wakeObserver: NSObjectProtocol?
    private var sigtermSource: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let state = sharedAppState
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        Task { @MainActor in
            if ServiceManager.isBundledRuntime {
                // App-bundle topology: this app is the launchd job and the
                // parent of the bundled Python service.
                guard FirstRunManager.ensurePrimaryInstance() else {
                    // Another instance runs; if it serves an older version
                    // (drag-upgrade), restart the job from disk before we go.
                    _ = FirstRunManager.reconcileStaleService()
                    exit(0)
                }
                FirstRunManager.ensureLaunchAgent()
                ServiceManager.shared.start()
                UpdaterController.shared.activateIfConfigured()
                self.installSigtermHandler()
            }

            state.setupIPC()
            state.ipcClient?.start()

            self.overlayController = OverlayWindowController(appState: state)

            self.installSleepWakeObservers(for: state)

            if !OnboardingFlag.hasCompleted {
                OnboardingPresenter.shared.present(with: state)
            }
        }
    }

    @MainActor
    private func installSigtermHandler() {
        // launchctl bootout / wh stop deliver SIGTERM; dying by signal would
        // count as unsuccessful exit and make launchd restart us. Convert it
        // into a clean terminate (which also stops the service child).
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler {
            NSApp.terminate(nil)
        }
        source.resume()
        sigtermSource = source
    }

    @MainActor
    private func installSleepWakeObservers(for state: AppState) {
        let center = NSWorkspace.shared.notificationCenter
        wakeObserver = center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                state.ipcClient?.sendAction("resync_audio")
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let observer = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            wakeObserver = nil
        }
        sharedAppState.ipcClient?.stopSync()
        MainActor.assumeIsolated {
            ServiceManager.shared.stop()
        }
    }
}

// MARK: - App entry point

@main
struct LocalWhisperUIApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    private var appState: AppState { sharedAppState }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(appState)
                .tint(Theme.Brand.accent(for: colorScheme))
        } label: {
            Image(systemName: appState.menuBarIconName)
                .modifier(MenuBarBounce(value: appState.phase, reduceMotion: reduceMotion))
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView()
                .environment(appState)
                .tint(Theme.Brand.accent(for: colorScheme))
        }
        .defaultSize(width: 880, height: 640)
        .windowResizability(.contentMinSize)
    }
}

private struct MenuBarBounce<V: Equatable>: ViewModifier {
    let value: V
    let reduceMotion: Bool
    func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else {
            content.symbolEffect(.bounce, value: value)
        }
    }
}
