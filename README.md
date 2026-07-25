# Pomo

A pomodoro timer for macOS that takes over your desktop — live video wallpapers, interactive particle effects, and themes generated automatically from whatever video you drop in.

![Pomo demo](Screenshots/demo.gif)

> **The videos are not included.** Pomo ships with 25 built-in themes that render
> procedurally, and you add your own videos in a couple of clicks — see
> [Add your own theme](#add-your-own-theme). The live wallpapers in these
> screenshots came from [moewalls.com](https://moewalls.com), which is where I
> get mine; any `.mp4`, `.mov`, or `.m4v` works.

---

## Install

**Requires macOS 14 (Sonoma) or later.**

Grab [`Pomo-1.0.dmg`](publish/Pomo-1.0.dmg) (or [the zip](publish/Pomo-1.0.zip)) and drag Pomo into Applications.

**Then run this once**, or macOS will refuse to open it:

```bash
xattr -dr com.apple.quarantine /Applications/Pomo.app
```

<details>
<summary>Why is that needed?</summary>

Pomo is signed ad-hoc rather than with a paid Apple Developer certificate
($99/yr), so it isn't notarized. macOS quarantines anything unnotarized that
arrives from the internet and shows *"Apple could not verify Pomo is free of
malware"* — with no Open button, so it looks like a dead end. The command above
clears the quarantine flag. Afterwards Pomo launches normally, forever, with
nothing disabled.

You can also do it through the UI: double-click Pomo, dismiss the warning, then
**System Settings → Privacy & Security → Open Anyway**. Note that Control-click →
*Open*, which older guides recommend, no longer works for unsigned apps on
macOS 15+.

Building from source avoids all of this — quarantine is only attached to
browser downloads.

</details>

Full steps, permissions, and uninstall notes are in [publish/INSTALL.md](publish/INSTALL.md).

---

## Build from source

**You need:** macOS 14 (Sonoma) or later, and Xcode 15+.

```bash
git clone https://github.com/randomblankspaces/Pomo.git
cd Pomo
```

Set your Apple Team ID (find it in Xcode → **Settings → Accounts**, or on the [developer portal](https://developer.apple.com/account)):

```bash
sed -i '' 's/YOUR_TEAM_ID/ABCDE12345/g' Pomo.xcodeproj/project.pbxproj
```

Then open it and press `⌘R`:

```bash
open Pomo.xcodeproj
```

**A paid developer account is not required.** Your free personal team (just your Apple ID) works — Xcode handles provisioning, and the app-group entitlement uses `$(TeamIdentifierPrefix)` so it adapts to whatever team you sign with.

---

## Add your own theme

Pomo starts with no custom themes and points you at the button with a red arrow.

1. Click the theme menu (top-left) → **Add Theme…**, or go to **Settings → My Themes** and click the dashed tile.
2. Drop in a video (`.mp4`, `.mov`, `.m4v`) or click **Choose Video…**.
3. Pomo copies it, reads its palette, picks matching particles, and builds the theme. Name it and you're done.

To change anything later: **Settings → My Themes → right-click a theme → Edit…**. You can set the ring colors, accent, emoji, and up to two particle effects, or hit **Re-read video** to regenerate the palette from scratch.

Videos live in `~/Library/Application Support/Pomo/Videos/`. You can also copy files there directly — anything new is picked up on next launch. For the battery-saver path, drop a 1080p version of the same file in `~/Library/Application Support/Pomo/Videos-1080/`.

### How the auto-theming works

Pomo samples four frames and builds a histogram over hue, then takes every peak — not just the biggest one. It picks the peak that most looks like *light* (saturation × brightness²) rather than the one covering the most pixels, because the color a scene reads as is usually the thing glowing, not the largest surface. For a moonlit field that's the moon, at 2% of the frame; for a night city it's the neon signs.

Particles come from content, not color — a histogram can't tell a black hole from a campfire. Pomo runs the frames through the macOS scene classifier and maps what it finds (`blossom` → petals, `sand_dune` → sand drift, `cityscape` → 8-bit pixels, `vehicle`/`road` → 3D rain), falling back to hue when nothing is recognized.

Measured against the 25 hand-tuned built-in themes, this reproduces the intended particle effect 10/10 on the author's test set, with every ring hue landing within 0.04.

---

## Features

**Timer** — configurable focus / short break / long break, auto-start, session counter with long-break cycling, animated ring with orbiting comet and glow pulse, completion sound.

**Desktop mode** (`⌘D`) — the window drops behind everything else and becomes your desktop background, with the video playing at the desktop level.

**Immersive mode** — syncs your Mac's wallpaper, dark mode, and accent color to the active theme. Your original wallpaper is always restored on quit, even after a crash.

**Interactive particles** — 25 styles, all reactive: particles flee, orbit, gust, or brighten near the cursor, and each has its own click response. Density and size are adjustable, and individual layers can be toggled per theme.

**Habit tracker** — side panels with daily habits, a completion ring, and a calendar heatmap. Toggle with one click.

| Habits on | Habits off |
|---|---|
| ![With habits](Screenshots/desktop-sakura-habits.jpg) | ![Without habits](Screenshots/desktop-sakura-nohabits.jpg) |

**Widget** — timer state on your desktop or in Notification Center, with start/pause/skip, kept in sync through a shared app group.

**Spotify bar** — now-playing with play/pause/skip, driven over AppleScript. No account or API key needed.

**Battery saver** — drops to 1080p video decode when unplugged.

## Themes

Each pairs a palette with its own particle system. Backgrounds here are live
video wallpapers from [moewalls.com](https://moewalls.com) — swap in anything
you like and Pomo builds the theme around it.

| | |
|---|---|
| ![Boreal Valley](Screenshots/desktop-irithyll.jpg) | ![Neon Sunset](Screenshots/desktop-synthwave.jpg) |
| **Boreal Valley** — snowfall | **Neon Sunset** — starfield |
| ![Event Horizon](Screenshots/desktop-blackhole.jpg) | ![Initial D](Screenshots/desktop-initiald.jpg) |
| **Event Horizon** — gravity well | **Initial D** — 3D rain |
| ![Autumn Shrine](Screenshots/desktop-autumn.jpg) | ![Swamp Spirit](Screenshots/desktop-swamp.jpg) |
| **Autumn Shrine** — falling leaves | **Swamp Spirit** — pond leaves |
| ![Mojave Night](Screenshots/desktop-desert.jpg) | ![Moonlit Meadow](Screenshots/desktop-meadow.jpg) |
| **Mojave Night** — sand drift, starfield | **Moonlit Meadow** — fireflies |
| ![Pixel City](Screenshots/desktop-pixelcity.jpg) | ![Sakura Moon](Screenshots/desktop-sakura.jpg) |
| **Pixel City** — 8-bit pixels, 3D rain | **Sakura Moon** — falling petals |

<details>
<summary><b>All 25 built-in themes</b></summary>

Available under **Built-in Presets** in the theme menu. Without a matching video, each renders a procedural background in its own palette.

| # | Theme | Particles |
|---|-------|-----------|
| 1 | 🌸 Sakura Moon | Sakura Petals |
| 2 | 🚗 Initial D | 3D Rain |
| 3 | 🐈‍⬛ Swamp Spirit | Pond Leaves & Ripples |
| 4 | ❄️ Boreal Valley | Snowfall |
| 5 | 🌕 Moonlit Meadow | Fireflies |
| 6 | 🌆 Neon Sunset | Starfield |
| 7 | 🏜️ Mojave Night | Sand Drift, Starfield |
| 8 | ⛩️ Autumn Shrine | Autumn Leaves |
| 9 | 🕳️ Event Horizon | Gravity Well |
| 10 | 🫧 Glass | Sand Drift |
| 11 | 🕹️ Pixel City | 8-bit Pixels, 3D Rain |
| 12 | 🔥 Campfire | Embers |
| 13 | 🌃 City Night | Bokeh Lights |
| 14 | 💎 Crystal Cave | Sparkle |
| 15 | 🎪 Carnival | Confetti |
| 16 | 🏔️ Misty Peaks | Smoke Wisps |
| 17 | 🌌 Northern Lights | Aurora, Starfield |
| 18 | 🏮 Lantern Festival | Lanterns |
| 19 | 🪶 Soft Clouds | Feathers |
| 20 | 🌧️ Rainy Window | Water Ripples, 3D Rain |
| 21 | ☄️ Meteor Shower | Comet Trails, Starfield |
| 22 | 🌫️ Deep Fog | Fog |
| 23 | 🔮 Sacred Geometry | Geometric |
| 24 | ⛈️ Thunderstorm | Lightning, 3D Rain |
| 25 | 🐋 Deep Ocean | Ripples & Fish, Sand Drift |

**Glass** is the odd one out — it shows your actual macOS wallpaper through a frosted-glass blur.

</details>

<details>
<summary><b>All 25 particle styles</b></summary>

| Style | Behaviour |
|-------|-----------|
| Sakura Petals | Pendulum-swaying blossoms that gust away from the cursor |
| Autumn Leaves | Tumbling leaves with spin and drift |
| 3D Rain | Parallax raindrops at several depths, with splat effects |
| Code Rain | Cascading glyph columns |
| Starfield | Twinkling points; stardust burst on click |
| Ripples & Fish | Schools of fish that flee the cursor; occasional shark |
| Snowfall | Swirling flakes that settle along the bottom edge |
| Fireflies | Glowing dots wandering on sine paths |
| Sand Drift | Dust motes carried on a slow wind |
| Gravity Well | Particles orbiting the cursor |
| 8-bit Pixels | Chunky retro sprites |
| Pond Leaves & Ripples | Floating lily pads with ambient rings |
| Embers | Rising sparks that flicker and fade |
| Bokeh Lights | Soft defocused discs, larger ones dimmer for depth |
| Sparkle | Brief bright flares |
| Confetti | Tumbling rectangles with spin |
| Smoke Wisps | Wisps that rise and expand |
| Aurora | Tall streaks swaying in waves |
| Lanterns | Paper lanterns drifting upward |
| Feathers | Slow side-to-side descent |
| Water Ripples | Expanding ambient rings |
| Comet Trails | Fast streaks with tapered tails |
| Fog | Large, slow, translucent haze |
| Geometric | Rotating polygons |
| Lightning | Periodic flashes with ambient motes |

</details>

---

## Project layout

```
App/
  PomoApp.swift          App entry, lifecycle
  ContentView.swift      Timer ring, controls, header
  SettingsView.swift     Settings, theme grid, FX controls
  AddThemeSheet.swift    Drop-a-video import flow
  ThemeEditorSheet.swift Per-theme colour and particle editing
  CustomThemeStore.swift User themes, persisted to themes.json
  ColorExtractor.swift   Palette extraction, content classification
  FXLayers.swift         Core Animation particle renderer (primary)
  InteractiveFX.swift    Canvas particle physics (fallback)
  ProceduralBackground.swift  Scene renderer when no video is present
  VideoBackground.swift  AVPlayerLooper, decode pooling
  ImmersiveMode.swift    Wallpaper, accent, dark-mode sync
  DesktopMode.swift      Desktop-level window, power monitoring
  Habits.swift / HabitTrackerView.swift
  Spotify.swift          AppleScript bridge
Shared/
  Theme.swift            Themes, particle styles, colour helpers
  TimerCore.swift        State shared with the widget
  PomoIntents.swift      Widget actions
Widget/
  PomoWidget.swift
project.yml              XcodeGen spec
```

Particles render through Core Animation — one `CALayer` per particle, composited on the GPU with no per-frame draw calls. Light-emitting styles composite additively so they read as glow rather than flat stickers. The SwiftUI `Canvas` path in `InteractiveFX.swift` holds the same physics as a fallback.

If you edit `project.yml`, regenerate with:

```bash
brew install xcodegen && xcodegen generate
```

---

## Permissions

- **Automation (System Events)** — to toggle dark mode in immersive mode
- **Screen Recording** — only for the Glass theme, which reads your wallpaper

Pomo makes no network requests. Nothing leaves your machine.

---

## Credits

Live wallpapers in the screenshots are from [moewalls.com](https://moewalls.com).
They are not redistributed here — Pomo ships with no video files, and you supply
your own.

Built with SwiftUI, WidgetKit, AVFoundation, and Core Animation.

---

## License

[MIT](LICENSE)
