import Foundation

public enum ProtocolError: Error, CustomStringConvertible {
    case invalid(String)
    public var description: String {
        switch self { case .invalid(let message): return message }
    }
}

public enum NativeFrame {
    public static let maximumLength = 65_536

    public static func encode(_ object: [String: Any]) throws -> Data {
        let body = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard body.count <= maximumLength else { throw ProtocolError.invalid("Native message is too large") }
        var size = UInt32(body.count).littleEndian
        var frame = withUnsafeBytes(of: &size) { Data($0) }
        frame.append(body)
        return frame
    }

    public static func length(_ header: Data) throws -> Int {
        guard header.count == 4 else { throw ProtocolError.invalid("Truncated native message header") }
        let bytes = Array(header)
        let value = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
        guard value > 0, value <= maximumLength else { throw ProtocolError.invalid("Invalid native message length") }
        return Int(value)
    }
}
