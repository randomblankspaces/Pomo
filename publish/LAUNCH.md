# Launch checklist

Everything needed to put Pomo in front of people, in the order worth doing it.

---

## 1. Topics (2 minutes, do first)

Repo page → the gear icon next to **About** → Topics. Paste:

```
macos swift swiftui pomodoro pomodoro-timer productivity widgetkit particles focus macos-app wallpaper live-wallpaper
```

Topics are how GitHub search and the topic pages surface a repo. An empty
topics list means the only way to find Pomo is a direct link.

---

## 2. Demo GIF (highest value, do before posting anywhere)

Static screenshots sell almost none of what Pomo does. The petals gusting away
from the cursor, the ring pulsing, the video moving behind it — none of that
survives a still frame. One short loop at the top of the README will do more
than everything else on this page.

**Recording it:**

1. Open Pomo in a normal window (press `⌘D` if it's in desktop mode, so it
   comes forward instead of sitting on the desktop).
2. Pick a theme with obvious motion. Sakura Moon is the best one for this —
   the petals read instantly. Neon Sunset and Autumn Shrine also work.
3. Press `⌘⇧5`, choose **Record Selected Portion**, drag a box around just the
   Pomo window, and record for about ten seconds. Move your cursor slowly
   through the particles while recording so the interaction is visible.
4. Stop, and the `.mov` lands on your Desktop.

**Converting to GIF.** Simplest is [Gifski](https://gif.ski) (free, Mac App
Store) — drop the `.mov` in, set width to about 900px and quality around 80,
export. Aim for **under 10 MB**; if it's larger, shorten the clip rather than
dropping quality, since a choppy GIF looks worse than a short one.

**Adding it.** Save as `Screenshots/demo.gif`, then in `README.md` put this
directly under the `# Pomo` heading and description, above the existing
screenshot:

```markdown
![Pomo demo](Screenshots/demo.gif)
```

Then commit and push:

```bash
git add Screenshots/demo.gif README.md
git commit -m "Add demo GIF"
git push
```

---

## 3. Cut the v1.0 release (5 minutes)

Repo page → **Releases** → **Create a new release**.

- **Tag:** `v1.0` (choose "Create new tag on publish")
- **Title:** `Pomo 1.0`
- **Description:** paste the contents of `publish/RELEASE-NOTES.md`
- **Attach:** drag `publish/Pomo-1.0.dmg` into the binaries box

Releases get their own page, a download counter, and a permanent link. It's
also the first place people look for a Mac app, ahead of browsing the file
tree.

---

## 4. Where to post

Space these out over a couple of weeks rather than the same day. Reply to
comments in the first few hours — early engagement decides whether a post
travels.

**r/macapps** is the best fit by a wide margin. Free, open source, and visually
striking is exactly what that audience upvotes. Draft below.

**Hacker News**, as a Show HN. Write it around the colour-extraction problem
rather than the timer; that crowd engages with the engineering, not the
category. Draft below.

**r/productivity** and **r/pomodoro** are worth a follow-up post later, using a
trimmed version of the Reddit draft.

**awesome-mac** ([sindresorhus/awesome-mac](https://github.com/jaywcjlove/awesome-mac))
takes pull requests. Slow, but it keeps sending people your way for years.

---

## Draft: r/macapps

**Title:** I made a pomodoro timer that builds its whole theme from any video you drop in (free, open source)

**Body:**

I kept not using pomodoro timers because they are all a circle and a number on
a grey background, and I wanted something I would actually enjoy having open. So
I made Pomo.

It plays a video as the background with the timer over it, and layers particle
effects on top, petals, snow, embers, fireflies, rain. They react to your
cursor, so the petals gust away when you move through them.

The part I am happiest with is the theming. You drop in any video and it reads
the colours out of it and builds the whole theme, the ring, the accent, the
background. It looks for the light in the scene rather than whatever covers the
most pixels, so a moonlit field gives you the pale yellow of the moon even
though most of the frame is blue. Then it looks at what is actually in the video
to pick the particles, so a field at night gets fireflies and a city gets
pixels. That took me a lot of tries and I am glad it finally works.

There is also a habit tracker, a widget, a Spotify bar, and a desktop mode where
the window drops behind everything and becomes your wallpaper.

The videos are not included, I get mine from moewalls.com. It comes with 25
built in themes that draw their own backgrounds so it works fine without any.

One heads up before you download. I do not have a paid Apple developer account,
so it is not notarized and macOS will block it the first time with a warning
about not being able to verify it. Nothing is wrong with it, you just run
`xattr -dr com.apple.quarantine /Applications/Pomo.app` once and it opens
normally after that. Or build it from source, which skips the warning.

This is the first thing I have really put out, so any feedback is welcome.

---

## Draft: Show HN

**Title:** Show HN: Pomo – a macOS pomodoro timer that generates its theme from your video

**Comment:**

I built this because I wanted a timer that was nice to look at, but the part
that turned out to be interesting was picking the colours.

The obvious approach is to cluster the pixels and take the biggest cluster. That
gives you the wrong answer almost every time, because the largest region is
usually a wall, the sky, or the ground. A moonlit field came out teal, since the
clouds and grass dominate the frame, when the colour the scene actually reads as
is the pale yellow of the moon at about two percent of the pixels.

What works is building a histogram over hue, taking every local peak instead of
just the tallest, and then choosing between peaks by how much each one looks
like a light source rather than by how much area it covers. Small and bright
beats large and dull. I also moved off k-means because it kept landing in
different local minima, so the same video could produce a different theme on
different imports.

Colour still cannot tell a black hole from a campfire, so the particle effects
come from the macOS scene classifier instead. Blossom gives petals, sand dune
gives drifting sand, cityscape gives pixels.

I checked it against 25 themes I had previously hand tuned, and it now picks the
same particle effect on all of the ones I had reference videos for, with the
ring hues landing within about 0.04.

It is free and MIT licensed. Not notarized, since I do not have a paid Apple
account, so there is a one-time quarantine command in the readme.

---

## What to expect

Most projects sit in single digits for a long time, including good ones. Stars
follow one post that happens to land rather than steady effort, so the thing
worth optimising is the demo GIF and the first paragraph of the post, not
volume. The work itself is already done.
