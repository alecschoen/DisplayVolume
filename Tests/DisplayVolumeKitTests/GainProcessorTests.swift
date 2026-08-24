import Testing
@testable import DisplayVolumeKit

@Suite("GainProcessor")
struct GainProcessorTests {

    private let sampleRate = 48_000.0
    private let channels = 2

    /// Runs `frames` of a constant signal through the processor and returns
    /// the interleaved output.
    private func process(_ gain: GainProcessor, frames: Int,
                         input: Float = 1.0) -> [Float] {
        var buffer = [Float](repeating: input, count: frames * channels)
        buffer.withUnsafeMutableBufferPointer { ptr in
            gain.processInterleaved(ptr.baseAddress!, frameCount: frames,
                                    channelCount: channels)
        }
        return buffer
    }

    /// Enough frames for any ramp to settle (100 ms at 48 kHz).
    private var settleFrames: Int { Int(sampleRate * 0.1) }

    @Test("0% volume produces exact silence after the ramp settles")
    func zeroVolumeProducesSilence() {
        let gain = GainProcessor()
        gain.prepare(sampleRate: sampleRate)
        gain.setTarget(volume: 0, muted: false)
        let out = process(gain, frames: settleFrames)
        #expect(out.suffix(1000).allSatisfy { $0 == 0 })
    }

    @Test("100% volume is bit-exact unity gain")
    func fullVolumeIsUnityGain() {
        let gain = GainProcessor()
        gain.prepare(sampleRate: sampleRate)
        gain.setTarget(volume: 1, muted: false)
        _ = process(gain, frames: settleFrames) // ramp up from silence
        let out = process(gain, frames: 512, input: 0.5)
        #expect(out.allSatisfy { $0 == 0.5 })
    }

    @Test("intermediate volumes never amplify beyond the source",
          arguments: [Float(0.01), 0.1, 0.25, 0.5, 0.75, 0.99])
    func intermediateVolumeNeverAmplifies(volume: Float) {
        let gain = GainProcessor()
        gain.prepare(sampleRate: sampleRate)
        gain.setTarget(volume: volume, muted: false)
        let out = process(gain, frames: settleFrames, input: 1.0)
        let peak = out.map(abs).max() ?? 0
        #expect(peak <= 1.0 + 1e-6)
        #expect(peak <= volume + 1e-6, "quadratic curve keeps gain(v) ≤ v")
    }

    @Test("mute produces zero samples; unmute restores the stored volume")
    func muteAndUnmute() {
        let gain = GainProcessor()
        gain.prepare(sampleRate: sampleRate)
        gain.setTarget(volume: 0.8, muted: false)
        _ = process(gain, frames: settleFrames)

        gain.setTarget(volume: 0.8, muted: true)
        let mutedOut = process(gain, frames: settleFrames)
        #expect(mutedOut.suffix(1000).allSatisfy { $0 == 0 })

        gain.setTarget(volume: 0.8, muted: false)
        let restored = process(gain, frames: settleFrames)
        let expected = VolumeCurve.gain(forVolume: 0.8)
        #expect(abs(restored.last! - expected) < 1e-4)
    }

    @Test("gain ramp contains no discontinuous jump and reaches its target")
    func rampHasNoDiscontinuity() {
        let gain = GainProcessor(rampMilliseconds: 15)
        gain.prepare(sampleRate: sampleRate)
        gain.setTarget(volume: 1, muted: false)
        let out = process(gain, frames: settleFrames, input: 1.0)

        // With constant full-scale input, output == applied gain per sample.
        let maxStep = Float(1.0 / (sampleRate * 0.015)) * 1.001
        var previous: Float = 0
        var maxObservedStep: Float = 0
        for frame in 0..<settleFrames {
            let value = out[frame * channels]
            maxObservedStep = max(maxObservedStep, abs(value - previous))
            previous = value
        }
        #expect(maxObservedStep <= maxStep)
        #expect(abs(previous - 1.0) < 1e-4)
    }

    @Test("pipeline startup ramps from silence, never jumps to the saved volume")
    func startupRampsFromSilence() {
        let gain = GainProcessor()
        gain.setTarget(volume: 1, muted: false)
        gain.prepare(sampleRate: sampleRate) // resets smoothed gain to 0
        let out = process(gain, frames: 64, input: 1.0)
        #expect(out[0] < 0.01)
    }

    @Test("mute/unmute transitions are smoothed")
    func muteTransitionIsSmoothed() {
        let gain = GainProcessor()
        gain.prepare(sampleRate: sampleRate)
        gain.setTarget(volume: 1, muted: false)
        _ = process(gain, frames: settleFrames)

        gain.setTarget(volume: 1, muted: true)
        let out = process(gain, frames: settleFrames, input: 1.0)
        let maxStep = Float(1.0 / (sampleRate * 0.015)) * 1.001
        var previous: Float = 1
        var maxObservedStep: Float = 0
        for frame in 0..<settleFrames {
            let value = out[frame * channels]
            maxObservedStep = max(maxObservedStep, abs(value - previous))
            previous = value
        }
        #expect(maxObservedStep <= maxStep)
        #expect(previous == 0, "mute must settle at exact zero")
    }

    @Test("invalid targets cannot create NaN or infinity")
    func invalidTargetsAreSafe() {
        let gain = GainProcessor()
        gain.prepare(sampleRate: sampleRate)
        gain.setTarget(volume: 0.5, muted: false)
        _ = process(gain, frames: settleFrames)

        gain.setTarget(volume: .nan, muted: false)
        gain.setTarget(volume: .infinity, muted: false)
        gain.setTarget(volume: -.infinity, muted: false)

        let out = process(gain, frames: 4096, input: 1.0)
        #expect(out.allSatisfy { $0.isFinite })
        let expected = VolumeCurve.gain(forVolume: 0.5)
        #expect(abs(out.last! - expected) < 1e-4,
                "invalid values must not change the target")
    }

    @Test("out-of-range volumes are clamped to 0–100%")
    func outOfRangeVolumesAreClamped() {
        let gain = GainProcessor()
        gain.prepare(sampleRate: sampleRate)
        gain.setTarget(volume: 5.0, muted: false)
        #expect(gain.targetGain == 1.0)
        gain.setTarget(volume: -3.0, muted: false)
        #expect(gain.targetGain == 0.0)
    }

    @Test("bogus sample rate in prepare() stays safe")
    func prepareWithBogusSampleRate() {
        let gain = GainProcessor()
        gain.prepare(sampleRate: .nan)
        gain.setTarget(volume: 1, muted: false)
        let out = process(gain, frames: 48_000)
        #expect(out.allSatisfy { $0.isFinite })
    }
}
