# Clarity

A small Mac app that makes an external monitor show everything bigger **and keeps text sharp**, and gives that monitor its own colour controls. It was built for a Philips 346B1C (3440 × 1440) on an M5 MacBook, but works with any external monitor. It needs no admin rights.

## Using it

Open Clarity and its window appears. Close the window once you're set up: Clarity keeps running in the background with no Dock icon, and your monitor stays scaled. To change something later, open Clarity again (Spotlight, Finder or Launchpad) and the window comes back. When it starts at login, it applies your settings without opening the window.

If you'd rather reach it from the menu bar, turn on **Menu bar icon** at the bottom of the window (off by default).

**Size**
- Drag the slider or pick a preset. 120% means everything is 20% bigger. On the Philips that "looks like" 2866 × 1200. The change is saved straight away.
- **Native** shows the panel 1:1, without scaling.
- Windows and desktops stay on the monitor when you change size (see below).

**Colour** (affects only that monitor, never the MacBook screen)
- **Warmth**: 10% warmer is about 5900 K. *Evening* is 30% warmer.
- **Brightness**, **Contrast**, **Gamma**: 2.2 is neutral. Higher values make midtones darker and punchier.
- **White balance**: separate red, green and blue gains for fine-tuning.

**Other**
- **Open at login** starts Clarity automatically. Your settings are re-applied whenever the monitor is plugged in.
- **Turn everything off** resets that display to native size with neutral colours.
- **Quitting Clarity always returns the monitor to normal.** Closing the window doesn't quit it; use **Quit Clarity** (⌘Q). If anything ever looks wrong, quit the app (or use Activity Monitor).

## How the sharp scaling works

Normally, picking a smaller "looks like" resolution makes macOS draw at that small size and **stretch** the image onto the panel, which blurs text.

Clarity does what BetterDisplay does instead:

1. It creates an invisible **virtual display** in HiDPI ("Retina") mode at the size you chose. HiDPI means macOS draws it at **twice** the pixels, so 2866 × 1200 is drawn at 5732 × 2400.
2. It makes the real monitor **mirror** that virtual display. macOS **shrinks** the 5732 × 2400 image down to the panel's 3440 × 1440. Shrinking a detailed image (supersampling) looks crisp, while stretching a small one looks soft.

### Keeping windows and desktops in place

To macOS, swapping the real monitor for the virtual one looks like unplugging one screen and plugging in another, which moves windows and Spaces (desktops) to the MacBook. Clarity avoids this in two ways:

- **The swap happens once.** Every size, including Native (1:1), is a mode of the same virtual display, so changing size afterwards is an ordinary resolution change, and windows and desktops stay where they are.
- **Each monitor's virtual display always has the same identity.** macOS stores each display's desktops under an ID made from the display's vendor, product and serial number. Clarity gives each monitor a serial number the first time it's scaled (the Philips is 1) and never changes it, so at every launch macOS recognises the display and brings back its desktops. Three-finger swiping between desktops on the monitor depends on this. When the identity changed during development, the monitor came back with a single empty desktop and there was nothing to swipe to.

### Main display and swiping between desktops

While a monitor is scaled, Clarity makes it the **main display** (switch: *Main display while scaled*, on by default). Without this, a three-finger swipe with the pointer on the scaled monitor switches the MacBook's desktops instead. The Dock works out which screen a swipe is on from the physical monitor under the pointer, finds that it has no desktops of its own (they belong to the virtual display it mirrors), and falls back to the main display. With the scaled monitor as main, that fallback lands on the right screen, and swipes on the MacBook still work normally.

macOS keeps the main display's desktops as one set that follows whichever screen is main. So the first time this takes effect, desktops can swap screens. Drag them to where you want them in Mission Control once.

### Screen arrangement

macOS re-lays out the screens whenever a display changes resolution, which can undo a vertical stack. Before every size change, Clarity records where each other screen sits relative to the scaled monitor (which edge, and how far along it) and rebuilds the same layout at the new size. When scaling starts, the layout you set for the real monitor in System Settings is carried over to the virtual one.

The one time windows do move is when Clarity starts or quits, which is when the swap happens. With **Open at login** on, that's at login, before most windows are open.

The virtual display belongs to the Clarity process, so if Clarity quits or crashes, macOS removes it and the monitor goes straight back to normal.

It uses `CGVirtualDisplay`, a **private** macOS API with no public documentation. Its declarations are in `Support/CGVirtualDisplay.h`. A future macOS update could change it. If scaling stops working after an update, that's the likely cause.

## How the colour works

Every display has **gamma tables**: three lookup tables (red, green, blue) that the graphics hardware uses to convert each brightness value before it reaches the screen. Clarity rewrites the Philips's tables (`CGSetDisplayTransferByTable`). For example, warmer means the blue and green tables top out a little lower. macOS sometimes resets these tables (after sleep or a display change), so Clarity checks every 3 seconds and puts its tables back if needed.

These are software adjustments. They can only dim channels, never make the panel brighter or more saturated than it physically is. The monitor's own OSD settings still apply underneath.

## Building

You need Xcode (or its command line tools). Nothing else.

```bash
./build.sh            # builds build/Clarity.app
./build.sh --install  # builds, then copies it to ~/Applications (quits a running copy first)
```

Self-test, for checking that scaling and colour still work, for example after a macOS update. **Quit Clarity first**: the test uses the same virtual display identity, and macOS won't create two. It scales the first external monitor to 120% with 10% warmth, switches to Native, 133% and back while checking it stays the same display, then reverts:

```bash
build/Clarity.app/Contents/MacOS/Clarity --selftest 1.2 5
```

## Files

| File | What it does |
| --- | --- |
| `Sources/ScalingEngine.swift` | Virtual display and mirroring (the sharp scaling) |
| `Sources/ColorEngine.swift` | Gamma-table maths: temperature, brightness, contrast, gamma, RGB |
| `Sources/Displays.swift` | Finds external monitors and their native resolution |
| `Sources/Arrangement.swift` | Records and restores where the screens sit around the scaled monitor |
| `Sources/AppModel.swift` | Saved settings, display plug/unplug, sleep/wake |
| `Sources/ClarityApp.swift` | The window, the optional menu bar icon, running in the background |
| `Sources/MenuView.swift` | The panel shown in the window and the menu bar |
| `Sources/SelfTest.swift` | The `--selftest` mode |
| `Support/` | Private API header and `Info.plist` |

## Known limits

- The scaled monitor runs at 60 Hz, the virtual display's refresh rate. The Philips is already at 60 Hz, so nothing is lost there.
- Settings are saved per monitor (by vendor, model and serial number), so a different monitor starts at native size.
- HiDPI rendering gives the GPU more pixels to draw (5732 × 2400 instead of 3440 × 1440). The M5 handles this easily.

## Licence

MIT. See [LICENSE](LICENSE).
