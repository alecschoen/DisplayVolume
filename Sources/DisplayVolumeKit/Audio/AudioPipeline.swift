import CAtomics
import CoreAudio
import Foundation

/// Snapshot of pipeline health for the diagnostics panel. Values are read
/// from atomics; the UI polls this outside the audio threads.
public struct PipelineStats: Equatable {
    public var deviceName = ""
    public var deviceUID = ""
    public var sampleRate: Double = 0
    public var channelCount = 0
    public var tapFormatDescription = ""
    public var outputFormatDescription = ""
    public var inputCallbacks: UInt64 = 0
    public var outputCallbacks: UInt64 = 0
    public var underruns: UInt64 = 0
    public var overruns: UInt64 = 0
    public var nonSilentInputSeen = false
    public var estimatedLatencyMs: Double = 0

    public init() {}
}

/// Orchestrates the full audio path:
///
///   apps/system audio → process tap (excluding this app, muted-when-tapped)
///     → private aggregate device (tap as input source)
///     → input IOProc: convert to interleaved stereo → GainProcessor
///     → RealtimeRingBuffer
///     → PhysicalOutputRenderer IOProc on the selected device
///
/// Everything the real-time callbacks touch is preallocated in `start`.
/// `start`/`stop` must be called on the main thread.
public final class AudioPipeline {

    public private(set) var isRunning = false
    public private(set) var currentDeviceID = AudioObjectID(kAudioObjectUnknown)
    public private(set) var currentDeviceUID = ""
    public private(set) var currentDeviceName = ""

    public let gain: GainProcessor

    private let tap = ProcessTapController()
    private let aggregate = AggregateDeviceController()
    private var ring: RealtimeRingBuffer?
    private var renderer: PhysicalOutputRenderer?
    private var inputContext: InputTapContext?
    private var inputProcID: AudioDeviceIOProcID?
    private var inputStarted = false

    private var tapFormatDescription = ""
    private var outputFormatDescription = ""
    private var statsSampleRate: Double = 0
    private var statsChannels = 0
    private var latencyMs: Double = 0

    /// IO buffer size requested from the HAL for both sides.
    public var ioBufferFrames: UInt32 = 256
    /// Frames buffered before the renderer starts consuming (adds latency,
    /// absorbs cycle phase offset between the two devices).
    public var prefillFrames: Int = 512

    public init(gain: GainProcessor) {
        self.gain = gain
    }

    deinit { stop() }

    // MARK: - Start

