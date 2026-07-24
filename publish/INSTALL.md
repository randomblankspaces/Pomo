# Installing Pomo

**Requires macOS 14 (Sonoma) or later.**

Download either `Pomo-1.0.dmg` or `Pomo-1.0.zip` — same app, pick whichever you prefer.

- **DMG** — open it and drag **Pomo** onto the **Applications** shortcut.
- **ZIP** — unzip it and move **Pomo.app** into your Applications folder.

---

## First launch: macOS will block it once

You'll see *"Pomo Not Opened"*, *"Apple could not verify Pomo is free of malware"*, or *"Pomo is damaged and can't be opened."*

Nothing is wrong with the app. Pomo is signed **ad-hoc** rather than with a paid Apple Developer certificate, so it isn't notarized, and macOS quarantines anything unnotarized that arrives from the internet.

You only have to clear this once.

### The quick way

```bash
xattr -dr com.apple.quarantine /Applications/Pomo.app
```

Then open Pomo normally. This works on every macOS version.

### Or through System Settings

1. Double-click **Pomo** and dismiss the warning.
2. Open **System Settings → Privacy & Security**.
3. Scroll to Security — *"Pomo was blocked to protect your Mac"* — and click **Open Anyway**.
4. Confirm with Touch ID or your password.

> On **macOS 15 and later**, Control-clicking the app and choosing *Open* no longer bypasses this for unsigned apps — Apple removed that shortcut. Use one of the two methods above instead. (Older guides still recommend the Control-click trick; it won't work here.)

> Prefer not to run an unnotarized app? Build it yourself instead — it takes one command and Xcode signs it with your own Apple ID. See the [README](../README.md#quick-start).

---

## Permissions

Pomo asks for these the first time each feature is used. Both are optional; decline them and the rest of the app still works.

| Permission | Why | Needed for |
|---|---|---|
| **Automation** (System Events) | Toggle dark mode and set your accent colour | Immersive mode |
| **Screen Recording** | Read your current wallpaper | The Glass theme only |

Pomo makes no network requests. Nothing leaves your machine.

---

## Adding your own videos

Pomo ships with **no video files** — the backgrounds render procedurally until you add your own.

On first launch a red arrow points at the theme menu. Click **Add Theme…**, drop in an `.mp4`, `.mov`, or `.m4v`, and Pomo reads its palette, picks matching particle effects, and builds a theme around it. Edit any of it afterwards under **Settings → My Themes → right-click → Edit…**

Videos are copied to:

```
~/Library/Application Support/Pomo/Videos/
```

You can also drop files straight into that folder; they're picked up on the next launch.

---

## The widget

Pomo installs a widget alongside the app. To add it: right-click your desktop
→ **Edit Widgets**, search for **Pomo**, and drag it out. It mirrors the timer
live, and its start / pause / skip buttons drive the app.

The widget only appears in the picker after you've launched Pomo at least once
from Applications.

---

## Uninstalling

Drag `Pomo.app` to the Trash, then remove its data if you want it gone
completely:

```bash
rm -rf ~/Library/Application\ Support/Pomo
rm -rf ~/Library/Group\ Containers/com.pomo.app
defaults delete com.pomo.app
```

The second path is the timer state the app and widget share; the first holds
your settings **and any videos you imported** — move those out first if you
want to keep them.
