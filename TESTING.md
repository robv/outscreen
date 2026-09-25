# Outscreen verification

## Automated checks

Run `make test`. This checks the intent policy (manual, auto, unplug, reconnect, and emergency override), strict C compilation, and bundle metadata. `make build` compiles and signs the full native app and verifies its local signature.

Tests do not change real displays. Actual display changes require a logged-in macOS desktop session with supported hardware.

## Physical acceptance checklist

Quit other utilities that automatically manage display connections before testing.

1. With the lid open and an external monitor connected, turn the built-in screen off. Verify the panel is dark, the pointer cannot enter it, and the external remains usable.
2. Press Control–Option–Command–R while another app is active. Verify the built-in screen returns and automatic switching is unchecked.
3. Turn the built-in screen off, then quit Outscreen. Verify it comes back before the app exits.
4. Enable automatic switching. Unplug the external monitor. Verify the internal panel returns promptly. Reconnect and verify automatic off resumes.
5. With automatic switching enabled, manually turn the built-in display on. It should stay on until a monitor is disconnected/reconnected or automatic mode is re-enabled.
6. Repeat unplug/reconnect through each dock, cable, and monitor arrangement you use. Confirm monitor sleep and input switching do not strand the desktop.
7. Sleep/wake the Mac with the internal off. Repeat with the lid closed, and with the cable removed during sleep. Verify the internal restores whenever no usable external remains.
8. Quit while the lid is closed, unplug the monitor, then open the lid. Verify the guardian restores the panel.
9. Enable Launch at Login, approve in System Settings if requested, log out/in or restart, and verify the icon and automatic preference return. Turn it back off and repeat if testing removal.
10. After every macOS upgrade, repeat the off/on, unplug, and sleep tests before leaving automatic switching enabled.

## Local test record

See the final task report for checks actually performed. The presence of a checkbox above does not claim that the physical test was run.

### 2026-09-25 — local verification

Hardware: Apple Silicon MacBook Pro (M4 Pro), macOS 26.5.1, one recognized physical external monitor.

Passed:

- Native release build, strict C compilation, property-list validation, local code-signature verification.
- Display intent policy tests.
- Isolated restore-marker, malformed-marker, cross-process lock, worker exit/failure, and bounded-timeout tests. These tests cannot call the real display backend.
- Live backend off/on cycle: panel-off request accepted; built-in display removed from active/online CoreGraphics lists; external stayed active; built-in successfully restored.
- Toggle through the running app followed by normal quit: built-in restored before app exit.
- Simulated menu-app crash while off: independent guardian restored the built-in display.
- Independent CLI restore.

Still requires a person:

- Physical panel appearance, actual unplug/replug and different cable/dock arrangements.
- Sleep/wake, closed-lid quit/reopen, and logout/reboot launch-at-login persistence.
- Physical Control–Option–Command–R keypress. The UI automation tool's targeted keypress did not trigger the global shortcut, so this is not claimed as verified.
- Visual menu inspection: the native UI inspector times out on this menu-only app (no standard app window). The installed app launches and its controller responds to commands.

The initial live test caught an incorrect IORegistry power assertion: `CurrentPowerState` remains 1 even after the panel-off request succeeds. It is now diagnostic only. A quit test also caught and fixed an AppKit nested-run-loop issue with `.terminateLater`; the app now cancels the initial quit, restores asynchronously, then terminates normally.