    public func start(deviceUID: String) throws {
        precondition(Thread.isMainThread)
        guard !isRunning else { return }

        // 1. Resolve the persistent UID to today's AudioObjectID. IDs are
        //    transient (change across reconnect/sleep); UIDs are stable.
        guard let deviceID = CA.deviceID(forUID: deviceUID), CA.isAlive(deviceID) else {
            throw DisplayVolumeError.deviceUnavailable(uid: deviceUID)
        }
        let deviceName = CA.objectName(deviceID) ?? deviceUID

        guard CA.outputChannelCount(deviceID) >= 2 else {
            throw DisplayVolumeError.noStereoOutput(deviceName: deviceName)
        }

        // 2. Validate the device's output stream format (never assume).
        guard let stream0 = CA.outputStreamIDs(deviceID).first else {
            throw DisplayVolumeError.noStereoOutput(deviceName: deviceName)
        }
        let (formatStatus, outFormat) = CA.streamVirtualFormat(stream0)
        guard formatStatus == noErr else {
            throw DisplayVolumeError.unsupportedFormat(details: "stream format unreadable (\(formatStatus))")
        }
        let outValidated = try AudioFormatUtilities.validate(outFormat)

        do {
            // 3. Tap (excludes this app; muted-when-tapped fail-safe).
            try tap.create(deviceUID: deviceUID)
            let tapValidated = try AudioFormatUtilities.validate(tap.tapFormat)

            // 4. The tap should match the device rate; a mismatch would need
            //    a resampler, which this version deliberately does not run in
            //    the RT path. Rebuilding on rate change is handled upstream.
            guard abs(tapValidated.sampleRate - outValidated.sampleRate) < 1.0 else {
                throw DisplayVolumeError.formatMismatch(details:
                    "tap \(tapValidated.sampleRate) Hz vs output \(outValidated.sampleRate) Hz")
            }

            // 5. Private aggregate hosting the tap.
            try aggregate.create(targetDeviceUID: deviceUID, tapUID: tap.tapUID)

            // 6. Reasonable IO buffer sizes (best effort; failure is benign).
            setBufferFrameSize(aggregate.aggregateID, frames: ioBufferFrames)
            setBufferFrameSize(deviceID, frames: ioBufferFrames)

            // 7. Preallocate the shared ring and both RT contexts.
            let ring = RealtimeRingBuffer(capacityFrames: 8192, channelCount: 2)
            let renderer = PhysicalOutputRenderer(ring: ring, prefillFrames: prefillFrames)
            let inputCtx = InputTapContext(ring: ring, gain: gain)
            gain.prepare(sampleRate: outValidated.sampleRate)

            // 8. Input IOProc on the aggregate. The block captures only the
            //    preallocated context.
            var procID: AudioDeviceIOProcID?
            let createStatus = AudioDeviceCreateIOProcIDWithBlock(
                &procID, aggregate.aggregateID, nil) { _, inInputData, _, _, _ in
                // REAL-TIME PATH
                inputCtx.handleInput(inInputData)
            }
            guard createStatus == noErr, let inputProc = procID else {
                throw DisplayVolumeError.inputCallbackFailure(status: createStatus)
            }
            inputProcID = inputProc
            self.ring = ring
            self.renderer = renderer
            self.inputContext = inputCtx

            // 9. Attach + start output first (renders silence until primed),
            //    then start the tap input.
            try renderer.attach(to: deviceID)
            try renderer.start()
            let startStatus = AudioDeviceStart(aggregate.aggregateID, inputProc)
            guard startStatus == noErr else {
                throw DisplayVolumeError.deviceStartFailed(status: startStatus)
            }
            inputStarted = true

            currentDeviceID = deviceID
            currentDeviceUID = deviceUID
            currentDeviceName = deviceName
            tapFormatDescription = AudioFormatUtilities.describe(tap.tapFormat)
            outputFormatDescription = AudioFormatUtilities.describe(outFormat)
            statsSampleRate = outValidated.sampleRate
            statsChannels = 2
            latencyMs = Double(prefillFrames + Int(ioBufferFrames)) / outValidated.sampleRate * 1000
            isRunning = true
            AppLog.audio.info("Pipeline running on \(deviceName, privacy: .public) (\(self.outputFormatDescription, privacy: .public))")
        } catch {
            teardown()
            throw error
        }
    }

    // MARK: - Stop

    /// Stops IO and destroys the tap and aggregate. After this returns, the
    /// tap no longer exists, so Core Audio unmutes the original direct audio
    /// path — the system is never left silent.
    public func stop() {
        teardown()
        if isRunning {
            AppLog.audio.info("Pipeline stopped")
        }
        isRunning = false
    }

    private func teardown() {
        if let procID = inputProcID {
            if inputStarted, aggregate.isActive {
                AudioDeviceStop(aggregate.aggregateID, procID)
            }
            if aggregate.isActive {
                AudioDeviceDestroyIOProcID(aggregate.aggregateID, procID)
            }
            inputProcID = nil
            inputStarted = false
        }
        renderer?.stopAndDetach()
        renderer = nil
        aggregate.destroy()
        tap.destroy()
        ring = nil
        inputContext = nil
        currentDeviceID = AudioObjectID(kAudioObjectUnknown)
    }

    // MARK: - Diagnostics

    public func stats() -> PipelineStats {
        var s = PipelineStats()
        s.deviceName = currentDeviceName
        s.deviceUID = currentDeviceUID
        s.sampleRate = statsSampleRate
        s.channelCount = statsChannels
        s.tapFormatDescription = tapFormatDescription
        s.outputFormatDescription = outputFormatDescription
        s.inputCallbacks = inputContext?.callbackCount ?? 0
        s.outputCallbacks = renderer?.callbackCount ?? 0
        s.underruns = ring?.underruns ?? 0
        s.overruns = ring?.overruns ?? 0
        s.nonSilentInputSeen = inputContext?.nonSilentSeen ?? false
        s.estimatedLatencyMs = latencyMs
        return s
    }

