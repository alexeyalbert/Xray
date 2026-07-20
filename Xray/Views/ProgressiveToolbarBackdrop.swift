//
//  ProgressiveToolbarBackdrop.swift
//  Xray
//

#if os(macOS)
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

/// Installs a live AppKit backdrop whose blur radius progressively reaches zero,
/// measured from the top edge of the window.
///
/// The effect is attached to the window frame directly above its full-size content
/// view, so it sits above scrolling SwiftUI content but below AppKit's toolbar. The small
/// representable itself has no visible layout and does not participate in hit testing.
struct ProgressiveToolbarBackdrop: NSViewRepresentable {
    var fadeLength: CGFloat = 50
    var maxBlurRadius: CGFloat = 5

    func makeNSView(context: Context) -> ToolbarBackdropAttachmentView {
        let view = ToolbarBackdropAttachmentView()
        view.fadeLength = fadeLength
        view.maxBlurRadius = maxBlurRadius
        return view
    }

    func updateNSView(_ nsView: ToolbarBackdropAttachmentView, context: Context) {
        nsView.fadeLength = fadeLength
        nsView.maxBlurRadius = maxBlurRadius
        nsView.installIfPossible()
    }

    static func dismantleNSView(_ nsView: ToolbarBackdropAttachmentView, coordinator: ()) {
        nsView.uninstall()
    }
}

final class ToolbarBackdropAttachmentView: NSView {
    var fadeLength: CGFloat = 15 {
        didSet {
            guard fadeLength != oldValue else { return }
            updateBackdrop()
        }
    }

    var maxBlurRadius: CGFloat = 5 {
        didSet {
            guard maxBlurRadius != oldValue else { return }
            updateBackdrop()
        }
    }

    private let backdropView = ProgressiveToolbarBlurView()
    private weak var hostView: NSView?
    private weak var contentReferenceView: NSView?
    private var heightConstraint: NSLayoutConstraint?

    private var backdropExtent: CGFloat {
        max(1, fadeLength) + backdropView.clearTailLength
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        guard window != nil else {
            uninstall()
            return
        }

        // SwiftUI can attach a representable before NSWindow has finished replacing
        // its root hosting view. Deferring one run-loop turn gives us the final host.
        DispatchQueue.main.async { [weak self] in
            self?.installIfPossible()
        }
    }

    func installIfPossible() {
        guard let contentView = window?.contentView else { return }
        let overlayHost = contentView.superview ?? contentView

        if hostView === overlayHost,
           contentReferenceView === contentView,
           backdropView.superview === overlayHost {
            updateBackdrop()
            return
        }

        uninstall()

        hostView = overlayHost
        contentReferenceView = contentView
        backdropView.translatesAutoresizingMaskIntoConstraints = false
        backdropView.fadeLength = fadeLength
        backdropView.maxBlurRadius = maxBlurRadius
        overlayHost.addSubview(
            backdropView,
            positioned: .above,
            relativeTo: overlayHost === contentView ? nil : contentView
        )

        let heightConstraint = backdropView.heightAnchor.constraint(equalToConstant: backdropExtent)
        self.heightConstraint = heightConstraint

        NSLayoutConstraint.activate([
            backdropView.topAnchor.constraint(equalTo: contentView.topAnchor),
            backdropView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            backdropView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            heightConstraint
        ])
    }

    func uninstall() {
        heightConstraint = nil
        backdropView.removeFromSuperview()
        hostView = nil
        contentReferenceView = nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    private func updateBackdrop() {
        let resolvedFadeLength = max(1, fadeLength)
        backdropView.fadeLength = resolvedFadeLength
        backdropView.maxBlurRadius = max(0, maxBlurRadius)
        heightConstraint?.constant = resolvedFadeLength + backdropView.clearTailLength
    }
}

private final class ProgressiveToolbarBlurView: NSView {
    private static let minimumClearTailLength: CGFloat = 48

    var fadeLength: CGFloat = 152 {
        didSet {
            guard fadeLength != oldValue else { return }
            updateFilterIfNeeded(force: true)
        }
    }

    var maxBlurRadius: CGFloat = 24 {
        didSet {
            guard maxBlurRadius != oldValue else { return }
            updateFilterIfNeeded(force: true)
        }
    }

    private var filteredSize: CGSize = .zero
    private var filteredFadeLength: CGFloat = 0
    private var filteredBlurRadius: CGFloat = 0
    private var filteredMaskOriginY: CGFloat = 0

    var clearTailLength: CGFloat {
        max(Self.minimumClearTailLength, maxBlurRadius * 2)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        updateFilterIfNeeded()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    private func updateFilterIfNeeded(force: Bool = false) {
        let size = bounds.size
        guard size.width > 0, size.height > 0 else { return }

        let resolvedClearTailLength = clearTailLength
        let resolvedFadeLength = min(max(1, fadeLength), max(1, size.height - resolvedClearTailLength))
        let resolvedBlurRadius = max(0, maxBlurRadius)
        let maskRect = convert(bounds, to: nil)
        let maskOriginY = maskRect.minY
        guard force
            || size != filteredSize
            || resolvedFadeLength != filteredFadeLength
            || resolvedBlurRadius != filteredBlurRadius
            || maskOriginY != filteredMaskOriginY
        else {
            return
        }

        filteredSize = size
        filteredFadeLength = resolvedFadeLength
        filteredBlurRadius = resolvedBlurRadius
        filteredMaskOriginY = maskOriginY

        guard resolvedBlurRadius > 0 else {
            backgroundFilters = []
            return
        }

        let gradient = CIFilter.smoothLinearGradient()
        gradient.color0 = CIColor.black
        gradient.color1 = CIColor.white
        gradient.point0 = CGPoint(x: 0, y: maskOriginY + resolvedClearTailLength)
        gradient.point1 = CGPoint(
            x: 0,
            y: maskOriginY + resolvedClearTailLength + resolvedFadeLength
        )

        let blur = CIFilter.maskedVariableBlur()
        blur.radius = Float(resolvedBlurRadius)
        blur.mask = gradient.outputImage?.cropped(to: maskRect)
        backgroundFilters = [blur]
    }
}
#endif
