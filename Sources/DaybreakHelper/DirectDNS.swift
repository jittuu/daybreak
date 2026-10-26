import Foundation
import Network
import Security
import DaybreakCore

/// A single, bounded DoH request. DNS and content connections share the physical-interface constraint.
private final class DoHQuery {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private var response = Data()
    private var completion: ((Result<DNSAnswer, Error>) -> Void)?
    private var deadline: DispatchWorkItem?
    private let host: String
    private let recordType: Int

    init(host: String, recordType: Int, path: PhysicalPath, queue: DispatchQueue,
         completion: @escaping (Result<DNSAnswer, Error>) -> Void) {
        self.host = host
        self.recordType = recordType
        self.queue = queue
        self.completion = completion
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, "cloudflare-dns.com")
        sec_protocol_options_add_tls_application_protocol(tls.securityProtocolOptions, "http/1.1")
        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        parameters.requiredInterface = path.interface
        connection = NWConnection(host: "1.1.1.1", port: 443, using: parameters)
    }

    func start() {
        let timer = DispatchWorkItem { [weak self] in self?.finish(.failure(ProtocolError.invalid("Direct DNS timed out"))) }
        deadline = timer
        queue.asyncAfter(deadline: .now() + 8, execute: timer)
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                // Host names were already restricted to ASCII DNS labels by DomainPolicy.
                let request = "GET /dns-query?name=\(self.host)&type=\(self.recordType) HTTP/1.1\r\nHost: cloudflare-dns.com\r\nAccept: application/dns-json\r\nConnection: close\r\n\r\n"
                self.connection.send(content: Data(request.utf8), completion: .contentProcessed { [weak self] error in
                    guard let self else { return }
                    if let error { self.finish(.failure(error)) } else { self.receive() }
                })
            case .failed(let error): self.finish(.failure(error))
            default: break
            }
        }
        connection.start(queue: queue)
    }

    func cancel() { finish(.failure(ProtocolError.invalid("Network changed during DNS lookup"))) }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, eof, error in
            guard let self, self.completion != nil else { return }
            if let data { self.response.append(data) }
            do {
                if let body = try HTTPResponse.body(self.response, eof: eof) {
                    self.finish(.success(try DNSAnswer.parse(body, recordType: self.recordType)))
                } else if let error { self.finish(.failure(error)) }
                else { self.receive() }
            } catch { self.finish(.failure(error)) }
        }
    }

    private func finish(_ result: Result<DNSAnswer, Error>) {
        guard let callback = completion else { return }
        completion = nil
        deadline?.cancel()
        connection.stateUpdateHandler = nil
        connection.cancel()
        callback(result)
    }
}

final class DirectDNS {
    private struct Entry { let addresses: [String]; let expires: Date }
    private struct Pending {
        let id: UUID
        var queries: [DoHQuery]
        var answers: [Int: DNSAnswer] = [:]
        var remaining = 2
        var callbacks: [(Result<[String], Error>) -> Void]
    }
    private let queue: DispatchQueue
    private var cache: [String: Entry] = [:]
    private var pending: [String: Pending] = [:]

    init(queue: DispatchQueue) { self.queue = queue }

    func invalidate() {
        cache.removeAll(keepingCapacity: true)
        let previous = pending
        pending.removeAll(keepingCapacity: true)
        for lookup in previous.values {
            lookup.queries.forEach { $0.cancel() }
            lookup.callbacks.forEach { $0(.failure(ProtocolError.invalid("Physical network changed"))) }
        }
    }

    func resolve(_ host: String, path: PhysicalPath, completion: @escaping (Result<[String], Error>) -> Void) {
        let key = "\(path.generation):\(host)"
        if let entry = cache[key], entry.expires > Date() { completion(.success(entry.addresses)); return }
        if pending[key] != nil { pending[key]?.callbacks.append(completion); return }
        guard pending.count < 32 else { completion(.failure(ProtocolError.invalid("Too many DNS lookups"))); return }
        let id = UUID()
        pending[key] = Pending(id: id, queries: [], callbacks: [completion])
        for type in [1, 28] {
            let query = DoHQuery(host: host, recordType: type, path: path, queue: queue) { [weak self] result in
                guard let self, var lookup = self.pending[key], lookup.id == id else { return }
                if case .success(let answer) = result { lookup.answers[type] = answer }
                lookup.remaining -= 1
                self.pending[key] = lookup
                guard lookup.remaining == 0 else { return }
                self.pending.removeValue(forKey: key)
                // Interleave families, preferring IPv4, with bounded connection attempts.
                let v4 = lookup.answers[1]?.addresses ?? []
                let v6 = lookup.answers[28]?.addresses ?? []
                var addresses: [String] = []
                for index in 0..<min(3, max(v4.count, v6.count)) {
                    if index < v4.count { addresses.append(v4[index]) }
                    if index < v6.count { addresses.append(v6[index]) }
                }
                if addresses.isEmpty {
                    lookup.callbacks.forEach { $0(.failure(ProtocolError.invalid("Direct DNS returned no usable addresses"))) }
                } else {
                    if self.cache.count >= 128 { self.cache = self.cache.filter { $0.value.expires > Date() } }
                    if self.cache.count >= 128, let first = self.cache.keys.first { self.cache.removeValue(forKey: first) }
                    let ttl = lookup.answers.values.map(\.ttl).min() ?? 0
                    if ttl > 0 { self.cache[key] = Entry(addresses: addresses, expires: Date().addingTimeInterval(ttl)) }
                    lookup.callbacks.forEach { $0(.success(addresses)) }
                }
            }
            pending[key]?.queries.append(query)
            query.start()
        }
    }
}
