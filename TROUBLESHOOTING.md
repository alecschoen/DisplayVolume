# Troubleshooting DisplayVolume

Open the menu-bar popover → **Diagnostics** and use **Copy Diagnostics**
when reporting an issue. Nothing in that report contains audio or personal
data.

## No audio at all while "Active"

1. **Permission not actually granted.** System Settings → Privacy &
   Security → **Screen & System Audio Recording** → System Audio Recording:
   make sure DisplayVolume is enabled. After changing it, press **Stop
   Processing**, then **Start Processing** (macOS applies the grant to new
   taps; in stubborn cases quit and relaunch the app).
   Diagnostics hint: `Audio observed: not yet` while something is audibly
   playing to that device means capture is blocked.
2. **Wrong output selected.** The device picker must show the display that
   the *system* is playing to (System Settings → Sound → Output). The tap
   captures audio destined for that specific device.
3. **App volume at 0 % or muted.** Check the percentage in the popover
   header.

## After a rebuild, macOS asks for permission again

Ad-hoc signatures change every build. Sign with a stable identity:

```bash
CODESIGN_IDENTITY="Apple Development: Your Name (TEAMID)" Scripts/build-app.sh
```

and keep the bundle ID `com.bnewable.DisplayVolume` unchanged. Run the app
from a stable path (e.g. `/Applications`).

## Audio is doubled / echoing

You are hearing both the direct and the processed signal. This should be
impossible while the tap is being read (`mutedWhenTapped` silences the
direct path). If you hear doubling:

- Confirm status is **Active** (if the pipeline stopped, only direct audio
  plays — that is correct and not doubled).
- Two copies of DisplayVolume running (e.g. one from `build/`, one from
  `/Applications`) will fight each other. Quit both, start one.

## Volume slider does nothing

- Status must be **Active**. When processing is stopped, audio flows
  directly at the device's fixed volume — the slider only affects the
  processed path.
- If status is **Permission required**, use **Open Settings** and grant
  System Audio Recording.

## Volume keys do nothing

- Enable **Control with keyboard volume keys** in the popover.
- Grant **Accessibility** when prompted (or Privacy & Security →
  Accessibility → enable DisplayVolume, then toggle the switch off/on).
- Keyboards with custom drivers (Logitech, etc.) sometimes remap media
  keys; verify the keys change the volume of a normal output first.
- The slider always works regardless of this permission.

## Crackling / dropouts

- Check Diagnostics → **Underruns/Overruns**. A handful right after start
  or reconnect is normal (the ring re-primes); steadily growing counts are
  not.
- Heavy CPU load from other apps can starve real-time threads; check
  Activity Monitor.
- Try a different USB-C cable/port — bus-powered display audio is
  occasionally marginal.
- Changing the display's sample rate in Audio MIDI Setup triggers an
  automatic pipeline rebuild; a one-second gap is expected, persistent
  crackling afterwards is not.

## "Output disconnected" won't recover

The app re-attaches automatically when a device with the **same UID**
returns. If the display re-enumerates with a different UID (rare, but some
docks do this), re-select it in the picker once; the new UID is then
remembered.

## Status shows "Audio error"

The diagnostics row **Last error** has the technical detail (OSStatus
four-char codes included). Typical causes:

- `deviceStartFailed` / `ioProcFailure`: another process holds the device
  exclusively (hog mode) — quit pro-audio apps.
- `formatMismatch`: the device changed rate mid-start; press Start again.
- `no stereo output stream`: the selected device is mono/capture-only —
  pick the real display output.

## Getting the app's logs

```bash
log show --last 10m --predicate 'subsystem == "com.bnewable.DisplayVolume"'
```

Logs never include audio content.

## Nothing helps

Quit DisplayVolume (audio always reverts to direct playback — if it
doesn't, unplug/replug the display, which resets the device). Then relaunch
and try again. The app never requires a reboot; the tap and aggregate are
private objects that die with the process.
