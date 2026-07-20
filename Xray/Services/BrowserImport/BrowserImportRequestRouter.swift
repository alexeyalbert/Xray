import Foundation

final class BrowserImportRequestRouter {
    private let sessionStore: BrowserImportSessionStore
    private let batchHandler: BrowserImportReceiver.BatchHandler
    private let snapshotHandler: BrowserImportReceiver.SnapshotHandler

    init(
        sessionStore: BrowserImportSessionStore,
        batchHandler: @escaping BrowserImportReceiver.BatchHandler,
        snapshotHandler: @escaping BrowserImportReceiver.SnapshotHandler
    ) {
        self.sessionStore = sessionStore
        self.batchHandler = batchHandler
        self.snapshotHandler = snapshotHandler
    }

    func handle(request: HTTPRequest) async -> HTTPResponse {
        if request.method.uppercased() == "OPTIONS" {
            return response(statusCode: 204, statusText: "No Content", payload: EmptyPayload())
        }

        guard await sessionStore.validate(token: request.headers["x-xray-session-token"]) else {
            return response(
                statusCode: 401,
                statusText: "Unauthorized",
                payload: ErrorPayload(success: false, message: "Invalid session token.")
            )
        }

        do {
            let requestDecoder = makeRequestDecoder()
            switch (request.method.uppercased(), request.path) {
            case ("GET", "/session/status"):
                let snapshot = await sessionStore.snapshot()
                let payload = BrowserImportStatusResponse(
                    success: true,
                    receiverStatus: snapshot.receiverStatus,
                    activeSessionId: snapshot.activeSessionId,
                    batchesReceived: snapshot.batchesReceived,
                    totalAcceptedCount: snapshot.totalAcceptedCount,
                    totalInsertedCount: snapshot.totalInsertedCount,
                    totalSkippedExistingCount: snapshot.totalSkippedExistingCount,
                    completed: snapshot.completed,
                    lastBatchAtMillis: snapshot.lastBatchAt.map { Int64($0.timeIntervalSince1970 * 1000) }
                )
                return response(statusCode: 200, statusText: "OK", payload: payload)

            case ("POST", "/session/start"):
                let startRequest = try requestDecoder.decode(BrowserImportStartRequest.self, from: request.body)
                let startResponse = await sessionStore.startSession(request: startRequest)
                await publishSnapshot()
                return response(
                    statusCode: startResponse.success ? 200 : 409,
                    statusText: startResponse.success ? "OK" : "Conflict",
                    payload: startResponse
                )

            case ("POST", "/session/batch"):
                let batchRequest = try requestDecoder.decode(BrowserImportBatchRequest.self, from: request.body)

                if let existing = await sessionStore.existingAck(for: batchRequest) {
                    return response(statusCode: 200, statusText: "OK", payload: existing)
                }

                if let sessionError = await sessionStore.ensureSession(for: batchRequest) {
                    let failure = await sessionStore.failBatch(for: batchRequest, message: sessionError)
                    return response(statusCode: 409, statusText: "Conflict", payload: failure)
                }

                do {
                    let result = try await batchHandler(batchRequest)
                    let ack = await sessionStore.recordBatchAck(
                        for: batchRequest,
                        insertedCount: result.insertedCount,
                        skippedExistingCount: result.skippedExistingCount
                    )
                    await publishSnapshot()
                    return response(statusCode: 200, statusText: "OK", payload: ack)
                } catch {
                    let failure = await sessionStore.failBatch(for: batchRequest, message: error.localizedDescription)
                    await publishSnapshot()
                    return response(statusCode: 500, statusText: "Internal Server Error", payload: failure)
                }

            case ("POST", "/session/complete"):
                let completeRequest = try requestDecoder.decode(BrowserImportCompleteRequest.self, from: request.body)
                let completeResponse = await sessionStore.completeSession(request: completeRequest)
                await publishSnapshot()
                return response(
                    statusCode: completeResponse.success ? 200 : 409,
                    statusText: completeResponse.success ? "OK" : "Conflict",
                    payload: completeResponse
                )

            default:
                return response(
                    statusCode: 404,
                    statusText: "Not Found",
                    payload: ErrorPayload(success: false, message: "Unknown route.")
                )
            }
        } catch {
            return response(
                statusCode: 400,
                statusText: "Bad Request",
                payload: ErrorPayload(success: false, message: error.localizedDescription)
            )
        }
    }

    func publishSnapshot() async {
        await snapshotHandler(await sessionStore.snapshot())
    }

    private func response<T: Encodable>(statusCode: Int, statusText: String, payload: T) -> HTTPResponse {
        let body = (try? JSONEncoder().encode(payload)) ?? Data("{}".utf8)
        return HTTPResponse(
            statusCode: statusCode,
            statusText: statusText,
            headers: corsHeaders(contentType: "application/json; charset=utf-8"),
            body: body
        )
    }

    private func makeRequestDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        decoder.dateDecodingStrategy = .formatted(formatter)
        return decoder
    }

    private func corsHeaders(contentType: String) -> [String: String] {
        [
            "Content-Type": contentType,
            "Access-Control-Allow-Origin": "*",
            "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
            "Access-Control-Allow-Headers": "Content-Type, X-Xray-Session-Token",
            "Access-Control-Allow-Private-Network": "true",
            "Access-Control-Max-Age": "86400",
            "Cache-Control": "no-store"
        ]
    }
}
