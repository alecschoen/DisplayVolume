# DisplayVolume — Manual Test Checklist

Target hardware: Apple Silicon Mac, macOS 14.2+ (primary: macOS 26), TCL
32X3A connected directly via USB-C (any fixed-volume USB-C/DP/HDMI display
works the same way).

Build first: `Scripts/build-app.sh`, then run `build/DisplayVolume.app`
(ideally moved to `/Applications` and signed with a stable identity — see
README).

Check each box only when the observed behavior matches the expectation.

## 1. First launch without permissions
- [ ] App shows a menu-bar speaker icon, no Dock icon.
- [ ] Onboarding window appears once, explains privacy, and never again
      after "Get Started".
- [ ] **No permission prompt appears at launch.** Status is "Stopped".
- [ ] Volume defaults to 50 %, not 100 %.

## 2. Granting System Audio Recording
- [ ] Select the display, press **Start Processing** → macOS shows the
      System Audio Recording consent (with the app's purpose string).
- [ ] Grant it. If audio doesn't flow immediately, Stop → Start once.
- [ ] Status becomes **Active**; Diagnostics "Audio observed: yes" once
      something plays; permission row flips to Granted.

## 3. Selecting 32X3A
- [ ] "32X3A" appears in the Output picker with its transport (USB).
- [ ] Diagnostics shows its UID, sample rate, and 2 channels once active.
- [ ] Aggregate devices from this app never appear in the picker, in
      System Settings → Sound, or in Audio MIDI Setup.

## 4. Playback from Safari
- [ ] YouTube in Safari plays through the monitor while Active.

## 5. Playback from Music (or another normal audio app)
- [ ] Music plays through the monitor; switching between apps mid-play
      keeps working.

## 6. Slider changes are audible
- [ ] Dragging 0→100 % sweeps smoothly from silence to full level.
- [ ] No clicks, pops, or zipper noise while dragging.
- [ ] 0 % is truly silent.

## 7. Volume keys are audible
- [ ] Enable "Control with keyboard volume keys" → Accessibility prompt
      appears (only now).
- [ ] Volume up/down changes by 5 points per press; holding repeats.
- [ ] ⌥⇧+volume keys change by 1 point.
- [ ] No system volume bezel fights the app; menu-bar percentage updates
      immediately.
- [ ] Pressing volume up/down while muted unmutes and applies the step.

## 8. Mute / unmute
- [ ] Mute → true silence (not just quiet); icon shows slashed speaker.
- [ ] Unmute → returns to the previous volume, with a short ramp, no pop.

## 9. No duplicate audio or echo
- [ ] While Active, listen for doubling/echo/comb filtering: none.
- [ ] Stop processing mid-playback → direct (full-volume) audio resumes
      seamlessly; still no doubling.

## 10. Disconnect / reconnect USB-C
- [ ] Unplug the display while Active → status "Output disconnected"
      within a couple of seconds; no crash, no CPU spin.
- [ ] Replug → processing resumes automatically with the saved volume
      (ramped, not jumped); selection and volume were preserved.
- [ ] Audio on other devices (e.g. MacBook speakers) was never muted by
      the app during the disconnect.

## 11. Sleep / wake
- [ ] Sleep the Mac while Active; wake it → processing resumes within a
      few seconds; volume ramps to the saved value.
- [ ] Repeat with the display detached at wake → "Output disconnected",
      then recovery when re-attached.

## 12. Changing the monitor's sample rate
- [ ] In Audio MIDI Setup, switch the display 48 kHz ↔ 44.1 kHz while
      Active → pipeline rebuilds automatically (≈1 s gap), then plays
      correctly at the new rate (Diagnostics shows the new rate).

## 13. Stopping processing
- [ ] **Stop Processing** → direct audio resumes at device level;
      status "Stopped"; Diagnostics counters freeze.

## 14. Quitting the application
- [ ] Quit from the popover while Active → audio continues directly
      (unmuted) without any user action; no orphaned devices appear in
      Audio MIDI Setup.
- [ ] `kill -9` the app while Active → same outcome (fail-safe unmute).

## 15. Relaunching with saved settings
- [ ] Relaunch → same device selected, same volume and mute state; if it
      was processing at quit it resumes automatically, otherwise it stays
      stopped; no onboarding window.

## 16. Denying Accessibility while using the slider
- [ ] Deny the Accessibility prompt → keyboard keys don't work, a red
      indicator shows next to the permission with "Open Settings", and the
      slider/mute/percentage keep working normally. No repeated prompts.

## 17. Denying System Audio Recording
- [ ] Deny the audio prompt → status "Permission required" with an
      "Open Settings" button; no repeated system prompts; device picker,
      preferences, and diagnostics still work.
- [ ] Grant later via System Settings → Start Processing works without
      reinstalling.

## 18. Match system output device
- [ ] With the toggle ON, pick a different device in the app's picker →
      System Settings → Sound → Output switches to the same device.
- [ ] Switch the output from Control Center / System Settings → the app's
      selection follows within a second and, if processing was active, it
      resumes on the new device.
- [ ] Turn the toggle OFF → the two selections become independent again.

## 19. One-hour soak
- [ ] Play continuous audio for ≥1 hour while Active.
- [ ] Memory (Activity Monitor) stays flat (no growth trend).
- [ ] CPU stays below ~5 % for the app during stereo playback.
- [ ] Diagnostics underruns/overruns essentially stop growing after
      startup.
- [ ] No audible crackling, dropouts, or drift at the end of the hour.
