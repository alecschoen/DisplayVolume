import Testing
@testable import DisplayVolumeKit

@Suite("VolumeCurve mapping")
struct VolumeMappingTests {

    @Test("0% is silence, 100% is unity")
    func endpoints() {
        #expect(VolumeCurve.gain(forVolume: 0) == 0)
        #expect(VolumeCurve.gain(forVolume: 1) == 1)
    }

    @Test("gain never exceeds unity and never amplifies")
    func neverExceedsUnity() {
        var v: Float = 0
        while v <= 1.0 {
            let g = VolumeCurve.gain(forVolume: v)
            #expect(g >= 0)
            #expect(g <= 1)
            #expect(g <= v + 1e-6, "curve must sit at or below linear")
            v += 0.001
        }
    }

    @Test("curve is monotonically increasing")
    func monotonic() {
        var previous: Float = -1
        var v: Float = 0
        while v <= 1.0 {
            let g = VolumeCurve.gain(forVolume: v)
            #expect(g >= previous)
            previous = g
            v += 0.001
        }
    }

    @Test("out-of-range inputs clamp to the 0–100% range",
          arguments: [(Float(-0.5), Float(0)), (1.5, 1), (100, 1), (-100, 0)])
    func clamping(input: Float, expected: Float) {
        #expect(VolumeCurve.gain(forVolume: input) == expected)
    }

    @Test("NaN and infinity map to silence, never to noise",
          arguments: [Float.nan, .infinity, -.infinity, .signalingNaN])
    func invalidInputs(bad: Float) {
        let g = VolumeCurve.gain(forVolume: bad)
        #expect(g.isFinite)
        #expect(g == 0)
    }
}
