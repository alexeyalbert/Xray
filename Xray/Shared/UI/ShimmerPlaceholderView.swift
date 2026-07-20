//
//  ShimmerPlaceholderView.swift
//  Xray
//

import SwiftUI

struct ShimmerPlaceholderView: View, Equatable {
    var cornerRadius: CGFloat = 0
    var includeBackgroundFill: Bool = false

    static func == (lhs: ShimmerPlaceholderView, rhs: ShimmerPlaceholderView) -> Bool {
        lhs.cornerRadius == rhs.cornerRadius
            && lhs.includeBackgroundFill == rhs.includeBackgroundFill
    }

    @Environment(\.colorScheme) private var colorScheme
    // Animated by Core Animation via a single `withAnimation` so the shimmer
    // does not force a per-display-frame SwiftUI body rebuild the way
    // `TimelineView(.animation)` did.
    @State private var phase: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let shimmerWidth = max(width * 0.55, 72)
            let travel = width + (shimmerWidth * 2)

            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(baseGradient)
                .background {
                    if includeBackgroundFill {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(backgroundFill)
                    }
                }
                .overlay {
                    LinearGradient(
                        colors: highlightColors,
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: shimmerWidth)
                    .blur(radius: 6)
                    .offset(x: (phase * travel) - shimmerWidth)
                }
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .onAppear {
                    phase = 0
                    withAnimation(.linear(duration: 1.35).repeatForever(autoreverses: false)) {
                        phase = 1
                    }
                }
        }
        .allowsHitTesting(false)
    }

    private var baseGradient: LinearGradient {
        LinearGradient(
            colors: baseColors,
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var baseColors: [Color] {
        if colorScheme == .dark {
            [
                .white.opacity(0.10),
                .white.opacity(0.06),
                .white.opacity(0.10)
            ]
        } else {
            [
                .black.opacity(0.10),
                .black.opacity(0.06),
                .black.opacity(0.10)
            ]
        }
    }

    private var backgroundFill: Color {
        colorScheme == .dark ? .secondary.opacity(0.28) : .secondary.opacity(0.18)
    }

    private var highlightColors: [Color] {
        if colorScheme == .dark {
            [
                .clear,
                .white.opacity(0.16),
                .clear
            ]
        } else {
            [
                .clear,
                .white.opacity(0.85),
                .clear
            ]
        }
    }
}

