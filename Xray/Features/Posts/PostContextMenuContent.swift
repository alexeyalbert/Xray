//
//  PostContextMenuContent.swift
//  Xray
//

import SwiftUI

struct PostContextMenuContent: View {
    let saveImageAction: (() -> Void)?
    let findSimilarImagesAction: (() -> Void)?
    let viewInBrowserAction: () -> Void
    let temporarilyHidePostAction: (() -> Void)?
    let showRawSQLiteRowAction: (() -> Void)?
    let showSearchExplanationAction: (() -> Void)?
    let compareEmbeddingAction: (() -> Void)?
    let showPostDebugAction: (() -> Void)?
    let editTopicsAction: () -> Void
    let deletePostAction: () -> Void
    let resetTopicsAction: () -> Void
    let isResetTopicsDisabled: Bool
    
    var body: some View {
        Group {
            if let saveImageAction {
                Button(action: saveImageAction) {
                    Label("Save Original Image...", systemImage: "square.and.arrow.down")
                }
            }

            if let findSimilarImagesAction {
                Button(action: findSimilarImagesAction) {
                    Label("Search Similar Images", systemImage: "photo.stack")
                }
            }

            if saveImageAction != nil || findSimilarImagesAction != nil {
                Divider()
            }
            
            Button(action: viewInBrowserAction) {
                Label("View in Browser", systemImage: "arrow.up.right.square")
            }

            if let temporarilyHidePostAction {
                Button(action: temporarilyHidePostAction) {
                    Label("Hide Post Temporarily", systemImage: "eye.slash")
                }
            }
            
            if let showRawSQLiteRowAction {
                Button(action: showRawSQLiteRowAction) {
                    Label("Show SQLite Row", systemImage: "server.rack")
                }
            }
            
            if let showSearchExplanationAction {
                Button(action: showSearchExplanationAction) {
                    Label("Debug Search Ranking", systemImage: "questionmark.bubble")
                }
            }
            
            if let compareEmbeddingAction {
                Button(action: compareEmbeddingAction) {
                    Label("Compare with Search Embedding", systemImage: "waveform")
                }
            }
            
            if let showPostDebugAction {
                Button(action: showPostDebugAction) {
                    Label("Show Post Debug Info", systemImage: "ladybug")
                }
            }
            
            if DebugSettings.showPostContextDebugOptions {
                Button(action: editTopicsAction) {
                    Label("Edit Stored Topics", systemImage: "slider.horizontal.3")
                }
            }
            
            Divider()
            
            Button(role: .destructive, action: deletePostAction) {
                Label("Delete Post From Database", systemImage: "trash.slash")
            }
            
            if DebugSettings.showPostContextDebugOptions {
                Button(role: .destructive, action: resetTopicsAction) {
                    Label("Reset Stored Topics", systemImage: "trash")
                }
                .disabled(isResetTopicsDisabled)
            }
        }
    }
}

