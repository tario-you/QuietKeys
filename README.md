# QuietKeys

Hides the macOS Tahoe volume and brightness popups. The keys still work; nothing is drawn.

It catches the volume, mute and brightness keys before macOS sees them and sets the level itself, so macOS never shows its popup. Same approach as [dannystewart/volumeHUD](https://github.com/dannystewart/volumeHUD), without a HUD of its own.

- Option+Shift with a key: fine steps (1/64).
- Option alone with a key: left to macOS (opens the matching System Settings pane).
- If QuietKeys can't change the level (external display, an output with no volume control), the key goes to macOS as normal.

## Install

```bash
./build.sh
```

This builds `~/Applications/QuietKeys.app` and a LaunchAgent that starts it at login. Then turn QuietKeys on in System Settings → Privacy & Security → Accessibility.

It signs with your first Apple Development identity so the Accessibility grant survives rebuilds. With no identity it signs ad-hoc, and you re-grant after each rebuild.

## Uninstall

```bash
launchctl bootout gui/$UID/live.opentrade.quietkeys
rm -rf ~/Applications/QuietKeys.app ~/Library/LaunchAgents/live.opentrade.quietkeys.plist
tccutil reset Accessibility live.opentrade.quietkeys
```

## License

MIT
