import Foundation
import Network
import Darwin
import DaybreakCore

let helperVersion = "0.1.0"
let protocolVersion = 1

func diagnostic(_ message: String) {
    FileHandle.standardError.write(Data(("daybreak: " + message + "\n").utf8))
}

func readExactly(_ count: Int, allowEOF: Bool = false) throws -> Data? {
    var result = Data()
    while result.count < count {
        guard let chunk = try FileHandle.standardInput.read(upToCount: count - result.count), !chunk.isEmpty else {
            if allowEOF && result.isEmpty { return nil }
            throw ProtocolError.invalid("Truncated native message")
        }
        result.append(chunk)
    }
    return result
}

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.contains("--help") {
    print("""
    daybreak-helper \(helperVersion) — macOS physical-interface SOCKS5 proxy

    No flags: native-messaging mode (length-prefixed JSON on stdin/stdout).
    --serve                      Standalone mode; prints one JSON readiness line.
    --port=NUMBER                Listen on this loopback port (default: random).
    --interface=NAME             Require this physical interface, e.g. en0.
    --allow-domain=HOST          Extra allowed domain, standalone diagnostics only.
    --version                    Print version and exit.

    Every mode requires SOCKS5 username/password authentication and domain-name
    destinations. TCP ports 80 and 443 only. Native mode never accepts extra domains.
    """)
    exit(0)
}
if arguments.contains("--version") { print(helperVersion); exit(0) }

let standalone = arguments.contains("--serve")
var port: UInt16 = 0
var interface: String?
var domains = DomainPolicy.youtubeDomains
for argument in arguments {
    if argument == "--serve" { continue }
    if argument.hasPrefix("--port=") {
        guard let value = UInt16(argument.dropFirst(7)) else { diagnostic("Invalid port"); exit(2) }
        port = value
    } else if argument.hasPrefix("--interface=") {
        let name = String(argument.dropFirst(12))
        guard !name.isEmpty, name.utf8.count < 16 else { diagnostic("Invalid interface name"); exit(2) }
        interface = name
    } else if argument.hasPrefix("--allow-domain=") {
        guard standalone, let host = DomainPolicy.normalize(String(argument.dropFirst(15))) else {
            diagnostic("Extra domains require standalone mode and a valid hostname"); exit(2)
        }
        domains.append(host)
    } else if argument.hasPrefix("--") {
        diagnostic("Unknown option: \(argument)"); exit(2)
    }
    // Firefox supplies the native manifest path and extension ID as positional arguments.
}

signal(SIGPIPE, SIG_IGN)
let queue = DispatchQueue(label: "app.daybreak.network", qos: .userInitiated)
let network = PhysicalNetwork(queue: queue, preferredName: interface)
let server: ProxyServer
do { server = try ProxyServer(queue: queue, network: network, domains: domains, port: port) }
catch { diagnostic("Cannot create listener: \(error)"); exit(1) }

func output(_ object: [String: Any]) {
    do {
        if standalone {
            var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            data.append(10)
            try FileHandle.standardOutput.write(contentsOf: data)
        } else { try FileHandle.standardOutput.write(contentsOf: NativeFrame.encode(object)) }
    } catch { diagnostic("Cannot write response"); exit(1) }
}

var listeningPort: UInt16?
var announcedReady = false
func status(type: String) -> [String: Any] {
    var result: [String: Any] = [
        "type": type, "protocolVersion": protocolVersion, "version": helperVersion,
        "interface": network.current?.interface.name as Any? ?? NSNull(),
        "networkAvailable": network.current != nil,
        "activeConnections": server.activeConnections,
        "connectionsAccepted": server.connectionsAccepted
    ]
    if let port = listeningPort {
        result["proxy"] = ["host": "127.0.0.1", "port": Int(port), "username": server.username, "password": server.password]
    }
    return result
}

server.onReady = { port in
    listeningPort = port
    // Let both physical path monitors deliver their initial snapshots.
    queue.asyncAfter(deadline: .now() + 0.25) {
        announcedReady = true
        output(status(type: "ready"))
    }
}
server.onError = { message in
    diagnostic(message)
    output(["type": "error", "message": message, "protocolVersion": protocolVersion])
    exit(1)
}
server.onNetworkChange = {
    if announcedReady, !standalone { output(status(type: "status")) }
}

if !standalone {
    DispatchQueue.global(qos: .utility).async {
        do {
            while let header = try readExactly(4, allowEOF: true) {
                let length = try NativeFrame.length(header)
                guard let body = try readExactly(length),
                      let message = try JSONSerialization.jsonObject(with: body) as? [String: Any],
                      let command = message["type"] as? String else {
                    throw ProtocolError.invalid("Expected a native command object")
                }
                queue.async {
                    switch command {
                    case "status", "ping": output(status(type: "status"))
                    case "shutdown": exit(0)
                    default: output(["type": "error", "message": "Unknown command", "protocolVersion": protocolVersion])
                    }
                }
            }
            exit(0) // Browser disconnected: no persistent daemon remains.
        } catch { diagnostic("Native protocol: \(error)"); exit(1) }
    }
}

queue.async { network.start(); server.start() }
dispatchMain()
