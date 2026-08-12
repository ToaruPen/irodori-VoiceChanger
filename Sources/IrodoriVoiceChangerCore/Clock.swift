import Dispatch

public protocol MonotonicClock: Sendable {
    func nowNanoseconds() -> UInt64
}

public struct SystemMonotonicClock: MonotonicClock {
    public init() {}

    public func nowNanoseconds() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }
}
