import Foundation

/// Lets `mailsift mcp` search through the running app, whose model and vectors are already in memory, instead of
/// loading its own copy for every agent turn. One JSON line in, one JSON line out, over a Unix socket.
public enum SearchService {
    struct Request: Codable {
        var query: String
        var filter: SearchFilter
        var limit: Int
    }

    /// ~/Library/Application Support/MailSift/search.sock
    static var socketPath: String {
        MailLibrary.defaultDatabaseURL().deletingLastPathComponent().appendingPathComponent("search.sock").path
    }

    /// App side: answers searches while the library can search by meaning; otherwise closes the connection so
    /// the caller falls back to its own model.
    public static func serve(_ library: MailLibrary) {
        let path = socketPath
        unlink(path)
        let server = socket(AF_UNIX, SOCK_STREAM, 0)
        guard server >= 0, var addr = address(path) else { return }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(server, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(path, 0o600) == 0, listen(server, 8) == 0 else { close(server); return }
        Thread.detachNewThread {
            while true {
                let client = accept(server, nil, nil)
                guard client >= 0 else { continue }
                var timeout = timeval(tv_sec: 5, tv_usec: 0)
                setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                Task {
                    defer { close(client) }
                    guard library.canSearchByMeaning, let line = readLine(client),
                          let request = try? JSONDecoder().decode(Request.self, from: line),
                          let hits = try? await library.search(request.query, filter: request.filter, limit: request.limit),
                          var data = try? JSONEncoder().encode(hits) else { return }
                    data.append(0x0A)
                    data.withUnsafeBytes { _ = write(client, $0.baseAddress, $0.count) }
                }
            }
        }
    }

    /// Caller side: nil when the app is not running or cannot search by meaning yet.
    public static func search(_ query: String, filter: SearchFilter, limit: Int) -> [SearchHit]? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        guard var addr = address(socketPath) else { return nil }
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0, var data = try? JSONEncoder().encode(Request(query: query, filter: filter, limit: limit))
        else { return nil }
        data.append(0x0A)
        guard data.withUnsafeBytes({ write(fd, $0.baseAddress, $0.count) }) == data.count,
              let line = readLine(fd) else { return nil }
        return try? JSONDecoder().decode([SearchHit].self, from: line)
    }

    private static func address(_ path: String) -> sockaddr_un? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes) }
        return addr
    }

    /// Reads up to the first newline; nil if the peer closes first.
    private static func readLine(_ fd: Int32) -> Data? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &buffer, buffer.count)
            guard n > 0 else { return nil }
            if let end = buffer[..<n].firstIndex(of: 0x0A) {
                data.append(contentsOf: buffer[..<end])
                return data
            }
            data.append(contentsOf: buffer[..<n])
        }
    }
}
