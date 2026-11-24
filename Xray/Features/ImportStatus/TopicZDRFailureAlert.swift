import SwiftUI

struct TopicZDRFailureAlertModifier: ViewModifier {
    var isHostActive = true
    @State private var diagnostics = TopicRequestDiagnostics.shared

    func body(content: Content) -> some View {
        content
            .disabled(isHostActive && diagnostics.pendingZDRAlert != nil)
            .accessibilityHidden(isHostActive && diagnostics.pendingZDRAlert != nil)
            .overlay {
                if isHostActive, let failure = diagnostics.pendingZDRAlert {
                    ZStack {
                        Color.black.opacity(0.2)
                            .ignoresSafeArea()
                            .accessibilityHidden(true)

                        TopicZDRFailureAlert(
                            failure: failure,
                            onDismiss: diagnostics.dismissZDRAlert
                        )
                        .padding(24)
                    }
                }
            }
    }
}

struct TopicZDRFailureAlert: View {
    let failure: TopicRequestFailure
    let onDismiss: () -> Void
    @FocusState private var isOKFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text("No ZDR provider available")
                    .font(.headline)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("OpenRouter reported that ZDR requirements excluded providers for a topic request.")
                    .font(.callout)

                HStack(alignment: .firstTextBaseline) {
                    Text(failure.model)
                        .font(.caption.monospaced())
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    if let status = failure.statusCode {
                        Text("HTTP \(status)")
                            .font(.caption.monospacedDigit())
                            .fixedSize()
                    }
                }
                .foregroundStyle(.secondary)

                Text(failure.details.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(6)
                    .textSelection(.enabled)
                    .help(failure.details.message)
            }

            HStack {
                Spacer()
                Button(action: onDismiss) {
                    Text("OK")
                        .frame(minWidth: 48)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .focused($isOKFocused)
                .pointingHandOnHover()
            }
        }
        .padding(24)
        .frame(maxWidth: 440, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.1))
        }
        .shadow(color: .black.opacity(0.18), radius: 20, y: 8)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .onAppear { isOKFocused = true }
    }
}
