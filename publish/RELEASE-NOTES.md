# Pomo 1.0

I made this because I wanted a pomodoro timer that was actually nice to look at
while I worked. Most of them are a circle and a number on a grey background, and
I kept not using them.

Pomo plays a video as the background and puts the timer over it, with particle
effects layered on top. Petals, snow, embers, fireflies, rain, that sort of
thing. They react to your cursor, so the petals gust away when you move through
them and the fireflies drift around it.

The part I am most happy with is the theming. You drop in any video and Pomo
reads the colors out of it and builds the whole theme around it, the ring, the
accent, the background gradient. It figures out the color by looking for the
light in the scene rather than whatever covers the most pixels, so a moonlit
field gives you the pale yellow of the moon even though most of the frame is
blue. Then it looks at what is actually in the video to pick the particles. A
field at night gets fireflies, a city gets pixels, a shot of blossoms gets
petals. That took me a lot of tries to get right and I am glad it finally works.

There is a habit tracker in the side panels if you want one, with a completion
ring and a calendar heatmap. There is a widget for your desktop or notification
center, and a Spotify bar for skipping tracks without leaving the timer. And
there is a desktop mode where the window drops behind everything else and just
becomes your wallpaper while it runs.

The videos are not included. I get mine from moewalls.com. Pomo comes with 25
built in themes that draw their own backgrounds, so it works fine with no videos
at all, and adding one is a couple of clicks.

## Before you download

I do not have a paid Apple developer account, so the app is not notarized and
macOS will block it the first time you open it. You will get a warning saying it
cannot verify the app is free of malware, and there is no Open button on it, so
it looks like a dead end. Nothing is wrong with it. Run this once:

```
xattr -dr com.apple.quarantine /Applications/Pomo.app
```

After that it opens normally and everything works. You can also build it from
source, which skips the warning entirely since the warning only applies to
things downloaded from a browser.

Requires macOS 14 or later.

This is the first thing I have put out like this, so if something breaks or
feels off, please open an issue and tell me.
