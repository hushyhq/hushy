import Darwin
import Foundation
import MurmurCore

/// Where the eval-only remote backend may send dev-set text: loopback, or the founder's tailnet.
///
/// Accepted hosts, and nothing else:
/// - `localhost`, `127.0.0.0/8`, `::1`;
/// - an IPv4 literal in `100.64.0.0/10` (Tailscale's CGNAT range);
/// - `<machine>.<tailnet>` when `<tailnet>` (e.g. `tail1234.ts.net`) is configured
///   (`HUSHY_REMOTE_TAILNET`), `<machine>` is one DNS label, and the name resolves only to
///   `100.64.0.0/10`. The URL is then pinned to the resolved address, so a later lookup can't
///   point the requests anywhere else.
/// Bare single-label names, other `*.ts.net` names and every public name or address are refused.
public enum RemoteAddressPolicy {
    public typealias Resolver = @Sendable (String) -> [String]

    public static func validatedURL(_ raw: String, tailnet: String? = nil, resolve: Resolver = resolveIPv4) throws -> URL {
        let trimmed = raw.hasSuffix("/") ? String(raw.dropLast()) : raw
        guard var components = URLComponents(string: trimmed), let scheme = components.scheme,
              ["http", "https"].contains(scheme.lowercased()), components.user == nil, components.password == nil,
              let host = components.host?.lowercased(), !host.isEmpty,
              components.query == nil, components.fragment == nil
        else { throw refusal("not a plain http(s) URL") }
        guard components.path.isEmpty || components.path == "/" else { throw refusal("give the server root, without a path") }
        components.path = ""

        if host == "localhost" || host == "::1" || host == "[::1]" { return try url(components) }
        if let octets = ipv4(host) {
            guard isLoopback(octets) || isTailscale(octets) else { throw refusal("\(host) is not loopback or a Tailscale address") }
            guard isLoopback(octets) || scheme.lowercased() == "http" else { throw refusal(httpOnly) }
            return try url(components)
        }
        guard scheme.lowercased() == "http" else { throw refusal(httpOnly) }
        guard let tailnet = tailnet?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")), !tailnet.isEmpty,
              tailnet.hasSuffix(".ts.net"), host.hasSuffix("." + tailnet)
        else { throw refusal("\(host) is not loopback, a Tailscale IP, or a machine on the configured tailnet (HUSHY_REMOTE_TAILNET)") }
        let machine = host.dropLast(tailnet.count + 1)
        guard !machine.isEmpty, machine.count <= 63,
              machine.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }), machine.allSatisfy(\.isASCII)
        else { throw refusal("\(host) is not <machine>.\(tailnet)") }
        let addresses = resolve(host)
        guard let first = addresses.first,
              addresses.allSatisfy({ ipv4($0).map(isTailscale) ?? false })
        else { throw refusal("\(host) does not resolve only to Tailscale addresses") }
        components.host = first
        return try url(components)
    }

    static func ipv4(_ text: String) -> [Int]? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let octets = parts.compactMap { part -> Int? in
            guard !part.isEmpty, part.count <= 3, part.allSatisfy(\.isASCII), part.allSatisfy(\.isNumber) else { return nil }
            return Int(part).flatMap { (0...255).contains($0) ? $0 : nil }
        }
        return octets.count == 4 ? octets : nil
    }

    static func isLoopback(_ octets: [Int]) -> Bool { octets[0] == 127 }
    static func isTailscale(_ octets: [Int]) -> Bool { octets[0] == 100 && (64...127).contains(octets[1]) }

    /// IPv4 addresses for `host` (getaddrinfo, AF_INET).
    public static let resolveIPv4: Resolver = { host in
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { return [] }
        defer { freeaddrinfo(first) }
        var addresses: [String] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let info = cursor {
            if let sockaddr = info.pointee.ai_addr, info.pointee.ai_family == AF_INET {
                var address = sockaddr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                if inet_ntop(AF_INET, &address, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil {
                    addresses.append(String(cString: buffer))
                }
            }
            cursor = info.pointee.ai_next
        }
        return addresses
    }

    /// Tailscale already encrypts and authenticates the path end to end (WireGuard), and the URL is
    /// pinned to an IP, which would break TLS host verification: tailnet hosts are plain http. (If
    /// https is ever needed, send SNI and Host as the original name instead of pinning the URL.)
    static let httpOnly = "use http:// for Tailscale hosts (the tailnet encrypts; the URL is pinned to an IP)"

    private static func url(_ components: URLComponents) throws -> URL {
        guard let url = components.url else { throw refusal("not a URL") }
        return url
    }

    private static func refusal(_ reason: String) -> LanguageModelError {
        .unavailable("remote: refused URL: \(reason)")
    }
}
