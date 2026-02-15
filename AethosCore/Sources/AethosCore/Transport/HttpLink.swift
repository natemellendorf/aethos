import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// HttpFrameServer uses a small POSIX socket server for reliability.
// Network.framework is intentionally not used here.

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// HTTP-based Link for transporting encoded Frames between remote peers.
///
/// Endpoints:
/// - Preferred: POST /frame (body = Frame.encode() bytes)
/// - Preferred: GET /frame (200 returns one frame, 204 when none)
/// - Back-compat: POST/GET /frames
///
/// Identity headers are best-effort hints only (not trusted):
/// - Client may send `X-Aethos-From-WayfarerId` and `X-Aethos-To-WayfarerId` headers.
/// - Server may echo `X-Aethos-From-WayfarerId`.
public final class HttpLink: Link {
    public enum HttpLinkError: Swift.Error, Equatable {
        case invalidBaseURL
        case badResponseStatus(Int)
        case missingResponseBody
        case invalidFrameBytes
        case network(String)
    }

    public let baseURL: URL
    public let localWayfarerIdHex: String?
    public let expectedRemoteWayfarerIdHex: String?

    private let session: URLSession

    public init(
        baseURL: URL,
        localWayfarerIdHex: String? = nil,
        expectedRemoteWayfarerIdHex: String? = nil,
        session: URLSession = .shared
    ) throws {
        guard baseURL.scheme == "http" || baseURL.scheme == "https" else {
            throw HttpLinkError.invalidBaseURL
        }
        self.baseURL = baseURL
        self.localWayfarerIdHex = localWayfarerIdHex
        self.expectedRemoteWayfarerIdHex = expectedRemoteWayfarerIdHex
        self.session = session
    }

    private func url(for endpoint: String) -> URL {
        baseURL.appendingPathComponent(endpoint, isDirectory: false)
    }

    private func requestWithCompat(_ req: URLRequest, compatEndpoint: String?) throws -> (Data?, HTTPURLResponse) {
        let (data, resp) = try request(req)
        if resp.statusCode == 404, let compatEndpoint, let originalURL = req.url {
            var retry = req
            let base = originalURL.deletingLastPathComponent()
            retry.url = base.appendingPathComponent(compatEndpoint, isDirectory: false)
            return try request(retry)
        }
        return (data, resp)
    }

    public func send(_ frame: Frame) throws {
        let body = frame.encode()
        var req = URLRequest(url: url(for: "frame"))
        req.httpMethod = "POST"
        req.httpBody = body
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        req.setValue("\(body.count)", forHTTPHeaderField: "Content-Length")
        if let local = localWayfarerIdHex {
            req.setValue(local, forHTTPHeaderField: "X-Aethos-From-WayfarerId")
        }
        if let expected = expectedRemoteWayfarerIdHex {
            req.setValue(expected, forHTTPHeaderField: "X-Aethos-To-WayfarerId")
        }

        let (_, response) = try requestWithCompat(req, compatEndpoint: "frames")
        let status = response.statusCode
        guard (200..<300).contains(status) else {
            throw HttpLinkError.badResponseStatus(status)
        }
        _ = response.value(forHTTPHeaderField: "X-Aethos-From-WayfarerId")
    }

    public func receive() throws -> Frame? {
        let (frame, _) = try receiveWithRemoteInfo()
        return frame
    }

    /// Like `receive()` but returns the echoed remote wayfarer id (if present).
    public func receiveWithRemoteInfo() throws -> (Frame?, String?) {
        var req = URLRequest(url: url(for: "frame"))
        req.httpMethod = "GET"
        if let local = localWayfarerIdHex {
            req.setValue(local, forHTTPHeaderField: "X-Aethos-From-WayfarerId")
        }
        if let expected = expectedRemoteWayfarerIdHex {
            req.setValue(expected, forHTTPHeaderField: "X-Aethos-To-WayfarerId")
        }

        let (data, response) = try requestWithCompat(req, compatEndpoint: "frames")
        let status = response.statusCode
        if status == 204 {
            let remote = response.value(forHTTPHeaderField: "X-Aethos-From-WayfarerId")
            return (nil, remote)
        }
        guard status == 200 else {
            throw HttpLinkError.badResponseStatus(status)
        }

        guard let data else {
            throw HttpLinkError.missingResponseBody
        }
        guard let frame = try? Frame.decode(data) else {
            throw HttpLinkError.invalidFrameBytes
        }
        let remote = response.value(forHTTPHeaderField: "X-Aethos-From-WayfarerId")
        return (frame, remote)
    }

