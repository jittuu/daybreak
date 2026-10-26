import Foundation
import Network
import DaybreakCore

final class ProxyServer {
    let username = "daybreak"
    let password = UUID().uuidString + UUID().uuidString
    private let queue: DispatchQueue
    private let network: PhysicalNetwork
    private let resolver: DirectDNS
    private let domains: [String]
    private let listener: NWListener
    private var sessions: [UUID: ProxySession] = [:]
    private(set) var connectionsAccepted = 0
    var onReady: ((UInt16) -> Void)?
    var onError: ((String) -> Void)?
    var onNetworkChange: (() -> Void)?

    init(queue: DispatchQueue, network: PhysicalNetwork, domains: [String], port: UInt16) throws {
        self.queue = queue
        self.network = network
        self.domains = domains
        resolver = DirectDNS(queue: queue)
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        listener = try NWListener(using: parameters)
        network.onChange = { [weak self] in
            guard let self else { return }
            self.resolver.invalidate()
            Array(self.sessions.values).forEach { $0.close() }
            self.onNetworkChange?()
        }
    }

    func start() {
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                if let port = self.listener.port?.rawValue { self.onReady?(port) }
            case .failed(let error): self.onError?("Proxy listener failed: \(error)")
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            guard self.sessions.count < 128 else { connection.cancel(); return }
            let id = UUID()
            let session = ProxySession(client: connection, queue: self.queue, network: self.network,
                                       resolver: self.resolver, domains: self.domains,
                                       username: self.username, password: self.password) { [weak self] in
                self?.sessions.removeValue(forKey: id)
            }
            self.sessions[id] = session
            self.connectionsAccepted += 1
            session.start()
        }
        listener.start(queue: queue)
    }

    var activeConnections: Int { sessions.count }
}

private final class ProxySession {
    private let client: NWConnection
    private let queue: DispatchQueue
    private let network: PhysicalNetwork
    private let resolver: DirectDNS
    private let domains: [String]
    private let username: String
    private let password: String
    private var upstream: NWConnection?
    private var deadline: DispatchWorkItem?
    private var attemptDeadline: DispatchWorkItem?
    private var closed = false
    private var completedDirections = 0
    private var onClose: (() -> Void)?

    init(client: NWConnection, queue: DispatchQueue, network: PhysicalNetwork, resolver: DirectDNS,
         domains: [String], username: String, password: String, onClose: @escaping () -> Void) {
        self.client = client
        self.queue = queue
        self.network = network
        self.resolver = resolver
        self.domains = domains
        self.username = username
        self.password = password
        self.onClose = onClose
    }

