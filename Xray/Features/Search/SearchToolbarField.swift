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
    var onClearTextSearch: () -> Void
    var onClearImageSearch: () -> Void
    var onEscape: () -> Void
    var onSubmit: () -> Void
    var onAnchorMinXChange: (CGFloat) -> Void

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
                Button(action: onClearTextSearch) {
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
        .legacyToolbarSearchFieldChrome()
        .background {
            SearchToolbarAnchorReader(onMinXChange: onAnchorMinXChange)
        }
        .animation(.spring(response: 0.24, dampingFraction: 0.86), value: imageSearchMedia?.id)
    }
}

private extension View {
    @ViewBuilder
    func legacyToolbarSearchFieldChrome() -> some View {
        if #available(macOS 26.0, *) {
            self
        } else {
            self
                .padding(.vertical, 5)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.94), in: Capsule())
                .overlay {
                    Capsule()
                        .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
                }
        }
    }
}

private struct SearchToolbarAnchorReader: NSViewRepresentable {
    let onMinXChange: (CGFloat) -> Void

    func makeNSView(context: Context) -> SearchToolbarAnchorView {
        let view = SearchToolbarAnchorView()
        view.onMinXChange = onMinXChange
        return view
    }

    func updateNSView(_ nsView: SearchToolbarAnchorView, context: Context) {
        nsView.onMinXChange = onMinXChange
        nsView.scheduleFrameReport()
    }
}

private final class SearchToolbarAnchorView: NSView {
    var onMinXChange: ((CGFloat) -> Void)?

    private var lastReportedMinX: CGFloat?
    private var isFrameReportScheduled = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        scheduleFrameReport()
    }

    override func layout() {
        super.layout()
        scheduleFrameReport()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func scheduleFrameReport() {
        guard !isFrameReportScheduled else { return }
        isFrameReportScheduled = true

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            isFrameReportScheduled = false
            reportFrameIfNeeded()
        }
    }

    private func reportFrameIfNeeded() {
        guard let contentView = window?.contentView else { return }

        let frameInWindow = convert(bounds, to: nil)
        let contentFrameInWindow = contentView.convert(contentView.bounds, to: nil)
        let minX = frameInWindow.minX - contentFrameInWindow.minX

        guard lastReportedMinX.map({ abs($0 - minX) > 0.5 }) ?? true else { return }
        lastReportedMinX = minX
        onMinXChange?(minX)
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
