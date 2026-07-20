import SwiftUI

@main
struct XrayApp: App {
    @State private var model = AppModel()
    @State private var isShowingSettings = false
    @State private var isShowingOnboarding = !OnboardingSettings.hasCompleted

    var body: some Scene {
        WindowGroup {
            if isShowingOnboarding {
                OnboardingView(
                    onStartBrowserImport: model.beginBrowserImportReceiver,
                    onComplete: {
                        isShowingOnboarding = false
                    }
                )
                .containerBackground(.regularMaterial, for: .window)
            } else {
                ContentView(
                    importState: model.importState,
                    isShowingSettings: $isShowingSettings,
                    onRebuildDatabaseSchema: {
                        Task { await model.rebuildDatabaseSchemaPreservingData() }
                    },
                    onResetDatabase: {
                        Task { await model.resetDatabaseAndUI() }
                    },
                    onGenerateRemainingEnrichments: {
                        Task.detached(priority: .userInitiated) {
                            await model.processRemainingEnrichments()
                        }
                    },
                    onRefreshEnrichmentAvailability: {
                        Task { await model.refreshPendingEnrichmentWork() }
                    }
                )
                .frame(minWidth: 1050, minHeight: 600)
                .onAppear { model.loadInitialPostsFromDatabase() }
                .containerBackground(.regularMaterial, for: .window)
            }
        }
        .windowResizability(isShowingOnboarding ? .contentSize : .automatic)
        .commands {
            XrayCommands(
                model: model,
                isShowingSettings: $isShowingSettings,
                isShowingOnboarding: $isShowingOnboarding
            )
        }
#if os(macOS)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified)
#endif
    }
}
