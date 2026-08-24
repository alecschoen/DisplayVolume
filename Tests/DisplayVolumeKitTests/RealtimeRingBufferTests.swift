import Testing
@testable import DisplayVolumeKit

@Suite("RealtimeRingBuffer")
struct RealtimeRingBufferTests {

    @Test("write then read round-trips samples")
    func roundTrip() {
        let ring = RealtimeRingBuffer(capacityFrames: 256, channelCount: 2)
        let input: [Float] = (0..<64).flatMap { [Float($0), Float(-$0)] }
        input.withUnsafeBufferPointer { ptr in
            _ = ring.write(interleaved: ptr.baseAddress!, frameCount: 32)
        }
        #expect(ring.framesAvailableToRead == 32)

        var output = [Float](repeating: 99, count: 64)
        let read = output.withUnsafeMutableBufferPointer { ptr in
            ring.read(into: ptr.baseAddress!, frameCount: 32)
        }
        #expect(read == 32)
        #expect(Array(output.prefix(64)) == Array(input.prefix(64)))
    }

    @Test("underrun zero-fills instead of delivering stale data")
    func underrunZeroFills() {
        let ring = RealtimeRingBuffer(capacityFrames: 64, channelCount: 2)
        var output = [Float](repeating: 7, count: 32)
        let read = output.withUnsafeMutableBufferPointer { ptr in
            ring.read(into: ptr.baseAddress!, frameCount: 16)
        }
        #expect(read == 0)
        #expect(output.prefix(32).allSatisfy { $0 == 0 })
    }

    @Test("overrun drops the excess and counts one event")
    func overrunDropsAndCounts() {
        let ring = RealtimeRingBuffer(capacityFrames: 16, channelCount: 2)
        let big = [Float](repeating: 1, count: 64 * 2)
        big.withUnsafeBufferPointer { ptr in
            _ = ring.write(interleaved: ptr.baseAddress!, frameCount: 64)
        }
        #expect(ring.framesAvailableToRead == 16)
        #expect(ring.overruns == 1)
    }

    @Test("wrap-around preserves sample ordering across many cycles")
    func wrapAroundOrdering() {
        let ring = RealtimeRingBuffer(capacityFrames: 8, channelCount: 2)
        var scratchOut = [Float](repeating: 0, count: 16)
        var next: Float = 0
        for _ in 0..<50 {
            let chunk: [Float] = (0..<5).flatMap { i -> [Float] in
                let v = next + Float(i)
                return [v, -v]
            }
            chunk.withUnsafeBufferPointer { ptr in
                #expect(ring.write(interleaved: ptr.baseAddress!, frameCount: 5) == 5)
            }
            let read = scratchOut.withUnsafeMutableBufferPointer { ptr in
                ring.read(into: ptr.baseAddress!, frameCount: 5)
            }
            #expect(read == 5)
            for i in 0..<5 {
                #expect(scratchOut[2 * i] == next + Float(i))
                #expect(scratchOut[2 * i + 1] == -(next + Float(i)))
            }
            next += 5
        }
        #expect(ring.underruns == 0)
        #expect(ring.overruns == 0)
    }

    @Test("capacity rounds up to a power of two")
    func capacityRoundsUp() {
        let ring = RealtimeRingBuffer(capacityFrames: 1000, channelCount: 2)
        #expect(ring.capacityFrames == 1024)
    }
}
