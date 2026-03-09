import Foundation
import Darwin

final class LifecycleUITestSocketClient {
    private let path: String

    private static let readinessAttempts = 12
    private static let readinessDelay: TimeInterval = 0.1
    private static let mutatingAttempts = 4
    private static let mutatingRetryDelay: TimeInterval = 0.1
    private static let responseTimeout: TimeInterval = 4.0

    init(path: String) {
        self.path = path
    }

    func call(method: String, params: [String: Any] = [:]) -> [String: Any]? {
        if method != "system.ping" {
            _ = warmSocket()
        }

        let attempts = method == "system.ping" ? 1 : Self.mutatingAttempts
        var lastResponse: [String: Any]?
        for attempt in 0..<attempts {
            let response = callOnce(method: method, params: params)
            lastResponse = response
            if !shouldRetry(response: response, method: method) {
                return response
            }
            if attempt + 1 < attempts {
                Thread.sleep(forTimeInterval: Self.mutatingRetryDelay)
            }
        }
        return lastResponse
    }

    private func warmSocket() -> Bool {
        for _ in 0..<Self.readinessAttempts {
            let response = callOnce(method: "system.ping", params: [:])
            if let result = response["result"] as? [String: Any],
               result["pong"] as? Bool == true {
                return true
            }
            Thread.sleep(forTimeInterval: Self.readinessDelay)
        }
        return false
    }

    private func shouldRetry(response: [String: Any]?, method: String) -> Bool {
        guard method != "system.ping" else { return false }
        guard let response else { return true }
        return response["_transportFailure"] as? Bool == true
    }

    private func callOnce(method: String, params: [String: Any]) -> [String: Any] {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            return transportFailure(method: method, stage: "socket", detail: errnoDescription("socket"))
        }
        defer { close(fd) }

#if os(macOS)
        var noSigPipe: Int32 = 1
        _ = withUnsafePointer(to: &noSigPipe) { ptr in
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, ptr, socklen_t(MemoryLayout<Int32>.size))
        }
#endif

        setTimeout(fd: fd, option: SO_RCVTIMEO, timeout: Self.responseTimeout)
        setTimeout(fd: fd, option: SO_SNDTIMEO, timeout: 1.0)

        var addr = sockaddr_un()
        memset(&addr, 0, MemoryLayout<sockaddr_un>.size)
        addr.sun_family = sa_family_t(AF_UNIX)

        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= maxLen else {
            return transportFailure(method: method, stage: "path", detail: "socket path too long")
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { pointer in
            let raw = UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: CChar.self)
            memset(raw, 0, maxLen)
            for (index, byte) in bytes.enumerated() {
                raw[index] = byte
            }
        }

        let sunPathOffset = MemoryLayout.offset(of: \sockaddr_un.sun_path) ?? 0
        let addrLen = socklen_t(sunPathOffset + bytes.count)
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, addrLen)
            }
        }
        guard connected == 0 else {
            return transportFailure(method: method, stage: "connect", detail: errnoDescription("connect"))
        }

        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": method,
            "params": params,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else {
            return transportFailure(method: method, stage: "encode", detail: "invalid JSON payload")
        }

        var packet = Data()
        packet.append(data)
        packet.append(0x0A)
        guard sendAll(fd: fd, data: packet) else {
            return transportFailure(method: method, stage: "send", detail: errnoDescription("send"))
        }

        return readResponse(fd: fd, method: method)
    }

    private func setTimeout(fd: Int32, option: Int32, timeout: TimeInterval) {
        let wholeSeconds = Int(timeout)
        let microseconds = Int32((timeout - TimeInterval(wholeSeconds)) * 1_000_000)
        var value = timeval(tv_sec: wholeSeconds, tv_usec: microseconds)
        _ = withUnsafePointer(to: &value) { ptr in
            setsockopt(fd, SOL_SOCKET, option, ptr, socklen_t(MemoryLayout<timeval>.size))
        }
    }

    private func sendAll(fd: Int32, data: Data) -> Bool {
        var sent = 0
        return data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return false }
            while sent < rawBuffer.count {
                let wrote = send(fd, baseAddress.advanced(by: sent), rawBuffer.count - sent, 0)
                if wrote <= 0 { return false }
                sent += wrote
            }
            return true
        }
    }

    private func readResponse(fd: Int32, method: String) -> [String: Any] {
        var buffer = Data()
        let deadline = Date().addingTimeInterval(Self.responseTimeout)

        while Date() < deadline {
            var chunk = [UInt8](repeating: 0, count: 4096)
            let readCount = recv(fd, &chunk, chunk.count, 0)
            if readCount > 0 {
                buffer.append(chunk, count: Int(readCount))
                if buffer.contains(0x0A) {
                    break
                }
                continue
            }

            if readCount == 0 {
                if buffer.isEmpty {
                    return transportFailure(method: method, stage: "read", detail: "EOF before response")
                }
                break
            }

            if errno == EAGAIN || errno == EWOULDBLOCK {
                break
            }
            return transportFailure(method: method, stage: "read", detail: errnoDescription("recv"))
        }

        guard !buffer.isEmpty else {
            return transportFailure(method: method, stage: "read", detail: "timeout waiting for response")
        }

        guard let text = String(data: buffer, encoding: .utf8),
              let line = text.split(separator: "\n", maxSplits: 1).first else {
            return transportFailure(
                method: method,
                stage: "decode",
                detail: "non-UTF8 or empty response: \(preview(buffer))"
            )
        }

        guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
            return transportFailure(
                method: method,
                stage: "decode",
                detail: "invalid JSON line: \(String(line.prefix(200)))"
            )
        }

        return json
    }

    private func preview(_ data: Data) -> String {
        if let string = String(data: data.prefix(200), encoding: .utf8) {
            return string
        }
        return data.prefix(32).map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    private func errnoDescription(_ operation: String) -> String {
        let message = String(cString: strerror(errno))
        return "\(operation) errno=\(errno) \(message)"
    }

    private func transportFailure(method: String, stage: String, detail: String) -> [String: Any] {
        [
            "jsonrpc": "2.0",
            "id": 1,
            "error": [
                "code": -32098,
                "message": "Lifecycle UI test socket transport failure",
                "data": [
                    "method": method,
                    "path": path,
                    "stage": stage,
                    "detail": detail,
                ],
            ],
            "_transportFailure": true,
        ]
    }
}
