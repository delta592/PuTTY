import Darwin
import Foundation

/**
 * macOS 15 Local Network privacy helpers (TN3179).
 *
 * BSD `connect()` does not wait while the Local Network alert is up; the
 * first attempt is often denied with `EHOSTUNREACH`. Triggering the alert
 * at launch (UDP connect to link-local IPv6, no traffic) gives the user
 * time to Allow before they open a session. Ad-hoc rebuilds change the
 * code identity and can return the privilege to undetermined.
 *
 * WORKAROUND: TN3179 has no API to present the alert directly — see
 * .cursor/rules/agents.mdc
 */
public enum PuttyLocalNetwork {
    /// Best-effort: nudge the Local Network privacy alert without sending
    /// packets. Safe to call more than once; errors are ignored.
    public nonisolated static func triggerPrivacyAlert() {
        for address in selectedLinkLocalIPv6Addresses() {
            let fd = socket(AF_INET6, SOCK_DGRAM, 0)
            guard fd >= 0 else { return }
            defer { close(fd) }
            var addr = address
            _ = withUnsafePointer(to: &addr) { sa6 in
                sa6.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    connect(fd, sa, socklen_t(sa.pointee.sa_len))
                }
            }
        }
    }

    private nonisolated static func selectedLinkLocalIPv6Addresses() -> [sockaddr_in6] {
        let r1 = (0..<8).map { _ in UInt8.random(in: 0...255) }
        let r2 = (0..<8).map { _ in UInt8.random(in: 0...255) }
        return ipv6AddressesOfBroadcastCapableInterfaces()
            .filter(isIPv6AddressLinkLocal)
            .map { addr in
                var a = addr
                a.sin6_port = UInt16(9).bigEndian
                return a
            }
            .flatMap { addr in
                [
                    setIPv6LinkLocalAddressHostPart(of: addr, to: r1),
                    setIPv6LinkLocalAddressHostPart(of: addr, to: r2),
                ]
            }
    }

    private nonisolated static func ipv6AddressesOfBroadcastCapableInterfaces() -> [sockaddr_in6] {
        var result: [sockaddr_in6] = []
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr else { return [] }
        defer { freeifaddrs(first) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = cursor {
            defer { cursor = ifa.pointee.ifa_next }
            let flags = Int32(ifa.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0,
                  (flags & IFF_BROADCAST) != 0,
                  let sa = ifa.pointee.ifa_addr,
                  sa.pointee.sa_family == sa_family_t(AF_INET6)
            else { continue }
            sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { sin6 in
                result.append(sin6.pointee)
            }
        }
        return result
    }

    private nonisolated static func isIPv6AddressLinkLocal(_ addr: sockaddr_in6) -> Bool {
        var addr = addr
        return withUnsafeBytes(of: &addr.sin6_addr) { buf in
            guard buf.count >= 2 else { return false }
            return buf[0] == 0xfe && (buf[1] & 0xc0) == 0x80
        }
    }

    private nonisolated static func setIPv6LinkLocalAddressHostPart(
        of addr: sockaddr_in6, to host: [UInt8]
    ) -> sockaddr_in6 {
        precondition(host.count == 8)
        var result = addr
        withUnsafeMutableBytes(of: &result.sin6_addr) { buf in
            guard buf.count >= 16 else { return }
            for i in 0..<8 {
                buf[8 + i] = host[i]
            }
        }
        return result
    }
}
