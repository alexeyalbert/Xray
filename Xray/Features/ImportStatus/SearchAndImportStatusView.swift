//
//  SearchAndImportStatusView.swift
//  Xray
//

import Foundation
import SwiftUI

struct SearchAndImportStatusView: View {
    @Bindable var importState: ImportState
    let query: String
    let mode: SearchMode
    let resultCount: Int
    let isSearching: Bool
    let startedAt: Date?
    let diagnostics: SQLiteManager.SearchDiagnostics?
    let error: String?
    let usesBookmarkOrder: Bool

    @State private var showsImportStatus = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if query.isEmpty {
                    ImportStatusView(importState: importState)
                } else {
                    searchStatus

                    Divider()

                    DisclosureGroup("Import & Database Status", isExpanded: $showsImportStatus) {
                        ImportStatusView(importState: importState)
                            .padding(.top, 10)
                    }
                    .font(.subheadline.weight(.semibold))
                }
            }
            .padding(16)
        }
    }

    @ViewBuilder
    private var searchStatus: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Current Search")
                    .font(.headline)
                Spacer()
                if isSearching {
                    ProgressView()
                        .controlSize(.small)
                } else if error == nil {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }

            diagnosticValue("Query", query)

            HStack(spacing: 24) {
                metric("Posts found", value: "\(diagnostics?.totalResultCount ?? resultCount)")
                metric("Mode", value: diagnostics?.mode ?? mode.rawValue)
                metric("Order", value: usesBookmarkOrder ? "Bookmark" : "Ranked")
            }

            if let diagnostics {
                metric("Total time", value: Self.formatDuration(diagnostics.totalDuration))

                if !diagnostics.countsByMethod.isEmpty {
                    sectionTitle("Candidates by method")
                    ForEach(diagnostics.countsByMethod, id: \.method) { item in
                        HStack {
                            Text(item.method)
                            Spacer()
                            Text("\(item.count)")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption)
                    }
                    Text("Counts are unique within each method; methods can overlap, and filters may reduce the final total.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                sectionTitle("Query plan")
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(diagnostics.plan.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                    if mode != .keyword {
                        Text("Text embedding threshold: \(diagnostics.minimumEmbeddingSimilarity, format: .number.precision(.fractionLength(3)))")
                            .font(.caption.monospaced())
                        Text("Image embedding threshold: \(diagnostics.minimumImageEmbeddingSimilarity, format: .number.precision(.fractionLength(3)))")
                            .font(.caption.monospaced())
                    }
                }

                if !diagnostics.operations.isEmpty {
                    sectionTitle("Operations run")
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(diagnostics.operations.enumerated()), id: \.element.id) { index, operation in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text("\(index + 1). \(operation.method)")
                                        .font(.caption.weight(.semibold))
                                    Spacer()
                                    Text("\(operation.resultCount) · \(Self.formatDuration(operation.duration))")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                                Text("Query: \(operation.query)")
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                                Text(operation.detail)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
            } else if isSearching, let startedAt {
                TimelineView(.periodic(from: .now, by: 0.1)) { context in
                    metric("Elapsed", value: Self.formatDuration(context.date.timeIntervalSince(startedAt)))
                }
                Text("The component counts, parsed query plan, thresholds, and individual operation timings will appear as the search completes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .padding(.top, 2)
    }

    private func metric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospacedDigit())
                .textSelection(.enabled)
        }
    }

    private func diagnosticValue(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private static func formatDuration(_ duration: TimeInterval) -> String {
        if duration < 1 {
            return "\(Int((duration * 1_000).rounded())) ms"
        }
        return String(format: "%.2f s", duration)
    }
}


