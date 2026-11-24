import SwiftUI

struct TopicRequestDiagnosticsView: View {
    @State private var diagnostics = TopicRequestDiagnostics.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Topic Request Failures")
                    .font(.headline)
                Spacer()
                if !diagnostics.failures.isEmpty {
                    Button("Clear") { diagnostics.clear() }
                        .buttonStyle(.borderless)
                        .pointingHandOnHover()
                }
            }

            if diagnostics.failures.isEmpty {
                Text("No topic request failures recorded this session.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Showing the latest \(diagnostics.failures.count) of \(diagnostics.totalFailureCount) failed attempts this session. Retries are listed separately; a later attempt may succeed.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                ForEach(diagnostics.failures) { failure in
                    TopicRequestFailureRow(failure: failure)
                }
            }
        }
    }
}

private struct TopicRequestFailureRow: View {
    let failure: TopicRequestFailure

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label {
                Text(failure.details.kind.title)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.orange)

            Text("\(failure.timestamp.formatted(date: .omitted, time: .standard)) · \(failure.provider) · \(failure.model)")
                .font(.caption2)
            Text("Post \(failure.postID) · Attempt \(failure.attempt)")
                .font(.caption2.monospacedDigit())

            if let status = failure.statusCode {
                Text("HTTP \(status)")
                    .font(.caption2.monospacedDigit())
            }
            if let code = failure.details.code, code != failure.statusCode {
                Text("Provider error code: \(code)")
                    .font(.caption2.monospacedDigit())
            }
            if let requestedZDR = failure.requestedZDR {
                Text(requestedZDR ? "Request ZDR: on" : "Request ZDR: off (account policies still apply)")
                    .font(.caption2)
            }
            if failure.details.kind == .zdrRouting {
                Text("OpenRouter explicitly reported ZDR provider exclusions. Other routing restrictions may also apply.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if failure.details.kind == .dataPolicy {
                Text("The provider reported a policy restriction, without confirming ZDR as the cause.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Text(failure.details.message)
                .font(.caption.monospaced())
            if let provider = failure.details.providerName {
                Text("Upstream provider: \(provider)")
                    .font(.caption2)
            }
            if let step = failure.details.routingStep {
                Text("Routing step: \(step)")
                    .font(.caption2)
            }
            if !failure.details.routingReasons.isEmpty {
                Text("Exclusions: \(failure.details.routingReasons.joined(separator: ", "))")
                    .font(.caption2.monospaced())
            }
        }
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.08)))
    }
}
