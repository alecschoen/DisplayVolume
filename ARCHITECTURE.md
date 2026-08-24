# DisplayVolume Architecture

## The problem

Fixed-volume digital outputs (USB-C/DisplayPort/HDMI displays such as the
TCL 32X3A) accept a digital audio stream at a fixed level. macOS exposes no
volume control for them, and the 32X3A's DDC implementation rejects the
standard audio VCP (`0x62`), so the only reliable lever is **attenuating the
PCM samples in software before they reach the device**.

## The audio path

```
┌────────────────────────────┐
│ Safari, Music, system, …   │  every process EXCEPT DisplayVolume
└─────────────┬──────────────┘
              │  audio destined for the selected device
              ▼
┌────────────────────────────┐   CATapDescription(
│   Core Audio process tap   │     __excludingProcesses: [ownProcessObjectID],
│   private,                 │     andDeviceUID: selectedUID, withStream: 0)
│   muteBehavior =           │   created with AudioHardwareCreateProcessTap
│   .mutedWhenTapped         │
└─────────────┬──────────────┘
              ▼
┌────────────────────────────┐   AudioHardwareCreateAggregateDevice with
│  private aggregate device  │   SubDeviceList = [device], TapList = [tap],
│  (tap as input source)     │   IsPrivate, TapAutoStart, DriftCompensation
└─────────────┬──────────────┘
              │  input IOProc (real-time thread)
              ▼
   InputTapContext.handleInput
     • normalize any Float32 layout → interleaved stereo scratch
     • GainProcessor.processInterleaved (volume curve + ramp)
     • RealtimeRingBuffer.write
              │
              ▼
┌────────────────────────────┐
│  RealtimeRingBuffer        │  SPSC, lock-free, preallocated,
│  (8192 frames, stereo)     │  atomic UInt64 positions
└─────────────┬──────────────┘
              │  output IOProc (real-time thread)
              ▼
   PhysicalOutputRenderer.render
     • prime: silence until ≥512 frames buffered
     • read ring → distribute to device ABL (interleaved or not,
       stereo → channels 0/1, others silenced)
     • underrun → silence + counter + re-prime
              │
              ▼
┌────────────────────────────┐
│  physical output device    │  the display, e.g. "32X3A"
└────────────────────────────┘
```

### Why the app excludes itself from the tap

The renderer plays the processed audio **on the same device the tap
watches**. If the tap captured DisplayVolume's own output, the pipeline
would re-capture its own signal — a feedback loop. The tap is therefore
created with the *excluding* initializer and this app's Core Audio process
object ID. That ID is obtained by translating our Unix PID through
`kAudioHardwarePropertyTranslatePIDToProcessObject` (a PID is **not** an
AudioObjectID). If that translation ever fails, startup **fails closed**
with a typed error rather than risking feedback.

### Why `.mutedWhenTapped`

While the tap is being read, Core Audio mutes the tapped processes' direct
path to the device, so the user hears only the processed signal (no
doubling/echo). The crucial property: the muting is tied to *active
reading*. If DisplayVolume stops, crashes, or is killed, the HAL unmutes
automatically. A permanently-muted configuration (`.muted`) could leave the
Mac silent after a crash and is deliberately not used.

### Why an aggregate device

