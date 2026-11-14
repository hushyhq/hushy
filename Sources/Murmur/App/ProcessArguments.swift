import Darwin
import Foundation

/// The launch arguments of another process of this user, as the system holds them
/// (`KERN_PROCARGS2`). Used only to tell a pill preview from a real Hushy (`SingleInstance`).
enum ProcessArguments {
    /// `nil` when the process is gone or its arguments cannot be read.
    static func of(pid: pid_t) -> [String]? {
        var name: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&name, UInt32(name.count), nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&name, UInt32(name.count), &buffer, &size, nil, 0) == 0 else { return nil }
        return parse(Array(buffer.prefix(size)))
    }

    /// The buffer is: the argument count (a 32-bit integer), the executable's path, some zero
    /// padding, then that many zero-terminated arguments (the environment follows and is not read).
    static func parse(_ bytes: [UInt8]) -> [String]? {
        let header = MemoryLayout<Int32>.size
        guard bytes.count > header else { return nil }
        let count = bytes.prefix(header).enumerated().reduce(Int32(0)) { $0 | Int32($1.element) << Int32(8 * $1.offset) }
        guard count > 0, count < 4_096 else { return nil }
        var index = header
        // Past the executable's path and the padding after it.
        while index < bytes.count, bytes[index] != 0 { index += 1 }
        while index < bytes.count, bytes[index] == 0 { index += 1 }
        var arguments: [String] = []
        while arguments.count < Int(count), index < bytes.count {
            let start = index
            while index < bytes.count, bytes[index] != 0 { index += 1 }
            arguments.append(String(decoding: bytes[start..<index], as: UTF8.self))
            index += 1
        }
        return arguments.count == Int(count) ? arguments : nil
    }
}
