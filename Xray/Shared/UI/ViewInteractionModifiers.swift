//
//  ViewInteractionModifiers.swift
//  Xray
//

import AppKit
import SwiftUI

extension View {
    @ViewBuilder
    func `if`<Content: View>(
        _ condition: Bool,
        transform: (Self) -> Content
    ) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
    
    @ViewBuilder
    func cheapableGlassButton<S: ShapeStyle>(tint: S) -> some View {
        self.buttonStyle(.plain)
    }
    
    @ViewBuilder
    func cheapableCircleGlass() -> some View {
        self.background(Color.black.opacity(0.35), in: Circle())
    }
    
    func pointingHandOnHover() -> some View {
        self.onHover { isHovering in
            if isHovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}

