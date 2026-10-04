# HalfScreen

A small Mac app for the Samsung U28E590. Its top-bar **Half / Full** toggle matches the monitor's picture by picture and normal modes:

- Half mode: 1920 × 2160 physical output, with 960 × 1080 HiDPI or 1920 × 2160 native desktop sizes.
- Full mode: 3840 × 2160 physical output, with 1920 × 1080 HiDPI or 3840 × 2160 native desktop sizes.
- Custom logical sizes in Half mode: an 8:9 HiDPI virtual display mirrored onto the U28E590. The app must stay open for a custom size.
- A brightness slider in the app window and top menu. It places a transparent dimmer over the Mac's image, so it does not change the monitor's backlight or the other computer's signal.

Switch the monitor's own PBP setting, then choose **Half** or **Full** in HalfScreen. If the matching resolution is not yet advertised by macOS, HalfScreen waits and applies it after the display reconnects. It does not try to turn the monitor's PBP setting on or off.

The U28E590 did not respond to DDC brightness reads in the tested split-screen setup, so this brightness control is visual dimming only. Quitting HalfScreen removes the dimmer.

Build with Xcode command line tools on macOS, then run:

```sh
make
make install
open /Applications/HalfScreen.app
```

The app has no account, payment, trial, or network dependency. It lives in the top menu bar without a Dock icon; choose **Show HalfScreen** from that menu to reopen its window. Choose **Open HalfScreen at login** if you want the controls available after login; then apply your preferred custom size. Closing the window leaves the app in the menu bar; quitting removes the virtual display and restores the large built-in mode. While it runs, the app restores a custom size if the U28E590 briefly disconnects and reconnects.

Custom logical sizes can be 640–1920 pixels wide and 600–2160 pixels high. The 8:9 option fills the half monitor. Other shapes may show bars.

Custom sizes use undocumented macOS `CGVirtualDisplay` and CGS display-mode APIs. They may need adjustment after a macOS update. A monitor cannot accept arbitrary physical timings: HalfScreen uses the U28E590's advertised 1920 × 2160 or 3840 × 2160 timing and varies the logical desktop size. This version was tested on macOS 26.5.2 with an M3 Max.

The app identifies the U28E590 by Samsung vendor and model IDs, so it will not change the other Samsung display.

Run `/Applications/HalfScreen.app/Contents/MacOS/HalfScreen --status` to inspect the current logical and physical mode. With the app running, `--layout half` or `--layout full` selects a monitor layout and `--brightness 80` sets 80% visual brightness; valid brightness values are 20–100. `--large` and `--native` switch directly between the selected layout's two display presets without opening the app.

Third-party acknowledgments are in [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md).
