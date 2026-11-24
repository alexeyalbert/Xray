import Foundation
import Observation

struct TopicRequestFailureDetails: Equatable {
    enum Kind: Equatable {
        case providerError, zdrRouting, dataPolicy, refusal, invalidResponse, transport

        var title: LocalizedStringResource {
            switch self {
            case .providerError: "Provider request failed"
            case .zdrRouting: "ZDR provider exclusion"
            case .dataPolicy: "Data policy / guardrail restriction"
            case .refusal: "Provider refused the request"
            case .invalidResponse: "Invalid provider response"
            case .transport: "Connection failed"
            }
        }
    }

    let message: String
    let code: Int?
    var kind: Kind = .providerError
    var routingReasons: [String] = []
    var routingStep: String?
    var providerName: String?

    static func parse(_ data: Data) -> Self? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        let choices = object["choices"] as? [[String: Any]] ?? []
        if let error = object["error"] as? [String: Any]
            ?? choices.compactMap({ $0["error"] as? [String: Any] }).first {
            let metadata = error["metadata"] as? [String: Any] ?? [:]
            let reasons = (metadata["ineligibility_reasons"] as? [[String: Any]] ?? [])
                .filter { ($0["endpoint_count"] as? Int ?? 1) > 0 }
                .compactMap { $0["reason"] as? String }
            let message = error["message"] as? String ?? "The provider returned an error without an explanation."
            let code = (error["code"] as? NSNumber)?.intValue ?? (error["code"] as? String).flatMap(Int.init)
            let text = message.lowercased()
            let errorType = metadata["error_type"] as? String
            let kind: Kind
            // A generic 404 or a locally enabled ZDR toggle cannot establish the cause.
            // Only explicit endpoint exclusions or a ZDR-specific routing message do.
            if reasons.contains(where: { $0.lowercased().hasPrefix("zdr-violation") })
                || (code == 404 && (text.contains("zero data retention")
                    || text.contains("zero-data-retention") || text.contains("(zdr)")
                    || text.contains("zdr violation"))) {
                kind = .zdrRouting
            } else if errorType == "refusal" || errorType == "content_policy_violation" {
                kind = .refusal
            } else if text.contains("data policy") || text.contains("guardrail")
                || reasons.contains(where: { $0.contains("guardrail") || $0.contains("data-policy") }) {
                kind = .dataPolicy
            } else {
                kind = .providerError
            }
            return Self(
                message: String(message.prefix(2_000)), code: code, kind: kind,
                routingReasons: Array(reasons.prefix(20)).map { String($0.prefix(200)) },
                routingStep: (metadata["failed_routing_step"] as? String).map { String($0.prefix(200)) },
                providerName: (metadata["provider_name"] as? String).map { String($0.prefix(200)) }
            )
        }
        for choice in choices {
            let message = choice["message"] as? [String: Any] ?? [:]
            let refusal = (message["refusal"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !refusal.isEmpty || choice["finish_reason"] as? String == "content_filter" {
                return Self(
                    message: refusal.isEmpty ? "The provider declined the request through its content filter." : String(refusal.prefix(2_000)),
                    code: nil, kind: .refusal
                )
            }
        }
        return nil
    }
}

struct TopicRequestFailure: Identifiable, Equatable {
    let id = UUID()
    let timestamp = Date()
    let provider: String
    let model: String
    let postID: Int
    let attempt: Int
    let statusCode: Int?
    let requestedZDR: Bool?
    let details: TopicRequestFailureDetails
}

struct TopicRunZDRFailure: Equatable {
    let startedAt: Date
    let model: String
    let blockedPostCount: Int
}

@MainActor
@Observable
final class TopicRequestDiagnostics {
    static let shared = TopicRequestDiagnostics()
    private static let lastRunZDRFailureKey = "topic_last_run_zdr_failure"
    private(set) var failures: [TopicRequestFailure] = []
    private(set) var totalFailureCount = 0
    private(set) var lastRunZDRFailure: TopicRunZDRFailure?
    private(set) var pendingZDRAlert: TopicRequestFailure?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var runStartedAt: Date?
    @ObservationIgnored private var zdrBlockedPostIDs: Set<Int> = []
    @ObservationIgnored private var didNotifyZDRThisRun = false

    var isTopicRunActive: Bool { runStartedAt != nil }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let stored = defaults.dictionary(forKey: Self.lastRunZDRFailureKey),
           let startedAt = stored["startedAt"] as? Date,
           let model = stored["model"] as? String,
           let count = stored["blockedPostCount"] as? Int, count > 0 {
            lastRunZDRFailure = TopicRunZDRFailure(startedAt: startedAt, model: model, blockedPostCount: count)
        }
    }

    func beginTopicRun() {
        runStartedAt = Date()
        didNotifyZDRThisRun = false
        zdrBlockedPostIDs.removeAll()
        lastRunZDRFailure = nil
        defaults.removeObject(forKey: Self.lastRunZDRFailureKey)
    }

    func endTopicRun() {
        runStartedAt = nil
    }

    func dismissZDRAlert() {
        pendingZDRAlert = nil
    }

    func recordTopicSuccess(postID: Int) {
        removeZDRFailure(postID: postID)
    }

    private func removeZDRFailure(postID: Int) {
        guard isTopicRunActive, zdrBlockedPostIDs.remove(postID) != nil else { return }
        if let previous = lastRunZDRFailure, !zdrBlockedPostIDs.isEmpty {
            saveRunFailure(TopicRunZDRFailure(
                startedAt: previous.startedAt, model: previous.model,
                blockedPostCount: zdrBlockedPostIDs.count
            ))
        } else {
            lastRunZDRFailure = nil
            defaults.removeObject(forKey: Self.lastRunZDRFailureKey)
        }
    }

    private func saveRunFailure(_ failure: TopicRunZDRFailure) {
        lastRunZDRFailure = failure
        // Persist only a compact summary, never post contents or raw provider errors.
        defaults.set([
            "startedAt": failure.startedAt,
            "model": failure.model,
            "blockedPostCount": failure.blockedPostCount
        ], forKey: Self.lastRunZDRFailureKey)
    }

    func record(
        provider: String, model: String, postID: Int, attempt: Int,
        statusCode: Int?, requestedZDR: Bool?, details: TopicRequestFailureDetails
    ) {
        totalFailureCount += 1
        let failure = TopicRequestFailure(
            provider: provider, model: model, postID: postID, attempt: attempt,
            statusCode: statusCode, requestedZDR: requestedZDR, details: details
        )
        failures.insert(failure, at: 0)
        if provider == "OpenRouter", details.kind == .zdrRouting,
           let startedAt = runStartedAt, zdrBlockedPostIDs.insert(postID).inserted {
            saveRunFailure(TopicRunZDRFailure(
                startedAt: startedAt, model: model, blockedPostCount: zdrBlockedPostIDs.count
            ))
            if !didNotifyZDRThisRun {
                didNotifyZDRThisRun = true
                pendingZDRAlert = failure
            }
        } else if details.kind != .zdrRouting {
            // Keep the latest known cause for each post, rather than attributing
            // a later unrelated failure to an earlier ZDR exclusion.
            removeZDRFailure(postID: postID)
        }
        // Keep detailed diagnostic memory bounded during large archive runs.
        if failures.count > 20 {
            failures.removeLast(failures.count - 20)
        }
    }

    func clear() {
        failures.removeAll()
        totalFailureCount = 0
    }
}
