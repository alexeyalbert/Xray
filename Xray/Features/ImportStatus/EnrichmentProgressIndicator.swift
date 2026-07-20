//
//  EnrichmentProgressIndicator.swift
//  Xray
//

import SwiftUI

struct EnrichmentProgressIndicator: View {
    @Bindable var importState: ImportState
    @State private var displayOpacity: Double = 0
    @State private var displayBlur: CGFloat = 6
    @State private var displayScale: CGFloat = 0.96

    private var isVisible: Bool {
        importState.isTopicAnnotating
            || importState.isTextEmbeddingGenerating
            || importState.isImageEmbeddingGenerating
    }

    private var title: LocalizedStringKey {
        if importState.isTopicAnnotating {
            "Generating Topics"
        } else if importState.isTextEmbeddingGenerating {
            "Generating Text Embeddings"
        } else {
            "Generating Image Embeddings"
        }
    }

    private var progress: Double {
        let value: Double
        if importState.isTopicAnnotating {
            value = importState.topicProgress
        } else if importState.isTextEmbeddingGenerating {
            value = importState.textEmbeddingProgress
        } else {
            value = importState.imageEmbeddingProgress
        }
        return min(max(value, 0), 1)
    }

    private var status: String {
        if importState.isTopicAnnotating {
            importState.topicStatus
        } else if importState.isTextEmbeddingGenerating {
            importState.textEmbeddingStatus
        } else {
            importState.imageEmbeddingStatus
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text(title)
                    .lineLimit(1)

                Spacer(minLength: 16)

                Text(progress, format: .percent.precision(.fractionLength(0)))
                    .monospacedDigit()
                    .foregroundStyle(Color(.secondaryLabelColor))
            }
            .font(.system(size: 12, weight: .medium, design: .rounded))

            ProgressView(value: progress) {
                Text(title)
            }
            .labelsHidden()
            .progressViewStyle(.linear)

            Text(status)
                .font(.caption)
                .foregroundStyle(Color(.secondaryLabelColor))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Color(.secondaryLabelColor))
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: 360)
        .compatibleGlassRoundedRectangle(cornerRadius: 14)
        .shadow(color: .primary.opacity(0.33), radius: 10, y: 3)
        .opacity(displayOpacity)
        .blur(radius: displayBlur)
        .scaleEffect(displayScale)
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