    private func setBufferFrameSize(_ deviceID: AudioObjectID, frames: UInt32) {
        var addr = CA.address(kAudioDevicePropertyBufferFrameSize)
        var value = frames
        let status = AudioObjectSetPropertyData(deviceID, &addr, 0, nil,
                                                UInt32(MemoryLayout<UInt32>.size), &value)
        if status != noErr {
            AppLog.audio.warning("Could not set buffer size on \(deviceID): \(status)")
        }
    }
}

// MARK: - Input real-time context

/// Everything the tap-input IOProc touches. Fully preallocated; the
/// callback performs no allocation, locking, or logging.
final class InputTapContext {
    private let ring: RealtimeRingBuffer
    private let gain: GainProcessor
    private let scratch: UnsafeMutablePointer<Float>
    private let scratchCapacityFrames: Int

    private let callbacks: UnsafeMutablePointer<DVAtomicU64>
    private let nonSilentFlag: UnsafeMutablePointer<DVAtomicU32>

    var callbackCount: UInt64 { dv_u64_load(callbacks) }
    var nonSilentSeen: Bool { dv_u32_load(nonSilentFlag) != 0 }

    init(ring: RealtimeRingBuffer, gain: GainProcessor, maxFramesPerSlice: Int = 16384) {
        self.ring = ring
        self.gain = gain
        self.scratchCapacityFrames = maxFramesPerSlice
        scratch = .allocate(capacity: maxFramesPerSlice * 2)
        scratch.initialize(repeating: 0, count: maxFramesPerSlice * 2)
        callbacks = .allocate(capacity: 1)
        callbacks.initialize(to: DVAtomicU64(_value: 0))
        nonSilentFlag = .allocate(capacity: 1)
        nonSilentFlag.initialize(to: DVAtomicU32(_value: 0))
    }

    deinit {
        scratch.deallocate()
        callbacks.deallocate()
        nonSilentFlag.deallocate()
    }

    /// REAL-TIME PATH. Converts whatever stereo-compatible Float32 layout
    /// the tap delivers (interleaved or non-interleaved, 1..N channels)
    /// into interleaved stereo, applies gain, and pushes into the ring.
    @inline(__always)
    func handleInput(_ inputData: UnsafePointer<AudioBufferList>) {
        _ = dv_u64_add(callbacks, 1)

        let abl = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: inputData))
        guard abl.count > 0, let firstData = abl[0].mData else { return }
        let firstChannels = max(1, Int(abl[0].mNumberChannels))
        var frames = Int(abl[0].mDataByteSize) / (MemoryLayout<Float>.size * firstChannels)
        guard frames > 0 else { return }
        frames = min(frames, scratchCapacityFrames)

        if abl.count == 1 {
            let src = firstData.assumingMemoryBound(to: Float.self)
            switch firstChannels {
            case 2:
                memcpy(scratch, src, frames * 2 * MemoryLayout<Float>.size)
            case 1:
                for f in 0..<frames {
                    let v = src[f]
                    scratch[2 * f] = v
                    scratch[2 * f + 1] = v
                }
            default:
                for f in 0..<frames {
                    scratch[2 * f] = src[f * firstChannels]
                    scratch[2 * f + 1] = src[f * firstChannels + 1]
                }
            }
        } else {
            // Non-interleaved: buffer 0 = left, buffer 1 = right.
            let left = firstData.assumingMemoryBound(to: Float.self)
            let rightBuffer = abl[1]
            let right = rightBuffer.mData?.assumingMemoryBound(to: Float.self) ?? left
            let rightFrames = Int(rightBuffer.mDataByteSize) / MemoryLayout<Float>.size
            let n = min(frames, max(0, rightFrames))
            for f in 0..<n {
                scratch[2 * f] = left[f]
                scratch[2 * f + 1] = right[f]
            }
            for f in n..<frames {
                scratch[2 * f] = left[f]
                scratch[2 * f + 1] = left[f]
            }
        }

        // Permission heuristic: note the first non-silent input sample.
        if dv_u32_load(nonSilentFlag) == 0 {
            let count = frames * 2
            for i in 0..<count where scratch[i] != 0 {
                dv_u32_store(nonSilentFlag, 1)
                break
            }
        }

        gain.processInterleaved(scratch, frameCount: frames, channelCount: 2)
        ring.write(interleaved: scratch, frameCount: frames)
    }
}
