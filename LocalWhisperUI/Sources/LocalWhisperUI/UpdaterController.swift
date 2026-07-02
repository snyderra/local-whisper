import Foundation
import Sparkle

/// Sparkle wrapper, active only in distributable dmg builds: both
/// `SUFeedURL` and `SUPublicEDKey` must be present in Info.plist, which the
/// bundle build injects only when the appcast keys are configured. Dev
/// builds (setup.sh) and adhoc test dmgs keep the legacy IPC "update" path.
@MainActor
final class UpdaterController {
    static let shared = UpdaterController()

    private var controller: SPUStandardUpdaterController?

    var isAvailable: Bool { controller != nil }

    func activateIfConfigured() {
        guard controller == nil,
            Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil,
            Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") != nil
        else { return }
        controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}