Process taps are read through an aggregate device that lists the tap in
`kAudioAggregateDeviceTapListKey` (per Apple's sample). Ours also contains
the target device as its (main) sub-device, which keeps the aggregate's
clock identical to the output device's clock — so the producer and consumer
of the ring buffer run in the same clock domain and cannot drift apart.
The aggregate is `IsPrivate` (invisible to the user and other apps, and
auto-destroyed by the HAL if the process dies). On startup the app
additionally sweeps and destroys any stale aggregate whose UID carries the
app's prefix (`com.bnewable.DisplayVolume.aggregate`), as defense in depth
after an interrupted run.

### Ring buffer and priming

The two IOProcs run on independent real-time threads. The SPSC ring buffer
decouples them:

- Capacity 8192 frames (power of two, masked indices, monotonically
  increasing 64-bit positions with acquire/release atomics).
- The renderer outputs silence until the ring holds `prefillFrames` (512),
  then consumes continuously. On a hard underrun it emits silence, counts
  the event, and re-primes — one small gap instead of a crackle storm.
- Overruns (producer faster than consumer) drop the excess and count.
- Added latency ≈ prefill (512) + one IO buffer (256) ≈ **16 ms @ 48 kHz**.

## Real-time rules

Everything inside `InputTapContext.handleInput`,
`PhysicalOutputRenderer.render`, and `GainProcessor.processInterleaved`
obeys:

- **No allocation** — scratch buffers, ring storage, and atomic cells are
  allocated in `init`/`start`, never in callbacks.
- **No locks** — cross-thread values (target gain, positions, counters) go
  through C11 atomics (`Sources/CAtomics`), lock-free on arm64/x86_64.
- **No logging, no SwiftUI/Combine access, no Core Audio property calls,
  no object creation/destruction** in the callbacks.
- Diagnostics are counters incremented atomically on the RT threads and
  *polled* once per second by the UI (`AppState.pollTick`).

## Volume model

- UI volume `v ∈ [0, 1]`, displayed as 0–100 %.
- Curve: `gain = v²` (quadratic). Perceptually more even than linear,
  guarantees `gain ≤ v ≤ 1` — the app can never amplify or clip a signal
  that wasn't already clipped. `v = 0 → 0` exactly; `v = 1 → 1` exactly
  (unity is a bit-exact passthrough fast path).
- Mute sets the target gain to 0 while preserving the stored volume.
- The applied gain **slews linearly** toward the target with a bounded
  per-frame step sized so a full 0→1 swing takes 15 ms. Every transition —
  slider moves, mute, unmute, and pipeline startup (smoothed gain always
  starts at 0) — is therefore click-free.
- `setTarget` ignores non-finite volumes; the RT side additionally clamps
  and NaN-checks the target before use. Invalid input can never produce
  NaN/∞ output or gain > 1.

## Formats

The tap's format and the device stream's *virtual* (client-side) format are
read at startup and validated — never assumed. Supported: linear PCM
Float32, interleaved or non-interleaved, any channel count (mixed down /
up-placed to stereo), at whatever rate the device runs (44.1/48/96 kHz).
The tap inherits the device stream's rate, and both IOProcs run on the same
clock, so no resampler is needed; a rate/format *change* while running
triggers a clean rebuild of the whole pipeline (debounced, listener-driven).
A tap/output rate mismatch at startup is rejected with a typed error.

## Failure handling

| Event | Response |
|---|---|
| Device unplugged | alive-listener fires → pipeline stops cleanly → status "Output disconnected"; UID + volume kept; devices-changed listener retries when the UID reappears (backoff 1→30 s, no tight loop) |
| Sleep | pipeline stopped on `willSleep` |
| Wake | after 1.5 s, device re-resolved **by UID** (object IDs are invalid across sleep) and the pipeline is rebuilt with the saved volume ramping up from silence |
| Sample-rate / stream-format change | debounced stop + rebuild |
| IO stall (no callbacks for 4 s) | watchdog stops the pipeline, surfaces "Audio error" |
| Tap creation fails | typed error; treated as permission denial if audio was never observed |
| App quits/crashes | tap + aggregate are destroyed (explicitly, or by the HAL because both are private) → direct audio resumes automatically |

## Threads

- **Main thread**: AppState (`@MainActor`), SwiftUI, all Core Audio
  property/listener calls, pipeline start/stop, 1 Hz stats polling.
- **HAL RT thread A**: aggregate input IOProc (tap frames → gain → ring).
- **HAL RT thread B**: device output IOProc (ring → device buffers).
- **Event-tap callback** (main run loop): media keys only; hops to main
  queue to touch state.

## Media keys

`MediaKeyController` installs a CGEvent tap whose event mask contains only
`NX_SYSDEFINED` (type 14) and inspects only subtype 8 (aux control) with key
codes 0/1/7 (volume up/down/mute). Those three are consumed (so the useless
system bezel doesn't appear); everything else passes through untouched.
Key-down repeats arrive from the OS, giving smooth hold-to-repeat. The tap
requires Accessibility permission and is only installed when the user
enables the feature; if the OS disables the tap (timeout), it re-enables
itself.
