import Foundation
import Network

final class BrowserImportReceiver {
    typealias BatchHandler = (BrowserImportBatchRequest) async throws -> (insertedCount: Int, skippedExistingCount: Int)
    typealias SnapshotHandler = (BrowserImportSnapshot) async -> Void

    private let token: String
    private let sessionStore: BrowserImportSessionStore
    private let requestRouter: BrowserImportRequestRouter
    private let networkQueue = DispatchQueue(label: "com.alexeyalbert.Xray.browser-import-receiver", qos: .userInitiated)
    private let lifecycleLock = NSLock()

    private var listener: NWListener?
    private var activeConnections: [UUID: HTTPConnectionHandler] = [:]
    private var isStopped = true

    init(token: String, batchHandler: @escaping BatchHandler, snapshotHandler: @escaping SnapshotHandler) {
        let sessionStore = BrowserImportSessionStore(token: token)
        self.token = token
        self.sessionStore = sessionStore
        self.requestRouter = BrowserImportRequestRouter(
            sessionStore: sessionStore,
            batchHandler: batchHandler,
            snapshotHandler: snapshotHandler
        )
    }

    func start(preferredPort: UInt16? = nil) async throws -> UInt16 {
        let boundPort = try reserveListeningPort(preferredPort: preferredPort)
        let listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: boundPort)!)

        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            let handler = HTTPConnectionHandler(connection: connection, callbackQueue: self.networkQueue) { request in
                await self.requestRouter.handle(request: request)
            } onClose: { [weak self] id in
                self?.removeActiveConnection(id: id)
            }
            if !self.activateConnection(handler) {
                handler.cancel()
            }
        }

        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            Task {
                switch state {
                case .ready:
                    await self.sessionStore.setListening(true, status: "Receiver is listening on localhost.")
                    await self.requestRouter.publishSnapshot()
                case let .failed(error):
                    await self.sessionStore.setListening(false, status: "Receiver failed: \(error.localizedDescription)")
                    await self.requestRouter.publishSnapshot()
                case .cancelled:
                    await self.sessionStore.setListening(false, status: "Receiver is stopped.")
                    await self.requestRouter.publishSnapshot()
                default:
                    break
                }
            }
        }

        lifecycleLock.lock()
        self.listener = listener
        isStopped = false
        listener.start(queue: networkQueue)
        lifecycleLock.unlock()
        return boundPort
    }

    func stop() {
        lifecycleLock.lock()
        guard !isStopped else {
            lifecycleLock.unlock()
            return
        }
        isStopped = true
        let listenerToCancel = listener
        listener = nil
        let connectionsToCancel = Array(activeConnections.values)
        activeConnections.removeAll()
        lifecycleLock.unlock()

        listenerToCancel?.cancel()
        for connection in connectionsToCancel {
            connection.cancel()
        }
    }

    func currentToken() -> String {
        token
    }

    private func activateConnection(_ handler: HTTPConnectionHandler) -> Bool {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        guard !isStopped else { return false }
        activeConnections[handler.id] = handler
        handler.start()
        return true
    }

    private func removeActiveConnection(id: UUID) {
        lifecycleLock.lock()
        activeConnections.removeValue(forKey: id)
        lifecycleLock.unlock()
    }

    private func reserveListeningPort(preferredPort: UInt16?) throws -> UInt16 {
        if let preferredPort,
           let port = NWEndpoint.Port(rawValue: preferredPort) {
            do {
                let probe = try NWListener(using: .tcp, on: port)
                probe.cancel()
                return preferredPort
            } catch {
                // Fall back to a random port if the preferred one is unavailable.
            }
        }

        for _ in 0..<32 {
            let candidate = UInt16.random(in: 49152...65535)
            guard let port = NWEndpoint.Port(rawValue: candidate) else { continue }
            do {
                let probe = try NWListener(using: .tcp, on: port)
                probe.cancel()
                return candidate
            } catch {
                continue
            }
        }

        throw NSError(
            domain: "BrowserImportReceiver",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Could not reserve a localhost port for browser import."]
        )
    }
}
