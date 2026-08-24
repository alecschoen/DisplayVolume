import CAtomics
import CoreAudio
import Foundation

/// Renders processed audio from the ring buffer to the selected physical
/// output device via a HAL IOProc.
///
/// Real-time rules observed in `render` (the IOProc):
///  - no allocation (scratch preallocated in init)
///  - no locks, no logging, no Core Audio property calls
///  - underruns are filled with silence and counted atomically
///
/// Priming: after start (and after any hard underrun) the renderer outputs
/// silence until the ring holds at least `prefillFrames`, which decouples the
/// tap and output IO cycles and prevents crackle storms.
public final class PhysicalOutputRenderer {

    private let ring: RealtimeRingBuffer
    private let prefillFrames: Int
    private let scratch: UnsafeMutablePointer<Float>
    private let scratchCapacityFrames: Int

    // Touched only by the output IO thread.
    private var primed = false

    private let callbackCounter: UnsafeMutablePointer<DVAtomicU64>

    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var started = false

    public var callbackCount: UInt64 { dv_u64_load(callbackCounter) }

    public init(ring: RealtimeRingBuffer, prefillFrames: Int, maxFramesPerSlice: Int = 16384) {
        self.ring = ring
        self.prefillFrames = prefillFrames
        self.scratchCapacityFrames = maxFramesPerSlice
        scratch = .allocate(capacity: maxFramesPerSlice * 2)
        scratch.initialize(repeating: 0, count: maxFramesPerSlice * 2)
        callbackCounter = .allocate(capacity: 1)
        callbackCounter.initialize(to: DVAtomicU64(_value: 0))
    }

    deinit {
        stopAndDetach()
        scratch.deallocate()
        callbackCounter.deallocate()
    }

    // MARK: - Lifecycle (non-real-time)

    public func attach(to deviceID: AudioObjectID) throws {
        precondition(ioProcID == nil, "renderer already attached")
        self.deviceID = deviceID
        var procID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, deviceID, nil) {
            [self] _, _, _, outOutputData, _ in
            // REAL-TIME PATH
            render(into: outOutputData)
        }
        guard status == noErr, procID != nil else {
            throw DisplayVolumeError.outputCallbackFailure(status: status)
        }
        ioProcID = procID
    }

    public func start() throws {
        guard let procID = ioProcID else {
            throw DisplayVolumeError.outputCallbackFailure(status: -1)
        }
        primed = false
        let status = AudioDeviceStart(deviceID, procID)
        guard status == noErr else {
            throw DisplayVolumeError.deviceStartFailed(status: status)
        }
        started = true
    }

    public func stopAndDetach() {
        if let procID = ioProcID {
            if started {
                AudioDeviceStop(deviceID, procID)
                started = false
            }
            AudioDeviceDestroyIOProcID(deviceID, procID)
            ioProcID = nil
        }
        deviceID = AudioObjectID(kAudioObjectUnknown)
    }

    // MARK: - Real-time render

    @inline(__always)
    private func render(into outOutputData: UnsafeMutablePointer<AudioBufferList>) {
        _ = dv_u64_add(callbackCounter, 1)

        let abl = UnsafeMutableAudioBufferListPointer(outOutputData)
        guard abl.count > 0, let firstData = abl[0].mData else { return }
        let firstChannels = max(1, Int(abl[0].mNumberChannels))
        let frameCount = Int(abl[0].mDataByteSize) / (MemoryLayout<Float>.size * firstChannels)
        guard frameCount > 0 else { return }

        if !primed {
            if ring.framesAvailableToRead >= prefillFrames {
                primed = true
            } else {
                silence(abl)
                return
            }
        }

        if ring.framesAvailableToRead < frameCount {
            // Hard underrun: count it, output silence, re-prime.
            ring.noteUnderrun()
            primed = false
            silence(abl)
            return
        }

        let frames = min(frameCount, scratchCapacityFrames)
        ring.read(into: scratch, frameCount: frames)

        if abl.count == 1 {
            // Interleaved output buffer with N channels.
            let dst = firstData.assumingMemoryBound(to: Float.self)
            if firstChannels == 2 {
                memcpy(dst, scratch, frames * 2 * MemoryLayout<Float>.size)
            } else if firstChannels == 1 {
                for f in 0..<frames {
                    dst[f] = 0.5 * (scratch[2 * f] + scratch[2 * f + 1])
                }
            } else {
                // Stereo into channels 0/1, silence in the rest.
                memset(dst, 0, Int(abl[0].mDataByteSize))
                for f in 0..<frames {
                    dst[f * firstChannels] = scratch[2 * f]
                    dst[f * firstChannels + 1] = scratch[2 * f + 1]
                }
            }
        } else {
            // Non-interleaved: one buffer per channel (or channel group).
            for (index, buffer) in abl.enumerated() {
                guard let data = buffer.mData else { continue }
                let dst = data.assumingMemoryBound(to: Float.self)
                let chans = max(1, Int(buffer.mNumberChannels))
                let bufFrames = min(frames, Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * chans))
                if index < 2 && chans == 1 {
                    for f in 0..<bufFrames { dst[f] = scratch[2 * f + index] }
                } else if index == 0 && chans >= 2 {
                    memset(data, 0, Int(buffer.mDataByteSize))
                    for f in 0..<bufFrames {
                        dst[f * chans] = scratch[2 * f]
                        dst[f * chans + 1] = scratch[2 * f + 1]
                    }
                } else {
                    memset(data, 0, Int(buffer.mDataByteSize))
                }
            }
        }
    }

    @inline(__always)
    private func silence(_ abl: UnsafeMutableAudioBufferListPointer) {
        for buffer in abl {
            if let data = buffer.mData {
                memset(data, 0, Int(buffer.mDataByteSize))
            }
        }
    }
}
