//
//  SearchToolbarField.swift
//  Xray
//

import Kingfisher
import SwiftUI
#if os(macOS)
import AppKit
#endif

#if os(macOS)
struct SearchToolbarField: View {
    static let controlWidth: CGFloat = 460

    @Binding var searchText: String
    @Binding var selection: TextSelection?
    var focused: FocusState<Bool>.Binding
    let imageSearchMedia: Media?
    var isPanelActive: Bool
    var onClearImageSearch: () -> Void
    var onEscape: () -> Void
    var onSubmit: () -> Void

    var body: some View {
        HStack(spacing: 7) {
            if let imageSearchMedia {
                SearchToolbarImageAttachment(media: imageSearchMedia)
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
            } else {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
            }

            TextField(
                imageSearchMedia == nil ? "Search" : "Similar images",
                text: $searchText,
                selection: $selection
            )
                .textFieldStyle(.plain)
                .focused(focused)
                .onSubmit {
                    if isPanelActive {
                        onSubmit()
                    }
                }
                .onKeyPress(.escape) {
                    if isPanelActive {
                        onEscape()
                        return .handled
                    }
                    return .ignored
                }

            if imageSearchMedia != nil {
                Button(action: onClearImageSearch) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear Image Search")
                .pointingHandOnHover()
            } else if !searchText.isEmpty {
                Button {
                    searchText = ""
                    focused.wrappedValue = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear Search")
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, searchText.isEmpty && imageSearchMedia == nil ? 10 : 8)
        .frame(width: Self.controlWidth)
        .animation(.spring(response: 0.24, dampingFraction: 0.86), value: imageSearchMedia?.id)
    }
}

private struct SearchToolbarImageAttachment: View {
    let media: Media

    var body: some View {
        KFImage(media.thumbnail)
            .setProcessor(SharedImagePipeline.thumbnailProcessor)
            .targetCache(SharedImagePipeline.thumbnailCache)
            .serialize(by: SharedImagePipeline.thumbnailCacheSerializer)
            .requestModifier(SharedImagePipeline.sharedRequestModifier)
            .backgroundDecode()
            .resizable()
            .placeholder {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(NSColor.tertiarySystemFill))
                    .overlay {
                        Image(systemName: "photo")
                            .foregroundStyle(.tertiary)
                    }
            }
            .scaledToFill()
            .frame(width: 28, height: 28)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color(NSColor.separatorColor), lineWidth: 1)
            }
            .accessibilityLabel("Image search reference")
    }
}
#endif
