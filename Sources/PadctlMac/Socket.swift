import Darwin
import Foundation

public struct AlreadyRunning: Error, CustomStringConvertible {
    public let path: String
    public var description: String { "another padctl is already running (\(path))" }
}

/// One JSON object per line in each direction, one request per connection.
public enum ControlSocket {
    public static var path: String {
        if let p = ProcessInfo.processInfo.environment["PADCTL_SOCKET"] { return p }
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/padctl")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("padctl.sock").path
    }

    static func address(_ path: String) -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8.prefix(103))
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = b }
            raw[bytes.count] = 0
        }
        return addr
    }

    /// Client: send a request, wait for one reply line. Returns nil if the app isn't running or times out.
    public static func request(_ obj: [String: Any], timeout: Double = 0.2) -> [String: Any]? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - Double(Int(timeout))) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = address(path)
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard ok == 0, var data = try? JSONSerialization.data(withJSONObject: obj) else { return nil }
        data.append(0x0A)
        let sent = data.withUnsafeBytes { write(fd, $0.baseAddress, data.count) }
        guard sent == data.count else { return nil }
        var reply = Data()
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            reply.append(contentsOf: buf[0..<n])
            if reply.last == 0x0A { break }
        }
        return (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any]
    }
}

/// Server side, inside the app. Handler runs on the main queue and returns the reply.
public final class ControlServer {
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    public var handler: (([String: Any]) -> [String: Any])?

    public init() {}

    public func start() throws {
        let path = ControlSocket.path
        // never steal a live instance's socket: hooks and the CLI would talk to the wrong process
        if ControlSocket.request(["cmd": "status"], timeout: 0.5) != nil { throw AlreadyRunning(path: path) }
        unlink(path)
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw NSError(domain: "socket", code: Int(errno)) }
        var addr = ControlSocket.address(path)
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard r == 0 else { throw NSError(domain: "socket bind \(path)", code: Int(errno)) }
        chmod(path, 0o600)
        listen(fd, 128)   // several agents can fire hooks at once
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global())
        src.setEventHandler { [weak self] in self?.accept() }
        src.resume()
        source = src
    }

    private func accept() {
        let c = Darwin.accept(fd, nil, nil)
        guard c >= 0 else { return }
        // hooks call with a 0.2 s timeout and may hang up before the reply: writing then must fail, not kill padctl
        var one: Int32 = 1
        setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        DispatchQueue.global().async { [weak self] in
            defer { close(c) }
            var tv = timeval(tv_sec: 2, tv_usec: 0)
            setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            var data = Data()
            var buf = [UInt8](repeating: 0, count: 65536)
            while data.last != 0x0A {
                let n = read(c, &buf, buf.count)
                if n <= 0 { break }
                data.append(contentsOf: buf[0..<n])
                if data.count > 4_000_000 { return }
            }
            guard let req = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
            var reply: [String: Any] = ["ok": false]
            DispatchQueue.main.sync { reply = self?.handler?(req) ?? ["ok": false, "error": "no handler"] }
            guard var out = try? JSONSerialization.data(withJSONObject: reply) else { return }
            out.append(0x0A)
            _ = out.withUnsafeBytes { write(c, $0.baseAddress, out.count) }
        }
    }

    public func stop() {
        source?.cancel()
        if fd >= 0 { close(fd) }
        unlink(ControlSocket.path)
    }
}
