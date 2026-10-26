import Foundation

public enum DomainPolicy {
    public static let youtubeDomains = [
        "youtube.com", "youtu.be", "googlevideo.com", "ytimg.com",
        "youtube-nocookie.com", "youtubei.googleapis.com"
    ]

    public static func normalize(_ host: String) -> String? {
        let value = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !value.isEmpty, value.utf8.count <= 253,
              !host.hasPrefix("."), !host.hasSuffix(".."),
              value.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 46 })
        else { return nil }
        let labels = value.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count > 1, labels.allSatisfy({
            !$0.isEmpty && $0.utf8.count <= 63 && !$0.hasPrefix("-") && !$0.hasSuffix("-")
        }) else { return nil }
        return value
    }

    public static func allows(_ host: String, domains: [String] = youtubeDomains) -> Bool {
        guard let host = normalize(host) else { return false }
        return domains.contains { host == $0 || host.hasSuffix("." + $0) }
    }
}