    func start() {
        let timer = DispatchWorkItem { [weak self] in self?.close() }
        deadline = timer
        queue.asyncAfter(deadline: .now() + 25, execute: timer)
        client.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.greeting()
            case .failed, .cancelled: self?.close()
            default: break
            }
        }
        client.start(queue: queue)
    }

    private func read(_ count: Int, completion: @escaping (Data) -> Void) {
        guard !closed else { return }
        readRemaining(count, accumulated: Data(), completion: completion)
    }

    private func readRemaining(_ count: Int, accumulated: Data, completion: @escaping (Data) -> Void) {
        client.receive(minimumIncompleteLength: 1, maximumLength: count - accumulated.count) { [weak self] data, _, eof, error in
            guard let self, !self.closed else { return }
            var result = accumulated
            if let data { result.append(data) }
            if result.count == count { completion(result) }
            else if eof || error != nil { self.close() }
            else { self.readRemaining(count, accumulated: result, completion: completion) }
        }
    }

    private func send(_ bytes: [UInt8], then: @escaping () -> Void) {
        guard !closed else { return }
        client.send(content: Data(bytes), completion: .contentProcessed { [weak self] error in
            guard let self, !self.closed else { return }
            if error != nil { self.close() } else { then() }
        })
    }

    private func greeting() {
        read(2) { [weak self] bytes in
            guard let self else { return }
            guard bytes[0] == 5, bytes[1] > 0 else { self.close(); return }
            self.read(Int(bytes[1])) { [weak self] methods in
                guard let self else { return }
                guard methods.contains(2) else { self.send([5, 255]) { self.close() }; return }
                self.send([5, 2]) { self.authenticate() }
            }
        }
    }

    private func authenticate() {
        read(2) { [weak self] header in
            guard let self else { return }
            guard header[0] == 1, header[1] > 0 else { self.close(); return }
            self.read(Int(header[1])) { [weak self] name in
                guard let self else { return }
                self.read(1) { [weak self] length in
                    guard let self else { return }
                    guard length[0] > 0 else { self.send([1, 1]) { self.close() }; return }
                    self.read(Int(length[0])) { [weak self] token in
                        guard let self else { return }
                        let valid = name == Data(self.username.utf8) && token == Data(self.password.utf8)
                        self.send([1, valid ? 0 : 1]) { if valid { self.request() } else { self.close() } }
                    }
                }
            }
        }
    }

    private func request() {
        read(4) { [weak self] header in
            guard let self else { return }
            guard header[0] == 5, header[2] == 0 else { self.reject(1); return }
            guard header[1] == 1 else { self.reject(7); return } // CONNECT only; no BIND or UDP relay.
            guard header[3] == 3 else { self.reject(8); return } // Domain names only; DNS stays in the helper.
            self.read(1) { [weak self] length in
                guard let self else { return }
                guard length[0] > 0 else { self.reject(8); return }
                self.read(Int(length[0]) + 2) { [weak self] destination in
                    guard let self else { return }
                    let bytes = Array(destination)
                    let count = Int(length[0])
                    let port = UInt16(bytes[count]) << 8 | UInt16(bytes[count + 1])
                    guard let host = String(bytes: bytes[..<count], encoding: .utf8),
                          let normalized = DomainPolicy.normalize(host),
                          DomainPolicy.allows(normalized, domains: self.domains), port == 443 || port == 80 else {
                        self.reject(2); return
                    }
                    guard let path = self.network.current else { self.reject(3); return }
                    self.resolver.resolve(normalized, path: path) { [weak self] result in
                        guard let self, !self.closed else { return }
                        guard self.network.current?.generation == path.generation else { self.reject(3); return }
                        switch result {
                        case .success(let addresses): self.connect(addresses, port: port, path: path)
                        case .failure: self.reject(4)
                        }
                    }
                }
            }
        }
    }

    private func connect(_ addresses: [String], port: UInt16, path: PhysicalPath) {
        guard !closed else { return }
        guard let address = addresses.first else { reject(5); return }
        guard network.current?.generation == path.generation else { reject(3); return }
        let parameters = NWParameters.tcp
        parameters.requiredInterface = path.interface
        let connection = NWConnection(host: NWEndpoint.Host(address), port: NWEndpoint.Port(rawValue: port)!, using: parameters)
        upstream = connection
        var finishedAttempt = false
        let next: () -> Void = { [weak self, weak connection] in
            guard !finishedAttempt else { return }
            finishedAttempt = true
            connection?.stateUpdateHandler = nil
            connection?.cancel()
            self?.attemptDeadline?.cancel()
            self?.connect(Array(addresses.dropFirst()), port: port, path: path)
        }
        let timer = DispatchWorkItem(block: next)
        attemptDeadline = timer
        queue.asyncAfter(deadline: .now() + 3, execute: timer)
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection, !self.closed, !finishedAttempt else { return }
            switch state {
            case .ready:
                finishedAttempt = true
                self.attemptDeadline?.cancel()
                connection.stateUpdateHandler = nil
                self.deadline?.cancel()
                self.send([5, 0, 0, 1, 0, 0, 0, 0, 0, 0]) {
                    self.relay(from: self.client, to: connection)
                    self.relay(from: connection, to: self.client)
                }
            case .failed: next()
            default: break
            }
        }
        connection.start(queue: queue)
    }

    private func relay(from source: NWConnection, to destination: NWConnection) {
        guard !closed else { return }
        // Read the next chunk only after the previous send completes: bounded memory and backpressure.
        source.receive(minimumIncompleteLength: 1, maximumLength: 32_768) { [weak self] data, _, eof, error in
            guard let self, !self.closed else { return }
            if error != nil { self.close(); return }
            destination.send(content: data, contentContext: eof ? .finalMessage : .defaultMessage,
                             isComplete: true, completion: .contentProcessed { [weak self] error in
                guard let self, !self.closed else { return }
                if error != nil { self.close() }
                else if eof {
                    self.completedDirections += 1
                    if self.completedDirections == 2 { self.close() }
                } else { self.relay(from: source, to: destination) }
            })
        }
    }

    private func reject(_ reason: UInt8) {
        send([5, reason, 0, 1, 0, 0, 0, 0, 0, 0]) { self.close() }
    }

    func close() {
        guard !closed else { return }
        closed = true
        deadline?.cancel()
        attemptDeadline?.cancel()
        client.stateUpdateHandler = nil
        client.cancel()
        upstream?.stateUpdateHandler = nil
        upstream?.cancel()
        let callback = onClose
        onClose = nil
        callback?()
    }
}
