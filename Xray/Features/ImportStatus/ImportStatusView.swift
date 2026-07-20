//
//  ImportStatusView.swift
//  Xray
//

import SwiftUI

struct ImportStatusView: View {
    @Bindable var importState: ImportState
    
    var body: some View {
        let isEnrichmentRunning = importState.isTopicAnnotating
            || importState.isTextEmbeddingGenerating
            || importState.isImageEmbeddingGenerating
        let hasEnrichmentCompletion = importState.topicCompleted
            || importState.textEmbeddingCompleted
            || importState.imageEmbeddingCompleted
        let hasEnrichmentError = importState.topicError != nil
            || importState.textEmbeddingError != nil
            || importState.imageEmbeddingError != nil

        VStack(alignment: .leading, spacing: 12) {
            Text("Import & Database Status")
                .font(.headline)
            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Browser Import Receiver")
                    .font(.subheadline.weight(.semibold))
                HStack(spacing: 8) {
                    Image(systemName: importState.isBrowserImportReceiverRunning ? "dot.radiowaves.left.and.right" : "pause.circle")
                        .foregroundStyle(importState.isBrowserImportReceiverRunning ? .green : .secondary)
                    Text(importState.browserImportReceiverStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !importState.browserImportReceiverURL.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Receiver URL")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(importState.browserImportReceiverURL)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Session Token")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(importState.browserImportReceiverToken)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }

                if let activeSessionID = importState.browserImportActiveSessionID {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Active Browser Session")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(activeSessionID)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }

                if importState.browserImportBatchesReceived > 0 || importState.browserImportAcceptedCount > 0 {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Streamed Import Totals")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text("Batches: \(importState.browserImportBatchesReceived)")
                            .font(.caption.monospaced())
                        Text("Accepted: \(importState.browserImportAcceptedCount)")
                            .font(.caption.monospaced())
                        Text("Inserted: \(importState.browserImportInsertedCount)")
                            .font(.caption.monospaced())
                        Text("Skipped existing: \(importState.browserImportSkippedExistingCount)")
                            .font(.caption.monospaced())
                        if let lastBatchAt = importState.browserImportLastBatchAt {
                            Text("Last batch: \(lastBatchAt.formatted(date: .omitted, time: .standard))")
                                .font(.caption.monospaced())
                        }
                    }
                }

                if importState.browserImportCompleted {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("Browser session completed.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let browserImportError = importState.browserImportReceiverError {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(browserImportError)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Divider()
            
            if importState.isDatabaseImporting && !isEnrichmentRunning {
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: importState.databaseImportProgress) {
                        Text("Saving to Database")
                    } currentValueLabel: {
                        Text("\(Int(importState.databaseImportProgress * 100))%")
                            .monospacedDigit()
                    }
                    .progressViewStyle(.linear)
                    Text(importState.databaseImportStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .transaction { $0.animation = nil }
            }
            
            if importState.databaseImportCompleted && !hasEnrichmentCompletion {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    VStack(alignment: .leading) {
                        Text("Database Import Complete").font(.subheadline)
                        Text(importState.databaseImportStatus).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            
            if let dbError = importState.databaseImportError, !hasEnrichmentError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    VStack(alignment: .leading) {
                        Text("Database Import Error").font(.subheadline)
                        Text(dbError).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            
            // Topic annotation status
            if importState.isTopicAnnotating {
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: importState.topicProgress) {
                        Text("Annotating Topics")
                    } currentValueLabel: {
                        Text("\(Int(importState.topicProgress * 100))%")
                            .monospacedDigit()
                    }
                    .progressViewStyle(.linear)
                    Text(importState.topicStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .transaction { $0.animation = nil }
            }
            
            // Text embeddings status
            else if importState.isTextEmbeddingGenerating {
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: importState.textEmbeddingProgress) {
                        Text("Generating Text Embeddings")
                    } currentValueLabel: {
                        Text("\(Int(importState.textEmbeddingProgress * 100))%")
                            .monospacedDigit()
                    }
                    .progressViewStyle(.linear)
                    Text(importState.textEmbeddingStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .transaction { $0.animation = nil }
            }
            
            // Image embeddings status
            else if importState.isImageEmbeddingGenerating {
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: importState.imageEmbeddingProgress) {
                        Text("Generating Image Embeddings")
                    } currentValueLabel: {
                        Text("\(Int(importState.imageEmbeddingProgress * 100))%")
                            .monospacedDigit()
                    }
                    .progressViewStyle(.linear)
                    Text(importState.imageEmbeddingStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .transaction { $0.animation = nil }
            }
            
            if importState.topicCompleted {
                HStack(spacing: 8) {
                    Image(systemName: "wand.and.stars").foregroundStyle(.blue)
                    VStack(alignment: .leading) {
                        Text("Topic Annotation Complete").font(.subheadline)
                        Text(importState.topicStatus).font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else if importState.textEmbeddingCompleted {
                HStack(spacing: 8) {
                    Image(systemName: "square.grid.3x3.square.fill").foregroundStyle(.blue)
                    VStack(alignment: .leading) {
                        Text("Text Embedding Pass Complete").font(.subheadline)
                        Text(importState.textEmbeddingStatus).font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else if importState.imageEmbeddingCompleted {
                HStack(spacing: 8) {
                    Image(systemName: "photo.fill").foregroundStyle(.blue)
                    VStack(alignment: .leading) {
                        Text("Image Embedding Pass Complete").font(.subheadline)
                        Text(importState.imageEmbeddingStatus).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            
            if let topicError = importState.topicError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    VStack(alignment: .leading) {
                        Text("Topic Annotation Error").font(.subheadline)
                        Text(topicError).font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else if let textEmbeddingError = importState.textEmbeddingError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    VStack(alignment: .leading) {
                        Text("Text Embedding Error").font(.subheadline)
                        Text(textEmbeddingError).font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else if let imageEmbeddingError = importState.imageEmbeddingError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    VStack(alignment: .leading) {
                        Text("Image Embedding Error").font(.subheadline)
                        Text(imageEmbeddingError).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            
            if let loadError = importState.loadError {
                HStack(spacing: 8) {
                    Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                    Text(loadError).font(.caption)
                }
            }
        }
    }
}