    private func request(_ req: URLRequest) throws -> (Data?, HTTPURLResponse) {
        let sema = DispatchSemaphore(value: 0)

        final class ResultBox: @unchecked Sendable {
            var data: Data?
            var response: HTTPURLResponse?
            var error: Error?
        }
        let box = ResultBox()

        session.dataTask(with: req) { data, resp, err in
            box.data = data
            box.response = resp as? HTTPURLResponse
            box.error = err
            sema.signal()
        }.resume()

        _ = sema.wait(timeout: .now() + 30)
        if let err = box.error {
            throw HttpLinkError.network("\(err)")
        }
        guard let resp = box.response else {
            throw HttpLinkError.network("missing response")
        }
        return (box.data, resp)
    }
}

// MARK: - Minimal HTTP Frame Server (POSIX)

/// Minimal HTTP server used by `aethos serve`.
///
/// Endpoints:
/// - POST /frame: validates `Frame.decode`, stores raw bytes into inbox directory
/// - GET /frame: returns one encoded frame from outbox directory, 204 if none
/// - Back-compat: POST/GET /frames
/// - GET /inventory: returns one Inventory frame from outbox directory, 204 if none
/// - POST /inventory-request: accepts either InventoryRequest frame bytes or canonical bytes
///
/// Notes:
/// - This server always closes the connection after a response.
/// - Frame integrity/authentication are handled at higher layers; this transport only moves bytes.
/// - Identity headers (if present) are best-effort hints and are not enforced.
public final class HttpFrameServer: @unchecked Sendable {
    public enum ServerError: Swift.Error, Equatable {
        case alreadyStarted
        case notStarted
        case bindFailed(String)
        case io(String)
    }

    public let bindHost: String
    public let port: UInt16
    public let inboxDir: URL
    public let outboxDir: URL
    public let archiveDir: URL
    public let localWayfarerIdHex: String?

    private let fileManager: FileManager
    // IMPORTANT: accept() blocks; do not run request handling on same serial queue.
    private let acceptQueue = DispatchQueue(label: "aethos.http.server.accept")
    private let clientQueue = DispatchQueue(label: "aethos.http.server.client", attributes: .concurrent)
    private var listenFD: Int32 = -1
    private var acceptWork: DispatchWorkItem?

    public init(
        bindHost: String,
        port: UInt16,
        inboxDir: URL,
        outboxDir: URL,
        archiveDir: URL,
        localWayfarerIdHex: String? = nil,
        fileManager: FileManager = .default
    ) throws {
        self.bindHost = bindHost
        self.port = port
        self.inboxDir = inboxDir
        self.outboxDir = outboxDir
        self.archiveDir = archiveDir
        self.localWayfarerIdHex = localWayfarerIdHex
        self.fileManager = fileManager

        do {
            try fileManager.createDirectory(at: inboxDir, withIntermediateDirectories: true, attributes: nil)
            try fileManager.createDirectory(at: outboxDir, withIntermediateDirectories: true, attributes: nil)
            try fileManager.createDirectory(at: archiveDir, withIntermediateDirectories: true, attributes: nil)
        } catch {
            throw ServerError.io("\(error)")
        }
    }

    public func start() throws {
        guard listenFD < 0 else { throw ServerError.alreadyStarted }

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ServerError.bindFailed("socket") }

        var yes: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian

        if bindHost == "0.0.0.0" {
            addr.sin_addr = in_addr(s_addr: INADDR_ANY.bigEndian)
        } else {
            var a = in_addr()
            let rc = bindHost.withCString { cs in
                inet_pton(AF_INET, cs, &a)
            }
            guard rc == 1 else {
                _ = close(fd)
                throw ServerError.bindFailed("invalid host")
            }
            addr.sin_addr = a
        }

