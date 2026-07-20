import Foundation
import Network

final class HTTPConnectionHandler {
    let id = UUID()
    private let connection: NWConnection
    private let callbackQueue: DispatchQueue
    private let requestHandler: (HTTPRequest) async -> HTTPResponse
    private let onClose: (UUID) -> Void
    private let finishLock = NSLock()
    private var buffer = Data()
    private var didHandleRequest = false
    private var didFinish = false

    init(
        connection: NWConnection,
        callbackQueue: DispatchQueue,
        requestHandler: @escaping (HTTPRequest) async -> HTTPResponse,
        onClose: @escaping (UUID) -> Void
    ) {
        self.connection = connection
        self.callbackQueue = callbackQueue
        self.requestHandler = requestHandler
        self.onClose = onClose
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .failed = state {
                self.finish()
            } else if case .cancelled = state {
                self.finish()
            } else if case .waiting = state {
                self.connection.cancel()
            }
        }
        connection.start(queue: callbackQueue)
        receiveNextChunk()
    }

    private func receiveNextChunk() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let data, !data.isEmpty {
                self.buffer.append(data)
            }

            if let error {
                self.sendResponse(
                    HTTPResponse(
                        statusCode: 500,
                        statusText: "Internal Server Error",
                        headers: [:],
                        body: Data(error.localizedDescription.utf8)
                    )
                )
                return
            }

            if self.didHandleRequest {
                return
            }

            if let request = self.parseRequestIfComplete() {
                self.didHandleRequest = true
                Task {
                    let response = await self.requestHandler(request)
                    self.sendResponse(response)
                }
                return
            }

            if isComplete {
                self.sendResponse(
                    HTTPResponse(
                        statusCode: 400,
                        statusText: "Bad Request",
                        headers: [:],
                        body: Data("Incomplete HTTP request.".utf8)
                    )
                )
                return
            }

            self.receiveNextChunk()
        }
    }

    private func parseRequestIfComplete() -> HTTPRequest? {
        guard let headerBoundary = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            return nil
        }

        let headerData = buffer.subdata(in: 0..<headerBoundary.lowerBound)
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            return nil
        }

        let headerLines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = headerLines.first else {
            return nil
        }

        let requestParts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard requestParts.count >= 2 else {
            return nil
        }

        var headers: [String: String] = [:]
        for line in headerLines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[key] = value
        }

        let contentLength = Int(headers["content-length"] ?? "") ?? 0
        let bodyStart = headerBoundary.upperBound
        let totalNeeded = bodyStart + contentLength
        guard buffer.count >= totalNeeded else {
            return nil
        }

        let body = contentLength > 0 ? buffer.subdata(in: bodyStart..<totalNeeded) : Data()
        return HTTPRequest(
            method: String(requestParts[0]),
            path: String(requestParts[1]),
            headers: headers,
            body: body
        )
    }

    private func sendResponse(_ response: HTTPResponse) {
        var responseData = Data()
        let statusLine = "HTTP/1.1 \(response.statusCode) \(response.statusText)\r\n"
        responseData.append(contentsOf: statusLine.utf8)

        var headers = response.headers
        headers["Content-Length"] = String(response.body.count)
        headers["Connection"] = "close"

        for (key, value) in headers {
            responseData.append(contentsOf: "\(key): \(value)\r\n".utf8)
        }
        responseData.append(contentsOf: "\r\n".utf8)
        responseData.append(response.body)

        connection.send(content: responseData, completion: .contentProcessed { [weak self] _ in
            self?.finish()
        })
    }

    func cancel() {
        finish()
    }

    private func finish() {
        finishLock.lock()
        guard !didFinish else {
            finishLock.unlock()
            return
        }
        didFinish = true
        finishLock.unlock()

        connection.stateUpdateHandler = nil
        connection.cancel()
        onClose(id)
    }
}
