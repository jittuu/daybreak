import XCTest
@testable import DaybreakCore

final class CoreTests: XCTestCase {
    func testPolicyMatchesServiceDomainsWithoutMatchingLookalikes() {
        for host in ["youtube.com", "WWW.YouTube.com.", "rr1---sn-a5mekn7s.googlevideo.com", "i.ytimg.com", "youtubei.googleapis.com"] {
            XCTAssertTrue(DomainPolicy.allows(host), host)
        }
        for host in ["youtube.com.attacker.test", "notyoutube.com", "youtubei.googleapis.com.evil.test", "googleapis.com",
                     ".youtube.com", "a..youtube.com", "youtube.com..", "youtube.com\r\nHost: example.com", "127.0.0.1"] {
            XCTAssertFalse(DomainPolicy.allows(host), host)
        }
    }

    func testNativeFramesUseLittleEndianByteLengthAndRejectUnboundedInput() throws {
        let object: [String: Any] = ["type": "status", "note": "မြန်မာ"]
        let frame = try NativeFrame.encode(object)
        let length = try NativeFrame.length(Data(frame.prefix(4)))
        XCTAssertEqual(length, frame.count - 4)
        let decoded = try JSONSerialization.jsonObject(with: Data(frame.dropFirst(4))) as? [String: String]
        XCTAssertEqual(decoded?["note"], "မြန်မာ")
        XCTAssertThrowsError(try NativeFrame.length(Data([0, 0, 0, 0])))
        XCTAssertThrowsError(try NativeFrame.length(Data([255, 255, 255, 255])))
        XCTAssertThrowsError(try NativeFrame.length(Data([1, 0])))
    }

    func testHTTPParserWaitsForFullContentLength() throws {
        let partial = Data("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhel".utf8)
        XCTAssertNil(try HTTPResponse.body(partial))
        XCTAssertThrowsError(try HTTPResponse.body(partial, eof: true))
        var full = partial
        full.append(Data("lo".utf8))
        XCTAssertEqual(try HTTPResponse.body(full), Data("hello".utf8))
    }

    func testHTTPParserHandlesFragmentedChunkedDNSResponse() throws {
        let full = Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n2;ignored=yes\r\nde\r\n0\r\n\r\n".utf8)
        for count in 0..<full.count { XCTAssertNil(try HTTPResponse.body(Data(full.prefix(count)))) }
        XCTAssertEqual(try HTTPResponse.body(full), Data("abcde".utf8))
    }

    func testHTTPParserRejectsResolverErrorsAndMalformedChunks() {
        for value in [
            "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n",
            "HTTP/1.1 200 OK\r\nContent-Length: 99999999\r\n\r\n",
            "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nFFFFFFFFFFFFFFFFFFFFFFFF\r\n",
            "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n1\r\nx!!",
            "HTTP/1.1 200 OK\r\nTransfer-Encoding: gzip\r\n\r\n"
        ] { XCTAssertThrowsError(try HTTPResponse.body(Data(value.utf8))) }
        XCTAssertThrowsError(try HTTPResponse.body(Data(repeating: 65, count: HTTPResponse.maximumLength + 1)))
    }

    func testDNSParserHonorsAliasesTTLAndAddressFamilies() throws {
        let data = Data(#"{"Status":0,"Answer":[{"type":5,"TTL":20,"data":"alias.example"},{"type":1,"TTL":120,"data":"203.0.113.1"},{"type":1,"TTL":120,"data":"203.0.113.1"},{"type":28,"TTL":60,"data":"2001:db8::1"}]}"#.utf8)
        let ipv4 = try DNSAnswer.parse(data, recordType: 1)
        XCTAssertEqual(ipv4.addresses, ["203.0.113.1"])
        XCTAssertEqual(ipv4.ttl, 20)
        XCTAssertEqual(try DNSAnswer.parse(data, recordType: 28).addresses, ["2001:db8::1"])
        XCTAssertThrowsError(try DNSAnswer.parse(Data(#"{"Status":3}"#.utf8), recordType: 1))
        XCTAssertThrowsError(try DNSAnswer.parse(Data(#"{"Status":0,"Answer":[{"type":1,"data":"not-an-ip"}]}"#.utf8), recordType: 1))
        XCTAssertEqual(try DNSAnswer.parse(Data(#"{"Status":0,"Answer":[{"type":1,"TTL":0,"data":"203.0.113.1"}]}"#.utf8), recordType: 1).ttl, 0)
    }
}