        var sa = sockaddr()
        memcpy(&sa, &addr, MemoryLayout<sockaddr_in>.size)
        let brc = withUnsafePointer(to: &sa) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saptr in
                bind(fd, saptr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard brc == 0 else {
            _ = close(fd)
            throw ServerError.bindFailed("bind")
        }

        guard listen(fd, 128) == 0 else {
            _ = close(fd)
            throw ServerError.bindFailed("listen")
        }

        listenFD = fd

        let work = DispatchWorkItem { [weak self] in
            self?.acceptLoop()
        }
        acceptWork = work
        acceptQueue.async(execute: work)
    }

    public func stop() throws {
        guard listenFD >= 0 else { throw ServerError.notStarted }
        let fd = listenFD
        listenFD = -1
        acceptWork?.cancel()
        acceptWork = nil
        _ = shutdown(fd, SHUT_RDWR)
        _ = close(fd)
    }

    private func acceptLoop() {
        while listenFD >= 0 {
            var addr = sockaddr()
            var len: socklen_t = socklen_t(MemoryLayout<sockaddr>.size)
            let cfd = withUnsafeMutablePointer(to: &addr) { aptr in
                accept(listenFD, aptr, &len)
            }
            if cfd < 0 {
                // Likely interrupted during shutdown.
                continue
            }
            clientQueue.async { [weak self] in
                self?.handleClient(fd: cfd)
            }
        }
    }

    private func handleClient(fd: Int32) {
        defer { _ = close(fd) }

        func debug(_ msg: String) {
            guard ProcessInfo.processInfo.environment["AETHOS_HTTP_DEBUG"] == "1" else { return }
            fputs("[HttpFrameServer] \(msg)\n", stderr)
        }

        // Read header.
        var buf = Data()
        buf.reserveCapacity(8 * 1024)
        guard let (headerBytes, remaining) = readUntil(fd: fd, delimiter: Data("\r\n\r\n".utf8), maxBytes: 128 * 1024) else {
            return
        }
        buf = remaining

        guard let headerStr = String(data: headerBytes, encoding: .utf8) else {
            _ = sendResponse(fd: fd, status: 400, headers: [:], body: Data())
            return
        }

        // Normalize CRLF to LF. (In Swift, "\r\n" can form a single Character.)
        let normalizedHeader = headerStr.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalizedHeader.split(separator: "\n", omittingEmptySubsequences: false)
        guard let requestLine = lines.first.map({ String($0) })?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            _ = sendResponse(fd: fd, status: 400, headers: [:], body: Data())
            return
        }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else {
            _ = sendResponse(fd: fd, status: 400, headers: [:], body: Data())
            return
        }
        let method = String(parts[0])
        let path = String(parts[1])

