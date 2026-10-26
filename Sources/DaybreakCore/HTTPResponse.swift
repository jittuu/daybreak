import Foundation

/// Bounded HTTP/1.1 response parser for the helper's own DoH requests, not browser traffic.
public enum HTTPResponse {
    public static let maximumLength = 131_072

    public static func body(_ data: Data, eof: Bool = false) throws -> Data? {
        guard data.count <= maximumLength else { throw ProtocolError.invalid("DNS response exceeds limit") }
        guard let separator = data.range(of: Data("\r\n\r\n".utf8)) else {
            if eof { throw ProtocolError.invalid("Incomplete DNS HTTP headers") }
            return nil
        }
        guard let headers = String(data: data[..<separator.lowerBound], encoding: .utf8) else {
            throw ProtocolError.invalid("Invalid DNS HTTP headers")
        }
        let lines = headers.components(separatedBy: "\r\n")
        guard let first = lines.first, first.hasPrefix("HTTP/1."), first.split(separator: " ").dropFirst().first == "200" else {
            throw ProtocolError.invalid("DNS resolver returned an HTTP error")
        }
        var fields: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { throw ProtocolError.invalid("Malformed DNS HTTP header") }
            fields[String(line[..<colon]).lowercased()] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        let payload = Data(data[separator.upperBound...])
        if let transfer = fields["transfer-encoding"] {
            guard transfer.lowercased() == "chunked" else { throw ProtocolError.invalid("Unsupported DNS transfer encoding") }
            return try decodeChunks(payload, eof: eof)
        }
        if let raw = fields["content-length"] {
            guard let count = Int(raw), count >= 0, count <= maximumLength else {
                throw ProtocolError.invalid("Invalid DNS content length")
            }
            guard payload.count >= count else {
                if eof { throw ProtocolError.invalid("Truncated DNS HTTP body") }
                return nil
            }
            return Data(payload.prefix(count))
        }
        return eof ? payload : nil
    }

    private static func decodeChunks(_ data: Data, eof: Bool) throws -> Data? {
        let bytes = Array(data)
        var cursor = 0
        var result = Data()
        while cursor < bytes.count {
            guard let end = (cursor..<max(cursor, bytes.count - 1)).first(where: { bytes[$0] == 13 && bytes[$0 + 1] == 10 }) else {
                if eof { throw ProtocolError.invalid("Truncated DNS chunk header") }
                return nil
            }
            let raw = String(decoding: bytes[cursor..<end], as: UTF8.self).split(separator: ";", maxSplits: 1).first ?? ""
            guard !raw.isEmpty, raw.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
                  let size = Int(raw, radix: 16), size <= maximumLength else {
                throw ProtocolError.invalid("Invalid DNS chunk size")
            }
            cursor = end + 2
            if size == 0 {
                guard bytes.count >= cursor + 2 else {
                    if eof { throw ProtocolError.invalid("Truncated final DNS chunk") }
                    return nil
                }
                guard bytes[cursor] == 13, bytes[cursor + 1] == 10 else {
                    throw ProtocolError.invalid("Unexpected DNS HTTP trailers")
                }
                return result
            }
            guard size <= maximumLength - result.count else { throw ProtocolError.invalid("DNS chunk body exceeds limit") }
            guard bytes.count >= cursor + size + 2 else {
                if eof { throw ProtocolError.invalid("Truncated DNS chunk") }
                return nil
            }
            result.append(contentsOf: bytes[cursor..<(cursor + size)])
            cursor += size
            guard bytes[cursor] == 13, bytes[cursor + 1] == 10 else {
                throw ProtocolError.invalid("Invalid DNS chunk terminator")
            }
            cursor += 2
        }
        if eof { throw ProtocolError.invalid("Missing final DNS chunk") }
        return nil
    }
}
