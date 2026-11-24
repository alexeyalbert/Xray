import Foundation
import Testing
@testable import Xray

@Suite("Topic request failure diagnostics")
@MainActor
struct TopicRequestDiagnosticsTests {
    private func details(_ json: String) throws -> TopicRequestFailureDetails {
        try #require(TopicRequestFailureDetails.parse(Data(json.utf8)))
    }

    @Test("Structured ZDR exclusions identify account and request restrictions")
    func structuredZDRExclusion() throws {
        let result = try details(#"{"error":{"code":404,"message":"No eligible endpoints","metadata":{"ineligibility_reasons":[{"reason":"zdr-violation-by-account","endpoint_count":1}],"failed_routing_step":"Filter by Data Policy"}}}"#)
        #expect(result.kind == .zdrRouting)
        #expect(result.code == 404)
        #expect(result.routingReasons == ["zdr-violation-by-account"])
        #expect(result.routingStep == "Filter by Data Policy")
    }

    @Test("Legacy explicit ZDR messages are recognized")
    func legacyZDRMessage() throws {
        let result = try details(#"{"error":{"code":"404","message":"No endpoints found matching your data policy (Zero data retention)."}}"#)
        #expect(result.kind == .zdrRouting)
        #expect(result.code == 404)
    }

    @Test("Generic policy blocks and missing models are not diagnosed as ZDR")
    func noFalseZDRAttribution() throws {
        let policy = try details(#"{"error":{"code":404,"message":"No endpoints found matching your data policy (Free model training)."}}"#)
        let missing = try details(#"{"error":{"code":404,"message":"Model not found"}}"#)
        let zeroExcluded = try details(#"{"error":{"code":404,"message":"Model not found","metadata":{"ineligibility_reasons":[{"reason":"zdr-violation-by-account","endpoint_count":0}]}}}"#)
        let priceLimit = try details(#"{"error":{"code":404,"message":"No eligible endpoints","metadata":{"ineligibility_reasons":[{"reason":"max-price","endpoint_count":1}]}}}"#)
        #expect(policy.kind == .dataPolicy)
        #expect(missing.kind == .providerError)
        #expect(zeroExcluded.kind == .providerError)
        #expect(priceLimit.kind == .providerError)
    }

    @Test("Provider errors embedded inside HTTP 200 choices are surfaced")
    func choiceError() throws {
        let result = try details(#"{"choices":[{"message":{"content":"partial"},"error":{"code":403,"message":"Blocked","metadata":{"error_type":"content_policy_violation","provider_name":"Example"}}}]}"#)
        #expect(result.kind == .refusal)
        #expect(result.message == "Blocked")
        #expect(result.providerName == "Example")
    }

    @Test("Successful refusal and content-filter response shapes are surfaced")
    func successfulRefusal() throws {
        let refusal = try details(#"{"choices":[{"message":{"content":null,"refusal":"I cannot process this request."},"finish_reason":"content_filter"}]}"#)
        let filter = try details(#"{"choices":[{"message":{"content":null},"finish_reason":"content_filter"}]}"#)
        #expect(refusal.kind == .refusal)
        #expect(refusal.message == "I cannot process this request.")
        #expect(filter.kind == .refusal)
    }

    @Test("Success and non-JSON bodies do not invent provider errors")
    func nonErrorResponses() {
        #expect(TopicRequestFailureDetails.parse(Data(#"{"choices":[{"message":{"content":"{}"}}]}"#.utf8)) == nil)
        #expect(TopicRequestFailureDetails.parse(Data("Bad gateway".utf8)) == nil)
    }

    @Test("Diagnostics retain bounded recent attempts and clear explicitly")
    func boundedHistory() {
        let diagnostics = TopicRequestDiagnostics()
        for postID in 0..<25 {
            diagnostics.record(
                provider: "OpenRouter", model: "test/model", postID: postID,
                attempt: 2, statusCode: 404, requestedZDR: false,
                details: TopicRequestFailureDetails(message: "Rejected", code: 404)
            )
        }
        #expect(diagnostics.totalFailureCount == 25)
        #expect(diagnostics.failures.count == 20)
        #expect(diagnostics.failures.first?.postID == 24)
        #expect(diagnostics.failures.last?.postID == 5)
        #expect(diagnostics.failures.first?.requestedZDR == false)
        diagnostics.clear()
        #expect(diagnostics.failures.isEmpty)
        #expect(diagnostics.totalFailureCount == 0)
    }

    private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let suite = "Xray.TopicRunZDRTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    private func recordZDRFailure(_ diagnostics: TopicRequestDiagnostics, postID: Int = 1) {
        diagnostics.record(
            provider: "OpenRouter", model: "test/model", postID: postID,
            attempt: 1, statusCode: 404, requestedZDR: true,
            details: TopicRequestFailureDetails(message: "ZDR excluded all endpoints", code: 404, kind: .zdrRouting)
        )
    }

    @Test("The latest run's ZDR warning survives a new diagnostics instance")
    func persistedRunWarning() throws {
        try withDefaults { defaults in
            let diagnostics = TopicRequestDiagnostics(defaults: defaults)
            #expect(diagnostics.lastRunZDRFailure == nil)
            diagnostics.beginTopicRun()
            recordZDRFailure(diagnostics)
            recordZDRFailure(diagnostics)
            diagnostics.endTopicRun()

            let restored = TopicRequestDiagnostics(defaults: defaults)
            let failure = try #require(restored.lastRunZDRFailure)
            #expect(failure == diagnostics.lastRunZDRFailure)
            #expect(failure.model == "test/model")
            #expect(failure.blockedPostCount == 1)
            #expect(restored.failures.isEmpty)
            #expect(!restored.isTopicRunActive)
            #expect(restored.pendingZDRAlert == nil)
        }
    }

    @Test("A successful retry removes only that post's ZDR warning")
    func retryRecovery() {
        withDefaults { defaults in
            let diagnostics = TopicRequestDiagnostics(defaults: defaults)
            diagnostics.beginTopicRun()
            recordZDRFailure(diagnostics, postID: 1)
            recordZDRFailure(diagnostics, postID: 2)
            diagnostics.recordTopicSuccess(postID: 1)
            #expect(diagnostics.lastRunZDRFailure?.blockedPostCount == 1)
            #expect(TopicRequestDiagnostics(defaults: defaults).lastRunZDRFailure?.blockedPostCount == 1)
            diagnostics.recordTopicSuccess(postID: 2)
            #expect(diagnostics.lastRunZDRFailure == nil)
            #expect(TopicRequestDiagnostics(defaults: defaults).lastRunZDRFailure == nil)
        }
    }

    @Test("The warning survives clearing debug history but is replaced by a new run")
    func runBoundaries() {
        withDefaults { defaults in
            let diagnostics = TopicRequestDiagnostics(defaults: defaults)
            diagnostics.beginTopicRun()
            recordZDRFailure(diagnostics)
            diagnostics.endTopicRun()
            diagnostics.clear()
            #expect(TopicRequestDiagnostics(defaults: defaults).lastRunZDRFailure != nil)

            diagnostics.beginTopicRun()
            diagnostics.record(
                provider: "OpenRouter", model: "test/model", postID: 1,
                attempt: 1, statusCode: 404, requestedZDR: true,
                details: TopicRequestFailureDetails(message: "Model not found", code: 404)
            )
            diagnostics.endTopicRun()
            #expect(TopicRequestDiagnostics(defaults: defaults).lastRunZDRFailure == nil)
        }
    }

    @Test("ZDR failure persistence happens while a run is still active")
    func interruptedRunWarning() {
        withDefaults { defaults in
            let diagnostics = TopicRequestDiagnostics(defaults: defaults)
            diagnostics.beginTopicRun()
            recordZDRFailure(diagnostics)
            #expect(diagnostics.isTopicRunActive)
            #expect(TopicRequestDiagnostics(defaults: defaults).lastRunZDRFailure?.blockedPostCount == 1)
        }
    }

    @Test("A later unrelated failure replaces the earlier ZDR cause for that post")
    func updatedFailureCause() {
        withDefaults { defaults in
            let diagnostics = TopicRequestDiagnostics(defaults: defaults)
            diagnostics.beginTopicRun()
            recordZDRFailure(diagnostics)
            diagnostics.record(
                provider: "OpenRouter", model: "test/model", postID: 1,
                attempt: 2, statusCode: 429, requestedZDR: true,
                details: TopicRequestFailureDetails(message: "Rate limited", code: 429)
            )
            #expect(TopicRequestDiagnostics(defaults: defaults).lastRunZDRFailure == nil)
        }
    }

    @Test("A ZDR alert appears once per run, even after acknowledging it")
    func oneAlertPerRun() throws {
        try withDefaults { defaults in
            let diagnostics = TopicRequestDiagnostics(defaults: defaults)
            diagnostics.beginTopicRun()
            recordZDRFailure(diagnostics, postID: 1)
            let first = try #require(diagnostics.pendingZDRAlert)
            #expect(first.model == "test/model")
            #expect(first.details.kind == .zdrRouting)

            recordZDRFailure(diagnostics, postID: 1)
            recordZDRFailure(diagnostics, postID: 2)
            #expect(diagnostics.pendingZDRAlert?.id == first.id)
            diagnostics.dismissZDRAlert()
            recordZDRFailure(diagnostics, postID: 3)
            #expect(diagnostics.pendingZDRAlert == nil)
            #expect(diagnostics.lastRunZDRFailure?.blockedPostCount == 3)

            diagnostics.endTopicRun()
            diagnostics.beginTopicRun()
            recordZDRFailure(diagnostics, postID: 4)
            #expect(diagnostics.pendingZDRAlert != nil)
            #expect(diagnostics.pendingZDRAlert?.id != first.id)
        }
    }

    @Test("Generic policy errors and inactive-run failures do not pop a ZDR alert")
    func alertRequiresConfirmedActiveZDRFailure() {
        withDefaults { defaults in
            let diagnostics = TopicRequestDiagnostics(defaults: defaults)
            recordZDRFailure(diagnostics)
            #expect(diagnostics.pendingZDRAlert == nil)
            diagnostics.beginTopicRun()
            diagnostics.record(
                provider: "OpenRouter", model: "test/model", postID: 1,
                attempt: 1, statusCode: 404, requestedZDR: true,
                details: TopicRequestFailureDetails(message: "Data policy restriction", code: 404, kind: .dataPolicy)
            )
            #expect(diagnostics.pendingZDRAlert == nil)
        }
    }

    @Test("Processing and run completion do not wait for alert dismissal")
    func processingContinuesWithAlertOpen() async throws {
        let suite = "Xray.TopicRunZDRTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let diagnostics = TopicRequestDiagnostics(defaults: defaults)
        diagnostics.beginTopicRun()
        recordZDRFailure(diagnostics)
        #expect(diagnostics.pendingZDRAlert != nil)

        let completed = await Task { @MainActor in
            diagnostics.recordTopicSuccess(postID: 1)
            diagnostics.endTopicRun()
            return true
        }.value
        #expect(completed)
        #expect(!diagnostics.isTopicRunActive)
        #expect(diagnostics.lastRunZDRFailure == nil)
        #expect(diagnostics.pendingZDRAlert != nil)
        diagnostics.dismissZDRAlert()
        #expect(diagnostics.pendingZDRAlert == nil)
    }
}