        debug("requestLine=\(requestLine)")

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            let trimmed = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            if let idx = trimmed.firstIndex(of: ":") {
                let key = trimmed[..<idx].trimmingCharacters(in: .whitespacesAndNewlines)
                let value = trimmed[trimmed.index(after: idx)...].trimmingCharacters(in: .whitespacesAndNewlines)
                headers[key.lowercased()] = value
            }
        }

        if ProcessInfo.processInfo.environment["AETHOS_HTTP_DEBUG"] == "1" {
            debug("headers=\(headers)")
            debug("initialBodyBytes=\(buf.count)")
        }

        if method == "GET" && (path == "/frame" || path == "/frames") {
            handleGetFrames(fd: fd, onlyType: nil)
            return
        }

        if method == "GET" && path == "/inventory" {
            handleGetFrames(fd: fd, onlyType: CargoCodec.FrameType.inventory)
            return
        }

        if method == "POST" && (path == "/frame" || path == "/frames") {
            // Some HTTP clients (including some URLSession configurations) may use
            // `Expect: 100-continue` and will not send the body until we acknowledge.
            if let expect = headers["expect"], expect.lowercased().contains("100-continue") {
                _ = sendAll(fd: fd, data: Data("HTTP/1.1 100 Continue\r\n\r\n".utf8))
            }

            let body: Data
            if let te = headers["transfer-encoding"], te.lowercased().contains("chunked") {
                guard let b = readChunkedBody(fd: fd, already: buf, maxBytes: 20 * 1024 * 1024) else {
                    _ = sendResponse(fd: fd, status: 400, headers: defaultHeaders(), body: Data())
                    return
                }
                body = b
            } else if let lenStr = headers["content-length"], let len = Int(lenStr), len >= 0 {
                guard let b = readFixedBody(fd: fd, already: buf, length: len, maxBytes: 20 * 1024 * 1024) else {
                    _ = sendResponse(fd: fd, status: 400, headers: defaultHeaders(), body: Data())
                    return
                }
                body = b
            } else {
                // Some clients omit Content-Length and are not chunked. Read until close.
                guard let b = readToEOF(fd: fd, already: buf, maxBytes: 20 * 1024 * 1024) else {
                    _ = sendResponse(fd: fd, status: 400, headers: defaultHeaders(), body: Data())
                    return
                }
                body = b
            }

            handlePostFrames(fd: fd, body: body)
            return
        }

        if method == "POST" && path == "/inventory-request" {
            if let expect = headers["expect"], expect.lowercased().contains("100-continue") {
                _ = sendAll(fd: fd, data: Data("HTTP/1.1 100 Continue\r\n\r\n".utf8))
            }

            let body: Data
            if let te = headers["transfer-encoding"], te.lowercased().contains("chunked") {
                guard let b = readChunkedBody(fd: fd, already: buf, maxBytes: 20 * 1024 * 1024) else {
                    _ = sendResponse(fd: fd, status: 400, headers: defaultHeaders(), body: Data())
                    return
                }
                body = b
            } else if let lenStr = headers["content-length"], let len = Int(lenStr), len >= 0 {
                guard let b = readFixedBody(fd: fd, already: buf, length: len, maxBytes: 20 * 1024 * 1024) else {
                    _ = sendResponse(fd: fd, status: 400, headers: defaultHeaders(), body: Data())
                    return
                }
                body = b
            } else {
                guard let b = readToEOF(fd: fd, already: buf, maxBytes: 20 * 1024 * 1024) else {
                    _ = sendResponse(fd: fd, status: 400, headers: defaultHeaders(), body: Data())
                    return
                }
                body = b
            }

            handlePostInventoryRequest(fd: fd, body: body)
            return
        }

        _ = sendResponse(fd: fd, status: 404, headers: defaultHeaders(), body: Data())
    }

    private func readToEOF(fd: Int32, already: Data, maxBytes: Int) -> Data? {
        var out = Data(already)
        while out.count <= maxBytes {
            var tmp = [UInt8](repeating: 0, count: 16 * 1024)
            let rc = recv(fd, &tmp, tmp.count, 0)
            if rc == 0 {
                return out
            }
            if rc < 0 {
                return nil
            }
            out.append(contentsOf: tmp.prefix(rc))
        }
        return nil
    }

    private func handlePostFrames(fd: Int32, body: Data) {
        guard (try? Frame.decode(body)) != nil else {
            _ = sendResponse(fd: fd, status: 400, headers: defaultHeaders(), body: Data())
            return
        }

        let name = uniqueName(prefix: "in-", ext: "bin")
        let url = inboxDir.appendingPathComponent(name, isDirectory: false)
        do {
            try body.write(to: url, options: [.atomic])
        } catch {
            _ = sendResponse(fd: fd, status: 500, headers: defaultHeaders(), body: Data())
            return
        }

        _ = sendResponse(fd: fd, status: 201, headers: defaultHeaders(), body: Data())
    }

    private func handlePostInventoryRequest(fd: Int32, body: Data) {
        // Accept either:
        // - an encoded Frame of type inventoryRequest
        // - canonical InventoryRequestV1 bytes (wrapped into a Frame for storage)
        let frameBytes: Data
        if let f = try? Frame.decode(body) {
            guard CargoCodec.FrameType(rawValue: f.type) == .inventoryRequest else {
                _ = sendResponse(fd: fd, status: 400, headers: defaultHeaders(), body: Data())
                return
            }
            frameBytes = body
        } else {
            guard (try? CanonicalEncoderV1.decodeInventoryRequest(canonical: body)) != nil else {
                _ = sendResponse(fd: fd, status: 400, headers: defaultHeaders(), body: Data())
                return
            }
            let id = AethosIDs.sha256(body)
            let f = Frame(type: CargoCodec.FrameType.inventoryRequest.rawValue, id: id, partIndex: 0, partCount: 1, payload: body)
            frameBytes = f.encode()
        }

        let name = uniqueName(prefix: "in-", ext: "bin")
        let url = inboxDir.appendingPathComponent(name, isDirectory: false)
        do {
            try frameBytes.write(to: url, options: [.atomic])
        } catch {
            _ = sendResponse(fd: fd, status: 500, headers: defaultHeaders(), body: Data())
            return
        }

        _ = sendResponse(fd: fd, status: 201, headers: defaultHeaders(), body: Data())
    }

    private func handleGetFrames(fd: Int32, onlyType: CargoCodec.FrameType?) {
        while true {
            guard let next = oldestOutboxEntry(onlyType: onlyType) else {
                _ = sendResponse(fd: fd, status: 204, headers: defaultHeaders(), body: Data())
                return
            }

            let bytes: Data
            do {
                bytes = try Data(contentsOf: next)
            } catch {
                _ = try? archiveBad(next, reason: "read")
                continue
            }

            guard let frame = try? Frame.decode(bytes) else {
                _ = try? archiveBad(next, reason: "decode")
                continue
            }

            if let onlyType, CargoCodec.FrameType(rawValue: frame.type) != onlyType {
                // Selection should already filter by type; do not consume non-matching frame.
                continue
            }

            do {
                try archiveGood(next)
            } catch {
                _ = sendResponse(fd: fd, status: 500, headers: defaultHeaders(), body: Data())
                return
            }

            var h = defaultHeaders()
            h["Content-Type"] = "application/octet-stream"
            _ = sendResponse(fd: fd, status: 200, headers: h, body: bytes)
            return
        }
    }

    private func defaultHeaders() -> [String: String] {
        var h: [String: String] = [:]
        if let localWayfarerIdHex {
            h["X-Aethos-From-WayfarerId"] = localWayfarerIdHex
        }
        return h
    }

    private func sendResponse(fd: Int32, status: Int, headers: [String: String], body: Data) -> Bool {
        var hdrs = headers
        hdrs["Content-Length"] = "\(body.count)"
        hdrs["Connection"] = "close"
        hdrs["Server"] = "aethos"
        if hdrs["Content-Type"] == nil {
            hdrs["Content-Type"] = body.isEmpty ? "text/plain" : "application/octet-stream"
        }

        var lines: [String] = []
        lines.append("HTTP/1.1 \(status) \(reason(status))")
        for (k, v) in hdrs {
            lines.append("\(k): \(v)")
        }
        lines.append("")
        lines.append("")
        var out = Data(lines.joined(separator: "\r\n").utf8)
        out.append(body)
        return sendAll(fd: fd, data: out)
    }

    private func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 201: return "Created"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 411: return "Length Required"
        case 500: return "Internal Server Error"
        default: return "Status"
        }
    }

    private func sendAll(fd: Int32, data: Data) -> Bool {
        return data.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let rc = send(fd, raw.baseAddress!.advanced(by: sent), raw.count - sent, 0)
                if rc <= 0 { return false }
                sent += rc
            }
            return true
        }
    }

    private func readUntil(fd: Int32, delimiter: Data, maxBytes: Int) -> (Data, Data)? {
        var buffer = Data()
        buffer.reserveCapacity(8 * 1024)

        while buffer.count <= maxBytes {
            if let r = buffer.range(of: delimiter) {
                let header = Data(buffer[..<r.lowerBound])
                let rest = Data(buffer[r.upperBound...])
                return (header, rest)
            }

            var tmp = [UInt8](repeating: 0, count: 16 * 1024)
            let rc = recv(fd, &tmp, tmp.count, 0)
            if rc <= 0 {
                return nil
            }
            buffer.append(contentsOf: tmp.prefix(rc))
        }

        return nil
    }

    private func readFixedBody(fd: Int32, already: Data, length: Int, maxBytes: Int) -> Data? {
        guard length >= 0, length <= maxBytes else { return nil }
        var out = Data()
        out.reserveCapacity(length)
        if !already.isEmpty {
            out.append(already.prefix(length))
        }
        while out.count < length {
            var tmp = [UInt8](repeating: 0, count: min(16 * 1024, length - out.count))
            let rc = recv(fd, &tmp, tmp.count, 0)
            if rc <= 0 { return nil }
            out.append(contentsOf: tmp.prefix(rc))
        }
        if out.count > length {
            out = Data(out.prefix(length))
        }
        return out
    }

    private func readChunkedBody(fd: Int32, already: Data, maxBytes: Int) -> Data? {
        var buf = already
        var out = Data()

        func ensure(_ n: Int) -> Bool {
            while buf.count < n {
                var tmp = [UInt8](repeating: 0, count: 16 * 1024)
                let rc = recv(fd, &tmp, tmp.count, 0)
                if rc <= 0 { return false }
                buf.append(contentsOf: tmp.prefix(rc))
            }
            return true
        }

        while true {
            // size line
            while true {
                if let r = buf.range(of: Data("\r\n".utf8)) {
                    let line = Data(buf[..<r.lowerBound])
                    buf = Data(buf[r.upperBound...])
                    guard let lineStr = String(data: line, encoding: .utf8) else { return nil }
                    let token = lineStr.split(separator: ";", maxSplits: 1).first ?? ""
                    guard let size = Int(token.trimmingCharacters(in: .whitespacesAndNewlines), radix: 16) else { return nil }
                    if size == 0 {
                        // consume final CRLF after 0 chunk (trailers ignored)
                        return out
                    }
                    guard size >= 0, out.count + size <= maxBytes else { return nil }
                    guard ensure(size + 2) else { return nil }
                    out.append(buf.prefix(size))
                    buf = Data(buf.dropFirst(size))
                    // consume CRLF
                    if !buf.starts(with: Data("\r\n".utf8)) { return nil }
                    buf = Data(buf.dropFirst(2))
                    break
                }
                guard ensure(buf.count + 1) else { return nil }
            }
        }
    }

    private func oldestOutboxEntry(onlyType: CargoCodec.FrameType?) -> URL? {
        let entries = (try? fileManager.contentsOfDirectory(
            at: outboxDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let candidates = entries.filter { !$0.lastPathComponent.hasPrefix(".") }
        guard !candidates.isEmpty else { return nil }

        let sorted = candidates.sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard let onlyType else {
            return sorted.first
        }

        for url in sorted {
            guard let bytes = try? Data(contentsOf: url),
                  let frame = try? Frame.decode(bytes)
            else {
                continue
            }
            if CargoCodec.FrameType(rawValue: frame.type) == onlyType {
                return url
            }
        }
        return nil
    }

    private func archiveGood(_ url: URL) throws {
        let dest = archiveDir.appendingPathComponent(url.lastPathComponent, isDirectory: false)
        try moveReplacing(source: url, dest: dest)
    }

    private func archiveBad(_ url: URL, reason: String) throws {
        let dest = archiveDir.appendingPathComponent(url.lastPathComponent + "." + reason + ".bad", isDirectory: false)
        try moveReplacing(source: url, dest: dest)
    }

    private func moveReplacing(source: URL, dest: URL) throws {
        if fileManager.fileExists(atPath: dest.path) {
            try fileManager.removeItem(at: dest)
        }
        try fileManager.moveItem(at: source, to: dest)
    }

    private func uniqueName(prefix: String, ext: String) -> String {
        let now = Date()
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(secondsFromGMT: 0)
        fmt.dateFormat = "yyyyMMddHHmmssSSS"
        let ts = fmt.string(from: now)
        let rand = UInt64.random(in: 0...UInt64.max)
        return "\(prefix)\(ts)-\(String(rand, radix: 16)).\(ext)"
    }
}
