import Foundation

/// A calendar day as year-month-day numbers (Gregorian). Encodes as "YYYY-MM-DD".
public struct MetricsDay: Codable, Sendable, Equatable, Hashable, Comparable {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(year: Int, month: Int, day: Int) throws {
        guard (2000...9999).contains(year), (1...12).contains(month), (1...Self.daysIn(month: month, year: year)).contains(day) else {
            throw MetricsValidationError.invalidDay
        }
        self.year = year
        self.month = month
        self.day = day
    }

    /// Parses exactly `YYYY-MM-DD` (ASCII digits only) and rejects impossible dates.
    public init?(isoString: String) {
        let bytes = Array(isoString.utf8)
        guard bytes.count == 10, bytes[4] == 0x2D, bytes[7] == 0x2D else { return nil }
        func number(_ range: Range<Int>) -> Int? {
            var value = 0
            for byte in bytes[range] {
                guard (0x30...0x39).contains(byte) else { return nil }
                value = value * 10 + Int(byte - 0x30)
            }
            return value
        }
        guard let year = number(0..<4), let month = number(5..<7), let day = number(8..<10),
              let parsed = try? MetricsDay(year: year, month: month, day: day) else { return nil }
        self = parsed
    }

    public var isoString: String { String(format: "%04d-%02d-%02d", year, month, day) }

    public static func < (lhs: MetricsDay, rhs: MetricsDay) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    private static func daysIn(month: Int, year: Int) -> Int {
        switch month {
        case 2: (year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)) ? 29 : 28
        case 4, 6, 9, 11: 30
        default: 31
        }
    }

    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let parsed = MetricsDay(isoString: text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid metrics day"))
        }
        self = parsed
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(isoString)
    }
}

/// The Mac, in bands too coarse to single out a machine: chip generation class, memory band and
/// the macOS major version. No model identifier, serial number, build string or locale.
public struct MetricsEnvironment: Codable, Sendable, Equatable {
    public enum ChipClass: String, MetricsKey { case appleM1, appleM2, appleM3, appleM4OrLater, intel, unknown }

    /// Upper bound of the installed memory, in GiB.
    public enum MemoryBand: String, MetricsKey { case upTo8GB, upTo16GB, upTo32GB, upTo64GB, over64GB, unknown }

    public static let supportedMacOSMajors = 10...99

    public let chipClass: ChipClass
    public let memoryBand: MemoryBand
    public let macOSMajor: Int

    public init(chipClass: ChipClass, memoryBand: MemoryBand, macOSMajor: Int) throws {
        guard Self.supportedMacOSMajors.contains(macOSMajor) else { throw MetricsValidationError.invalidEnvironment }
        self.chipClass = chipClass
        self.memoryBand = memoryBand
        self.macOSMajor = macOSMajor
    }

    /// Bands raw machine readings. The brand string and byte count are read by the caller and
    /// discarded; only the bands are kept.
    public static func classify(chipBrand: String, physicalMemoryBytes: UInt64, macOSMajor: Int) throws -> MetricsEnvironment {
        try MetricsEnvironment(chipClass: chipClass(forBrand: chipBrand), memoryBand: memoryBand(forBytes: physicalMemoryBytes), macOSMajor: macOSMajor)
    }

    private static func chipClass(forBrand brand: String) -> ChipClass {
        if brand.localizedCaseInsensitiveContains("intel") { return .intel }
        guard brand.hasPrefix("Apple M") else { return .unknown }
        let digits = brand.dropFirst("Apple M".count).prefix { $0.isASCII && $0.isNumber }
        switch Int(digits) {
        case 1: return .appleM1
        case 2: return .appleM2
        case 3: return .appleM3
        case let generation? where generation >= 4: return .appleM4OrLater
        default: return .unknown
        }
    }

    private static func memoryBand(forBytes bytes: UInt64) -> MemoryBand {
        let gib: UInt64 = 1 << 30
        switch bytes {
        case 0: return .unknown
        case ...(8 * gib): return .upTo8GB
        case ...(16 * gib): return .upTo16GB
        case ...(32 * gib): return .upTo32GB
        case ...(64 * gib): return .upTo64GB
        default: return .over64GB
        }
    }

    private enum CodingKeys: String, CodingKey { case chipClass, memoryBand, macOSMajor }

    public init(from decoder: Decoder) throws {
        try decoder.requireOnlyKeys(["chipClass", "memoryBand", "macOSMajor"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                chipClass: values.decode(ChipClass.self, forKey: .chipClass),
                memoryBand: values.decode(MemoryBand.self, forKey: .memoryBand),
                macOSMajor: values.decode(Int.self, forKey: .macOSMajor))
        } catch let error as MetricsValidationError { throw metricsDecodingFailure(decoder, error) }
    }
}

extension MetricsEnvironment {
    /// This Mac, banded. The chip brand string and the memory size are read, banded and dropped on
    /// the spot; only the bands are kept. Nil if the macOS version is outside the supported range.
    public static func current(processInfo: ProcessInfo = .processInfo) -> MetricsEnvironment? {
        try? classify(
            chipBrand: chipBrandString(), physicalMemoryBytes: processInfo.physicalMemory,
            macOSMajor: processInfo.operatingSystemVersion.majorVersion)
    }

    private static func chipBrandString() -> String {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0) == 0 else { return "" }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
