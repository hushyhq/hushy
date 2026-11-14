import Foundation

/// When each step of opening a microphone happened, counted from the moment the capture was asked
/// to start. It splits "the first second was lost" into its parts: Hushy's own start-up (the graph
/// built, the engine started), the wait for the device's first buffer, and the silence a Bluetooth
/// headset delivers until its call link is up. Numbers only.
public struct CaptureTiming: Sendable, Equatable {
    /// The input graph was built and pointed at its device.
    public var graphReady: Duration?
    /// The engine reported it had started.
    public var engineStarted: Duration?
    /// The first buffer arrived, whatever was in it. A buffer arrives when it is full, so this is
    /// one buffer's length (about 100 ms) after the device began delivering.
    public var firstBuffer: Duration?
    /// The first buffer that was not exact zeros arrived.
    public var firstSound: Duration?

    public init(graphReady: Duration? = nil, engineStarted: Duration? = nil, firstBuffer: Duration? = nil,
                firstSound: Duration? = nil) {
        self.graphReady = graphReady
        self.engineStarted = engineStarted
        self.firstBuffer = firstBuffer
        self.firstSound = firstSound
    }

    public enum Step: Sendable { case graphReady, engineStarted, firstBuffer, firstSound }

    /// Each step is kept the first time it happens: a restart mid-capture does not move them.
    public mutating func mark(_ step: Step, at elapsed: Duration) {
        switch step {
        case .graphReady: graphReady = graphReady ?? elapsed
        case .engineStarted: engineStarted = engineStarted ?? elapsed
        case .firstBuffer: firstBuffer = firstBuffer ?? elapsed
        case .firstSound: firstSound = firstSound ?? elapsed
        }
    }

    /// How long the device delivered silence before its first sound: the headset's link coming up.
    /// Nil until both are known.
    public var silenceDelivered: Duration? {
        guard let firstBuffer, let firstSound else { return nil }
        return max(.zero, firstSound - firstBuffer)
    }

    /// "capture timing: graph ready 31 ms · engine started 96 ms · first buffer 214 ms · first sound 1312 ms".
    public var logLine: String {
        "capture timing: graph ready \(Self.words(graphReady)) · engine started \(Self.words(engineStarted))"
            + " · first buffer \(Self.words(firstBuffer)) · first sound \(Self.words(firstSound))"
    }

    public static func milliseconds(_ duration: Duration) -> Int {
        let parts = duration.components
        return Int((Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15).rounded())
    }

    private static func words(_ duration: Duration?) -> String {
        duration.map { "\(milliseconds($0)) ms" } ?? "-"
    }
}
