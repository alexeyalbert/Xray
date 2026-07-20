import SwiftUI

struct XrayCommands: Commands {
    let model: AppModel
    @Binding var isShowingSettings: Bool
    @Binding var isShowingOnboarding: Bool

    private var importState: ImportState {
        model.importState
    }

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Replay Onboarding…") {
                isShowingSettings = false
                isShowingOnboarding = true
            }
        }

        CommandGroup(replacing: .appSettings) {
            Button("Settings…") {
                isShowingSettings = true
            }
            .keyboardShortcut(",", modifiers: .command)
            .disabled(isShowingOnboarding)
        }

        CommandMenu("Bookmarks") {
            Button("Import from file", systemImage: "square.stack.3d.up.badge.a") {
                model.openJSONFilePicker()
            }
            .keyboardShortcut("I", modifiers: [.command, .shift])

            Button(
                importState.isBrowserImportReceiverRunning
                    ? "Browser Import Receiver Running"
                    : "Start Browser Import Receiver",
                systemImage: "dot.radiowaves.left.and.right"
            ) {
                model.beginBrowserImportReceiver()
            }
            .disabled(importState.isBrowserImportReceiverRunning)

            Button("Stop Browser Import Receiver", systemImage: "stop.circle") {
                model.endBrowserImportReceiver()
            }
            .disabled(!importState.isBrowserImportReceiverRunning)

            Divider()

            Button("Generate Topics", systemImage: "wand.and.stars") {
                Task { await model.processMissingTopics() }
            }
            .keyboardShortcut("P")
            .disabled(importState.isDatabaseImporting)

            if importState.isTextEmbeddingGenerating || importState.isImageEmbeddingGenerating {
                if importState.isEmbeddingStopRequested {
                    Button("Stopping Embedding Model...", systemImage: "stop.circle") {}
                        .disabled(true)
                } else {
                    Button("Stop Embedding Model", systemImage: "stop.circle") {
                        model.requestEmbeddingStop()
                    }
                }
            } else {
                Button("Generate Text Embeddings", systemImage: "square.grid.3x3.square") {
                    Task.detached(priority: .userInitiated) {
                        await model.processAllPostsEmbeddings()
                    }
                }
                .keyboardShortcut("E")
                .disabled(importState.isDatabaseImporting)

                Button("Generate Image Embeddings", systemImage: "photo") {
                    Task.detached(priority: .userInitiated) {
                        await model.processAllPostsImageEmbeddings()
                    }
                }
                .disabled(importState.isDatabaseImporting)
            }
        }
    }
}
