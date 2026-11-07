# NoNotch

Menu bar app that hides the MacBook notch by adding a black band to the top of your wallpaper, so the menu bar reads as solid black. A replacement for TopNotch, which broke on macOS 27 (it looks for wallpaper windows owned by the Dock, and macOS 27 moved them to WindowManager/WallpaperAgent).

It uses only public `NSWorkspace` wallpaper APIs. On every Space switch, wake, display change, and a 2-second poll, it checks each notched screen's wallpaper and swaps in a rendered copy if needed. Renders are cached in `~/Library/Application Support/NoNotch/rendered`.

## Build

```sh
./build.sh            # builds build/NoNotch.app
./build.sh --install  # also copies to /Applications and launches it
```

## Behavior

- **Hide Notch** off: restores the original wallpaper on each Space as you visit it.
- **Quit**: rendered wallpapers stay in place; new wallpapers aren't processed until it runs again.
- Dynamic (time-of-day) image files become a static image of their primary frame.
- Aerials and other live system wallpapers can't be re-rendered, so NoNotch draws a black strip window just above the wallpaper instead. With "Automatically hide menu bar" on, the revealed menu bar is drawn with an opaque background tinted from the Aerial. Turn off System Settings → Menu Bar → "Show menu bar background" (`SLSMenuBarUseBlurredAppearance`) so it shows the black strip instead.
- Registers itself as a login item on first launch (toggle in the menu).
