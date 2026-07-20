//
//  ContentViewPreviews.swift
//  Xray
//

import Foundation
import SwiftUI

private extension ImportState {
    static var preview: ImportState {
        let state = ImportState()
        //old preview file was named twitter-Bookmarks-1754319119715.json
        let fileURL = URL(fileURLWithPath: "/Users/alexeyalbert/Downloads/twitter-Bookmarks-latest-demo.json")
        state.importURL = fileURL
        
        // Load actual data for preview
        if let data = try? Data(contentsOf: fileURL) {
            let decoder = JSONDecoder()
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
            decoder.dateDecodingStrategy = .formatted(formatter)
            if let posts = try? decoder.decode([Post].self, from: data) {
                state.posts = posts
            } else {
                state.loadError = "Failed to decode JSON"
            }
        } else {
            state.loadError = "File not found"
        }
        
        return state
    }
}

private struct ContentViewSearchCapsulePreview: View {
    @State private var importState = ImportState.preview
    @State private var isShowingSearchCapsule = true
    @State private var dotCount = 1
    @State private var isShowingSettings = false
    
    var body: some View {
        ContentView(
            importState: importState,
            isShowingSettings: $isShowingSettings,
            onRebuildDatabaseSchema: {},
            onResetDatabase: {},
            onGenerateRemainingEnrichments: {},
            onRefreshEnrichmentAvailability: {}
        )
            .overlay(alignment: .bottom) {
                SearchStatusCapsule(isVisible: isShowingSearchCapsule, dotCount: dotCount)
                    .padding(.bottom, 18)
            }
            .task {
                while !Task.isCancelled {
                    isShowingSearchCapsule = true
                    try? await Task.sleep(nanoseconds: 10_000_000_000)
                    if Task.isCancelled { return }
                    isShowingSearchCapsule = false
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                }
            }
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 900_000_000)
                    if Task.isCancelled { return }
                    dotCount = (dotCount + 1) % 4
                }
            }
    }
}

#Preview {
    ContentViewSearchCapsulePreview()
        .frame(width: 800, height: 600)
}

