import AppUpdater
import Foundation
import Observation
import os

@Observable
@MainActor
final class AppUpdateController {
    enum InstallationPhase: Equatable {
        case idle
        case preparing
        case installing
    }

    static let releaseURL = URL(string: "https://github.com/alexeyalbert/Xray/releases/latest")!

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Xray",
        category: "AppUpdater"
    )

    private(set) var availableVersion: String?
    private(set) var installationPhase: InstallationPhase = .idle
    private(set) var errorMessage: String?

    @ObservationIgnored private let updater: AppUpdater
    @ObservationIgnored private var availableUpdate: Update?
    @ObservationIgnored private var isChecking = false

    init() {
        updater = AppUpdater(
            owner: "alexeyalbert",
            repo: "Xray"
        )
    }

    init(updater: AppUpdater) {
        self.updater = updater
    }

    func checkForUpdates() async {
        guard !isChecking,
              installationPhase == .idle,
              availableUpdate == nil
        else { return }

        isChecking = true
        defer { isChecking = false }

        do {
            let update = try await updater.check()
            availableUpdate = update
            availableVersion = update?.version
        } catch is CancellationError {
            return
        } catch {
            Self.logger.error("Update check failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func installAvailableUpdate(
        beforeInstallation: @MainActor () async -> Void
    ) async {
        guard installationPhase == .idle else { return }

        errorMessage = nil
        if availableUpdate == nil {
            await checkForUpdates()
        }

        guard let update = availableUpdate else {
            errorMessage = String(localized: "The update is no longer available.")
            return
        }

        installationPhase = .preparing

        do {
            let preparedUpdate = try await update.prepareInstallation()
            availableUpdate = nil
            await beforeInstallation()
            installationPhase = .installing
            try await preparedUpdate.installAndRelaunch()
        } catch {
            installationPhase = .idle
            errorMessage = error.localizedDescription
            availableUpdate = nil
            await checkForUpdates()
        }
    }
}
