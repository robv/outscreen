# Outscreen

Use your external monitor with your MacBook open.

Outscreen is a small, native macOS menu bar app with four controls:

- Turn the built-in display off or on.
- Optionally switch automatically when a physical external monitor connects.
- Restore on unplug or quit, with **Control–Option–Command–R** for emergency restoration.
- Optionally launch at login.

Automatic switching and launch at login start **off**. The app has no network calls, analytics, accounts, or dependencies beyond macOS frameworks.

## Requirements

- An Apple Silicon MacBook running macOS 13 or later.
- A physical external display connected directly over USB-C, Thunderbolt, DisplayPort, or HDMI, in extended-desktop mode.
- Xcode Command Line Tools (or Xcode) to build.

AirPlay, Sidecar, virtual displays, mirrored configurations, and DisplayLink are not currently supported as the only external display. Outscreen refuses to disable the built-in screen without a recognized active physical monitor.

## Build and install

```sh
make test
make build
make install
```

`make install` builds and installs `/Applications/Outscreen.app`, then opens it. To choose another destination:

```sh
./scripts/install.sh "$HOME/Applications/Outscreen.app"
```

The menu bar icon switches between a laptop and an external display. There is no Dock icon.

Builds are locally ad-hoc signed. To sign with your own Developer ID, set `OUTSCREEN_SIGN_IDENTITY` when building. Downloaded builds require an appropriate distribution-signing and notarization workflow; this repository does not claim a notarized release.

## Everyday use

Click the menu bar icon and choose **Turn Off Built-in Display**. Windows and the pointer stay on your external monitor, while the laptop remains open for its keyboard, trackpad, and Touch ID.

Enable **Automatically Switch on Monitor Connection** for automatic operation. Manually turning the built-in screen back on pauses automation until the external monitor count changes. Emergency restoration turns automatic switching off completely so it cannot immediately undo your recovery.

Enable **Launch at Login** from the menu. If macOS requires approval, the menu includes a link to Login Items. Rebuilding an ad-hoc signed app can invalidate its login registration; check this setting after installing an update.

## Recovery

Press **Control–Option–Command–R** from any app, or choose **Restore Built-in Display** from the menu. Shortcut conflicts appear in the menu as an error.

If the menu app is no longer responding, run:

```sh
/Applications/Outscreen.app/Contents/MacOS/Outscreen --restore
```

That recovery path works independently of the menu process and cancels automatic switching. Display changes are session-only; they are not written as permanent system display settings.

A separate guardian process watches for a lost external monitor or a crashed menu process. Mutations are serialized across the app, guardian, and recovery command. Potentially stalled private display calls run in disposable, time-limited helper processes. Recovery is verified against the active display list and the result of the panel-power request. The driver’s registry power state is not treated as proof of panel illumination. These safeguards reduce risk; private APIs can still fail or change between macOS releases.

When the lid is closed, macOS owns clamshell behavior. Outscreen avoids forcing the closed panel on. If you quit while it owns an off display and the lid is closed/asleep, its guardian remains until the lid opens and it can restore. Unusual failures may require closing/opening the lid, reconnecting the monitor, or restarting the Mac.

## Development

The app uses AppKit, CoreGraphics, IOKit, Carbon hotkeys, and ServiceManagement. It is built with `swiftc` and `clang`; no third-party dependencies or package manager are required.

`--status` prints a read-only JSON snapshot. `--toggle` and `--quit` route through the running menu app, including its recovery protection. `--version` prints the app version. `--set` and `--guardian` are internal commands used by the app, not supported automation interfaces.

The low-level backend uses private `SkyLight` and `IOMobileFramebuffer` APIs to remove the built-in screen from the desktop and power its panel down. Their behavior is not an Apple compatibility guarantee. Test upgrades on real hardware before relying on automation.

See [TESTING.md](TESTING.md) for checks that require physical interaction. Private API signatures and Apple Silicon behavior were researched in [Clamless](https://github.com/TCXM/clamless); Outscreen's implementation is original code.

## Uninstall

Turn off Launch at Login, then quit Outscreen to restore the display. Move `/Applications/Outscreen.app` to the Trash. The source repository is independent of the installed app. Preferences use `com.daymoon.outscreen`; temporary coordination files are scoped to your user and current boot session.

## License

[MIT](LICENSE) — Copyright © 2026 Robert Velasquez.
