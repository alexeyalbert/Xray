//
//  SearchStatusCapsule.swift
//  Xray
//

import SwiftUI

struct SearchStatusCapsule: View {
    let isVisible: Bool
    let dotCount: Int
    @State private var displayOpacity: Double = 0
    @State private var displayBlur: CGFloat = 6
    @State private var displayScale: CGFloat = 0.96
    
    var body: some View {
        HStack(spacing: 1) {
            Text("Searching")
            HStack(spacing: 0) {
                ForEach(0..<3, id: \.self) { index in
                    Text(".")
                        .opacity(index < dotCount ? 1 : 0)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                }
            }
            .frame(width: 16, alignment: .leading)
        }
        .font(.system(size: 12, weight: .medium, design: .rounded))
        .lineLimit(1)
        .fixedSize()
        .foregroundStyle(Color(.secondaryLabelColor))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .compatibleGlassCapsule()
        .shadow(color: .primary.opacity(0.33), radius: 10, y: 3)
        .opacity(displayOpacity)
        .blur(radius: displayBlur)
        .scaleEffect(displayScale)
        .animation(.linear(duration: 0.08), value: dotCount)
        .allowsHitTesting(false)
        .task(id: isVisible) {
            if isVisible {
                withAnimation(.easeInOut(duration: 0.42)) {
                    displayOpacity = 1
                    displayScale = 1
                }
                try? await Task.sleep(nanoseconds: 120_000_000)
                if Task.isCancelled { return }
                withAnimation(.easeInOut(duration: 0.36)) {
                    displayBlur = 0
                }
            } else {
                withAnimation(.easeInOut(duration: 0.24)) {
                    displayBlur = 6
                    displayScale = 0.96
                }
                withAnimation(.easeInOut(duration: 0.52)) {
                    displayOpacity = 0
                }
            }
        }
    }
}

