//
//  ExpandedMediaOverlay.swift
//  Xray
//

import SwiftUI

struct ExpandedMediaOverlay: View {
    let media: Media
    let saveContext: MediaSaveContext?
    let backdropOpacity: Double
    let onClose: () -> Void

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.black.opacity(backdropOpacity))
                .ignoresSafeArea()
                .onTapGesture(perform: onClose)

            MediaView(
                media: media,
                saveContext: saveContext,
                onClose: onClose
            )
        }
    }
}

