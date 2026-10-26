import Foundation
import Darwin

public struct DNSAnswer {
    public let addresses: [String]
    public let ttl: TimeInterval

    public static func parse(_ data: Data, recordType: Int) throws -> DNSAnswer {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = json["Status"] as? Int, status == 0 else {
            throw ProtocolError.invalid("DNS lookup failed")
        }
        var addresses: [String] = []
        var ttl = 300.0
        for item in json["Answer"] as? [[String: Any]] ?? [] {
            guard let kind = item["type"] as? Int else { continue }
            if let seconds = item["TTL"] as? Double { ttl = min(ttl, max(0, seconds)) }
            guard kind == recordType, let address = item["data"] as? String else { continue }
            var storage = in6_addr()
            let family = recordType == 1 ? AF_INET : AF_INET6
            guard address.withCString({ inet_pton(family, $0, &storage) }) == 1 else {
                throw ProtocolError.invalid("DNS resolver returned an invalid address")
            }
            if !addresses.contains(address) { addresses.append(address) }
        }
        return DNSAnswer(addresses: addresses, ttl: ttl)
    }
}
