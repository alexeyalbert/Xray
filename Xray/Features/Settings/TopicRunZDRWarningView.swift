import SwiftUI

struct TopicRunZDRWarningView: View {
    @State private var diagnostics = TopicRequestDiagnostics.shared

    var body: some View {
        if let failure = diagnostics.lastRunZDRFailure {
            TopicRunZDRWarningContent(failure: failure)
        }
    }
}

struct TopicRunZDRWarningContent: View {
    let failure: TopicRunZDRFailure

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.orange)
                    .padding(.top, 1)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 5) {
                    Text("No ZDR provider available")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.primary)

                    if failure.blockedPostCount == 1 {
                        Text("One post couldn’t be tagged in the last run.")
                    } else {
                        Text("\(failure.blockedPostCount) posts couldn’t be tagged in the last run.")
                    }

                    HStack(spacing: 6) {
                        Text(failure.model)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(failure.model)

                        Text("·")
                            .accessibilityHidden(true)

                        Text(failure.startedAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                            .fixedSize()
                            .help(failure.startedAt.formatted(date: .complete, time: .standard))
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.top, 4)
        .padding(.bottom, 4)
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
    }
}
