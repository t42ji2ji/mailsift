import CryptoKit
import Foundation
import dnssd

/// Sender pictures from public sources, cached in ~/Library/Caches/MailSift/avatars: the person's Gravatar,
/// else the company's BIMI logo (published in its DNS), else the icon of the sender's website.
public actor AvatarStore {
    public static let shared = AvatarStore()

    /// Mail providers: their logo says nothing about the person, so only Gravatar is tried.
    static let freeMail: Set<String> = [
        "gmail.com", "googlemail.com", "icloud.com", "me.com", "mac.com", "outlook.com", "hotmail.com", "live.com",
        "msn.com", "yahoo.com", "yahoo.com.tw", "ymail.com", "proton.me", "protonmail.com", "aol.com", "gmx.com",
        "qq.com", "163.com", "126.com", "privaterelay.appleid.com",
    ]
    /// A source found nothing: asked again after a week.
    static let missRetry: TimeInterval = 7 * 86_400

    private let dir: URL
    private var running: [String: Task<Data?, Never>] = [:]

    public init(dir: URL? = nil) {
        self.dir = dir ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MailSift/avatars", isDirectory: true)
    }

    /// Image bytes (PNG, JPEG, ICO or SVG) for an address, or nil when no source has one.
    /// With `online` false only what is already cached is returned.
    public func image(for address: String, online: Bool = true) async -> Data? {
        let address = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let at = address.lastIndex(of: "@"), at != address.startIndex else { return nil }
        let domain = String(address[address.index(after: at)...])
        guard domain.contains(".") else { return nil }
        if let face = await cached("g-" + Self.sha256(address), online: online, { await Self.gravatar(address) }) { return face }
        if Self.freeMail.contains(domain) { return nil }
        if let logo = await cached("b-" + domain, online: online, { await Self.bimi(domain) }) { return logo }
        let site = Self.siteDomain(domain)
        return await cached("i-" + site, online: online, { await Self.siteIcon(site) })
    }

    /// A cached result (an empty file records a miss), else one fetch shared by every caller asking meanwhile.
    private func cached(_ key: String, online: Bool, _ fetch: @escaping @Sendable () async -> Data?) async -> Data? {
        let file = dir.appendingPathComponent(key)
        if let data = try? Data(contentsOf: file) {
            if !data.isEmpty { return data }
            let age = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let age, -age.timeIntervalSinceNow < Self.missRetry { return nil }
        }
        guard online else { return nil }
        if let task = running[key] { return await task.value }
        let task = Task { await fetch() }
        running[key] = task
        let data = await task.value
        running[key] = nil
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? (data ?? Data()).write(to: file, options: .atomic)
        return data
    }

    // MARK: Sources

    static func gravatar(_ address: String) async -> Data? {
        await image(at: URL(string: "https://gravatar.com/avatar/\(sha256(address))?s=128&d=404"))
    }

    /// The BIMI logo of the domain or the nearest parent publishing one (mail.notion.so → notion.so).
    static func bimi(_ domain: String) async -> Data? {
        let labels = domain.split(separator: ".")
        let floor = siteDomain(domain).split(separator: ".").count
        for n in stride(from: labels.count, through: max(floor, 2), by: -1) {
            let name = labels.suffix(n).joined(separator: ".")
            let records = await Task.detached { txtRecords("default._bimi." + name) }.value
            if let url = records.lazy.compactMap(bimiLogo).first { return await image(at: url) }
        }
        return nil
    }

    static func siteIcon(_ site: String) async -> Data? {
        for path in ["https://\(site)/apple-touch-icon.png", "https://www.\(site)/apple-touch-icon.png", "https://\(site)/favicon.ico"] {
            if let data = await image(at: URL(string: path)) { return data }
        }
        return nil
    }

    /// The body of a 200 response that is an image; sites often answer a missing icon with an HTML page.
    private static func image(at url: URL?) async -> Data? {
        guard let url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue("MailSift", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200, !data.isEmpty,
              http.mimeType?.hasPrefix("image/") == true || url.pathExtension == "svg" else { return nil }
        return data
    }

    // MARK: Parsing

    /// The logo URL of a BIMI record (`v=BIMI1; l=https://…svg; a=…`); nil for other records or an empty `l=`.
    static func bimiLogo(_ record: String) -> URL? {
        let tags = record.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        guard tags.first?.lowercased() == "v=bimi1",
              let l = tags.first(where: { $0.lowercased().hasPrefix("l=") })?.dropFirst(2).trimmingCharacters(in: .whitespaces),
              l.lowercased().hasPrefix("https://") else { return nil }
        return URL(string: l)
    }

    /// The registrable domain: mail.notion.so → notion.so, mailhunter.megabank.com.tw → megabank.com.tw.
    static func siteDomain(_ domain: String) -> String {
        let labels = domain.split(separator: ".")
        guard labels.count > 2 else { return domain }
        let second = labels[labels.count - 2]
        let countryLevel = labels.last!.count == 2 && ["com", "co", "org", "net", "edu", "gov", "ac", "or", "ne", "go"].contains(second)
        return labels.suffix(countryLevel ? 3 : 2).joined(separator: ".")
    }

    static func sha256(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}


/// TXT records for a name from the system resolver (CNAMEs followed), or [] when it has none.
private func txtRecords(_ name: String, timeout: TimeInterval = 3) -> [String] {
    final class Box { var records: [String] = []; var done = false }
    let box = Box()
    var ref: DNSServiceRef?
    let flags = DNSServiceFlags(kDNSServiceFlagsReturnIntermediates)
    let err = DNSServiceQueryRecord(&ref, flags, 0, name, UInt16(kDNSServiceType_TXT), UInt16(kDNSServiceClass_IN),
                                    { _, flags, _, err, _, rrtype, _, length, rdata, _, context in
        guard let context else { return }
        let box = Unmanaged<Box>.fromOpaque(context).takeUnretainedValue()
        if err == kDNSServiceErr_NoError, rrtype == UInt16(kDNSServiceType_TXT), let rdata {
            // One record is a run of length-prefixed strings, read as one string.
            let bytes = UnsafeRawBufferPointer(start: rdata, count: Int(length))
            var text = "", i = 0
            while i < bytes.count {
                let n = Int(bytes[i]); i += 1
                text += String(decoding: bytes[i..<min(i + n, bytes.count)], as: UTF8.self); i += n
            }
            box.records.append(text)
            if flags & DNSServiceFlags(kDNSServiceFlagsMoreComing) == 0 { box.done = true }
        } else if err != kDNSServiceErr_NoError || rrtype != UInt16(kDNSServiceType_CNAME) {
            box.done = true
        }
    }, Unmanaged.passUnretained(box).toOpaque())
    guard err == kDNSServiceErr_NoError, let ref else { return [] }
    defer { DNSServiceRefDeallocate(ref) }
    var fd = pollfd(fd: DNSServiceRefSockFD(ref), events: Int16(POLLIN), revents: 0)
    let deadline = Date().addingTimeInterval(timeout)
    while !box.done {
        let ms = Int32(deadline.timeIntervalSinceNow * 1000)
        guard ms > 0, poll(&fd, 1, ms) > 0 else { break }
        DNSServiceProcessResult(ref)
    }
    return withExtendedLifetime(box) { box.records }
}
