import AppKit
import SwiftUI

struct AppUpdateToolbarButton: View {
    let controller: AppUpdateController
    let isInstallationAllowed: Bool
    let onPrepareForInstallation: () async -> Void

    var body: some View {
        if let version = controller.availableVersion {
            Button("Update") {
                presentUpdateAlert(version: version)
            }
            .disabled(controller.installationPhase != .idle)
            .help("Update available")
        }
    }

    private func presentUpdateAlert(version: String) {
        switch AppUpdateAlertPresenter.present(
            version: version,
            phase: controller.installationPhase,
            errorMessage: controller.errorMessage,
            isInstallationAllowed: isInstallationAllowed
        ) {
        case .update:
            installUpdate(version: version)
        case .viewRelease:
            NSWorkspace.shared.open(AppUpdateController.releaseURL)
        case .notNow:
            break
        }
    }

    private func installUpdate(version: String) {
        Task {
            await controller.installAvailableUpdate {
                await onPrepareForInstallation()
            }

            if controller.errorMessage != nil {
                presentUpdateAlert(version: controller.availableVersion ?? version)
            }
        }
    }
}

@MainActor
private enum AppUpdateAlertPresenter {
    enum Response: Equatable {
        case update
        case notNow
        case viewRelease
    }

    static func present(
        version: String,
        phase: AppUpdateController.InstallationPhase,
        errorMessage: String?,
        isInstallationAllowed: Bool
    ) -> Response {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = String(localized: "A New Update Is Available")
        alert.informativeText = informativeText(
            version: version,
            phase: phase,
            errorMessage: errorMessage,
            isInstallationAllowed: isInstallationAllowed
        )
        alert.icon = NSApplication.shared.applicationIconImage

        let updateButton = alert.addButton(withTitle: String(localized: "Update"))
        updateButton.isEnabled = phase == .idle && isInstallationAllowed
        updateButton.keyEquivalent = "\r"

        let notNowButton = alert.addButton(withTitle: String(localized: "Not Now"))
        notNowButton.keyEquivalent = "\u{1b}"

        alert.addButton(withTitle: String(localized: "View Release on GitHub"))

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return .update
        case .alertThirdButtonReturn:
            return .viewRelease
        default:
            return .notNow
        }
    }

    private static func informativeText(
        version: String,
        phase: AppUpdateController.InstallationPhase,
        errorMessage: String?,
        isInstallationAllowed: Bool
    ) -> String {
        if let errorMessage {
            return String(
                localized: "Xray version \(version) is available.\n\nThe update could not be installed: \(errorMessage)"
            )
        }

        if !isInstallationAllowed {
            return String(
                localized: "Xray version \(version) is available. Finish the current import or post processing before updating."
            )
        }

        switch phase {
        case .idle:
            return String(localized: "Xray version \(version) is ready to install.")
        case .preparing:
            return String(localized: "Xray version \(version) is downloading and being verified.")
        case .installing:
            return String(localized: "Xray version \(version) is installing. Xray will relaunch shortly.")
        }
    }
}

#Preview("Update Alert") {
    AppUpdateAlertPreview()
}

private struct AppUpdateAlertPreview: View {
    @State private var hasPresentedAlert = false

    var body: some View {
        Button("Show Update Alert", action: presentAlert)
            .frame(width: 500, height: 260)
            .task {
                guard !hasPresentedAlert else { return }
                hasPresentedAlert = true
                try? await Task.sleep(for: .milliseconds(250))
                presentAlert()
            }
    }

    private func presentAlert() {
        let response = AppUpdateAlertPresenter.present(
            version: "1.1.0",
            phase: .idle,
            errorMessage: nil,
            isInstallationAllowed: true
        )

        if response == .viewRelease {
            NSWorkspace.shared.open(AppUpdateController.releaseURL)
        }
    }
}
