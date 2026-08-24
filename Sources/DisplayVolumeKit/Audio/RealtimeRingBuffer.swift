import CAtomics
import Foundation

/// Single-producer / single-consumer lock-free ring buffer for interleaved
/// Float32 frames.
///
///  - Producer: the aggregate-device (tap) IOProc.
///  - Consumer: the physical-output IOProc.
///
/// All storage is preallocated in `init`. `write` and `read` are real-time
/// safe: no allocation, no locks, only memcpy/memset and two atomics.
/// Positions are monotonically increasing UInt64 frame counters; buffer
/// offsets are derived with a power-of-two mask.
public final class RealtimeRingBuffer {
    public let capacityFrames: Int
    public let channelCount: Int

    private let mask: UInt64
    private let storage: UnsafeMutablePointer<Float>

    private let writePos: UnsafeMutablePointer<DVAtomicU64>
    private let readPos: UnsafeMutablePointer<DVAtomicU64>
    private let underrunCounter: UnsafeMutablePointer<DVAtomicU64>
    private let overrunCounter: UnsafeMutablePointer<DVAtomicU64>

    public init(capacityFrames: Int = 8192, channelCount: Int = 2) {
        var cap = 1
        while cap < max(2, capacityFrames) { cap <<= 1 }
        self.capacityFrames = cap
        self.channelCount = max(1, channelCount)
        self.mask = UInt64(cap - 1)

        let sampleCount = cap * self.channelCount
        storage = .allocate(capacity: sampleCount)
        storage.initialize(repeating: 0, count: sampleCount)

        writePos = .allocate(capacity: 1)
        writePos.initialize(to: DVAtomicU64(_value: 0))
        readPos = .allocate(capacity: 1)
        readPos.initialize(to: DVAtomicU64(_value: 0))
        underrunCounter = .allocate(capacity: 1)
        underrunCounter.initialize(to: DVAtomicU64(_value: 0))
        overrunCounter = .allocate(capacity: 1)
        overrunCounter.initialize(to: DVAtomicU64(_value: 0))
    }

    deinit {
        storage.deallocate()
        writePos.deallocate()
        readPos.deallocate()
        underrunCounter.deallocate()
        overrunCounter.deallocate()
    }

    // MARK: - State

    public var framesAvailableToRead: Int {
        let w = dv_u64_load(writePos)
        let r = dv_u64_load(readPos)
        return Int(w &- r)
    }

    public var framesAvailableToWrite: Int {
        capacityFrames - framesAvailableToRead
    }

    public var underruns: UInt64 { dv_u64_load(underrunCounter) }
    public var overruns: UInt64 { dv_u64_load(overrunCounter) }

    /// Reset positions (only while neither audio callback is running).
    public func reset() {
        dv_u64_store(writePos, 0)
        dv_u64_store(readPos, 0)
        memset(storage, 0, capacityFrames * channelCount * MemoryLayout<Float>.size)
    }

    /// Consumer-side event counter for output-side underruns (priming misses).
    public func noteUnderrun() {
        _ = dv_u64_add(underrunCounter, 1)
    }

    // MARK: - Producer (real-time safe)

    /// Writes interleaved frames. If there is not enough free space the
    /// excess frames are dropped and one overrun event is counted.
    /// Returns the number of frames actually written.
    @discardableResult
    public func write(interleaved src: UnsafePointer<Float>, frameCount: Int) -> Int {
        guard frameCount > 0 else { return 0 }
        let w = dv_u64_load(writePos)
        let r = dv_u64_load(readPos)
        let space = capacityFrames - Int(w &- r)
        let n = min(frameCount, max(0, space))
        if n < frameCount {
            _ = dv_u64_add(overrunCounter, 1)
        }
        guard n > 0 else { return 0 }

        let startFrame = Int(w & mask)
        let firstFrames = min(n, capacityFrames - startFrame)
        let ch = channelCount
        memcpy(storage + startFrame * ch, src,
               firstFrames * ch * MemoryLayout<Float>.size)
        let remaining = n - firstFrames
        if remaining > 0 {
            memcpy(storage, src + firstFrames * ch,
                   remaining * ch * MemoryLayout<Float>.size)
        }
        dv_u64_store(writePos, w &+ UInt64(n))
        return n
    }

    // MARK: - Consumer (real-time safe)

    /// Reads up to `frameCount` interleaved frames into `dst`; any shortfall
    /// is zero-filled. Returns the number of real frames delivered.
    /// (Underrun accounting is the caller's decision — see the renderer's
    /// priming logic.)
    @discardableResult
    public func read(into dst: UnsafeMutablePointer<Float>, frameCount: Int) -> Int {
        guard frameCount > 0 else { return 0 }
        let w = dv_u64_load(writePos)
        let r = dv_u64_load(readPos)
        let avail = Int(w &- r)
        let n = min(frameCount, max(0, avail))
        let ch = channelCount

        if n > 0 {
            let startFrame = Int(r & mask)
            let firstFrames = min(n, capacityFrames - startFrame)
            memcpy(dst, storage + startFrame * ch,
                   firstFrames * ch * MemoryLayout<Float>.size)
            let remaining = n - firstFrames
            if remaining > 0 {
                memcpy(dst + firstFrames * ch, storage,
                       remaining * ch * MemoryLayout<Float>.size)
            }
            dv_u64_store(readPos, r &+ UInt64(n))
        }
        if n < frameCount {
            memset(dst + n * ch, 0, (frameCount - n) * ch * MemoryLayout<Float>.size)
        }
        return n
    }
}
