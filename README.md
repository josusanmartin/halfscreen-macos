# HalfScreen

A small Mac app for the Samsung U28E590 in picture by picture mode. It selects the monitor's 1920 × 2160 physical signal and offers:

- Large text: 960 × 1080 HiDPI, using a mode macOS already has.
- More space: 1920 × 2160 native.
- Custom logical sizes: an 8:9 HiDPI virtual display mirrored onto the U28E590. The app must stay open for a custom size.

Build with Xcode command line tools on macOS, then run:

```sh
make
make install
open /Applications/HalfScreen.app
```

The app has no account, payment, trial, or network dependency. It lives in the top menu bar without a Dock icon; choose **Show HalfScreen** from that menu to reopen its window. Choose **Open HalfScreen at login** if you want the controls available after login; then apply your preferred custom size. Closing the window leaves the app in the menu bar; quitting removes the virtual display and restores the large built-in mode. While it runs, the app restores a custom size if the U28E590 briefly disconnects and reconnects.

Custom logical sizes can be 640–1920 pixels wide and 600–2160 pixels high. The 8:9 option fills the half monitor. Other shapes may show bars.

Custom sizes use undocumented macOS `CGVirtualDisplay` and CGS display-mode APIs. They may need adjustment after a macOS update. A monitor cannot accept arbitrary physical timings: HalfScreen keeps the U28E590 on its advertised 1920 × 2160 timing and varies the logical desktop size. This version was tested on macOS 26.5.2 with an M3 Max.

The app identifies the U28E590 by Samsung vendor and model IDs, so it will not change the other Samsung display.

Run `/Applications/HalfScreen.app/Contents/MacOS/HalfScreen --status` to inspect the current logical and physical mode. `--large` and `--native` switch directly between the two physical-display presets without opening the app.

Third-party acknowledgments are in [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md).
