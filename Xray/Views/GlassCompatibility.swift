//
//  GlassCompatibility.swift
//  Xray
//

import SwiftUI
import AppKit

extension View {
    @ViewBuilder
    func compatibleGlassCircleButton() -> some View {
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(LegacyGlassCircleButtonStyle())
        }
    }

    @ViewBuilder
    func compatibleGlassCapsule() -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect()
        } else {
            self
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.94), in: Capsule())
                .overlay {
                    Capsule()
                        .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
                }
        }
    }

    @ViewBuilder
    func compatibleGlassRoundedRectangle(cornerRadius: CGFloat) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(in: .rect(cornerRadius: cornerRadius))
        } else {
            self
                .background(
                    Color(nsColor: .controlBackgroundColor).opacity(0.94),
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
                }
        }
    }
}

private struct LegacyGlassCircleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(4)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.94), in: Circle())
            .overlay {
                Circle()
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
            }
            .contentShape(Circle())
            .opacity(configuration.isPressed ? 0.7 : 1)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
    }
}
