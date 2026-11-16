# Bifrost Link

A native macOS app for docking an AYN Thor to a Mac. It does the following:
- mirrors both screens in one window
- passes keyboard, mouse, trackpad and controllers through
- gives each screen its own volume
- includes a file browser with storage analysis
- takes screenshots, records and keeps an instant replay
- keeps the Thor running, with both of its screens dark, while it's docked

Everything runs locally over USB (adb). Nothing is uploaded anywhere.

## Build & install

```sh
./scripts/build-app.sh            # builds build/Bifrost Link.app
./scripts/build-app.sh --install  # also copies it to /Applications
```

Requirements:
- Xcode Command Line Tools (Swift 5.9+)
- adb (`brew install android-platform-tools` or the Android command-line tools)
- to rebuild the device server: JDK 17 and the Android build tools / platform 36 (in `/opt/homebrew/share/android-commandlinetools`)

The build bundles `adb`, the patched server and the icon (`Resources/logo.png`) into the app. On launch the app prefers a system adb if one is installed.

## Releases

Every push to `main` builds a release on GitHub (`.github/workflows/release.yml`):
1. A macOS runner installs the tools Bifrost bundles (`chdman` from Homebrew's `rom-tools`, plus `adb` and `aapt2` from the Android SDK), then runs `./scripts/build-app.sh --dmg`.
2. The version is the base in `VERSION` plus the workflow run number, for example `1.0.12`. Edit `VERSION` for a bigger jump.
3. The release notes list every commit since the previous release tag.
4. The `Bifrost-Link-<version>.dmg` is published as release `v<version>`.

Pushes that only touch Markdown files or `.gitignore` don't create a release. Releases can also be started by hand from the Actions tab.

The app is ad-hoc signed, not notarized, so on another Mac it has to be opened once with right-click ▸ Open. The release notes say so. The build is Apple silicon only. The server jar (`Resources/bifrost-server.jar`) is used as committed, so run `./server/build.sh` and commit the jar after changing `server/bifrost.patch`.

To build the disk image locally: `BIFROST_VERSION=1.0.0 ./scripts/build-app.sh --dmg`.

## Using it

Plug the Thor in with USB debugging on. Bifrost links automatically.

### Screens & window

| Action | How |
| --- | --- |
| Layouts | Toolbar picker, or ⌘1 Stacked · ⌘2 Side by Side · ⌘3 Picture in Picture · ⌘4 Top Only · ⌘5 Bottom Only |
| Swap screens | ⌘0 or the ⇅ button |
| Picture in picture | ⌘-drag the small screen anywhere to move it; ⌘-drag one of its corners to resize it. ⌥⌘+ / ⌥⌘− also resize it, and View Layout ▸ Overlay Opacity sets its opacity |
| Full screen | ⌘F (enter and leave) or the toolbar button: black background, edge to edge, no toolbar |
| Cinema mode | ⌥⌘C: a soft glow of each screen's live colors in a dark room, like YouTube's ambient mode |
| MetalFX upscaling | ⌥⌘U: upscales the picture to the window's real pixel size (on by default) |
| Stats overlay | ⌥⌘I: fps, bitrate, decode→display latency, codec/resolution and audio buffer per screen |
| Fit window | ⌥⌘0 resizes the window to the layout's proportions. It never happens automatically |

### Input

| Action | How |
| --- | --- |
| Touch | Click / drag. Trackpad pinch = two-finger zoom |
| Back / Home / Recents | Right click / middle click, toolbar buttons, ⌘⌫ / ⇧⌘H / ⇧⌘A |
| Keyboard | Goes to the screen you clicked last. Your Mac keyboard layout is respected |
| Clipboard | ⌘C copies from the Thor, ⌘V pastes into it |
| Game controllers | Controllers connected to the Mac appear on the Thor as an **Odin Controller** by default, the same identity as the Thor's built-in controls, so existing app mappings just work. Face buttons follow the Odin's Nintendo layout: A and B as well as X and Y are swapped, so the button in the same position does the same thing. Settings ▸ Input can switch to Xbox Wireless Controller, which adds rumble on the Mac controller |
| Drop files on a screen | Sends them to `/sdcard/Download`; `.apk` files get installed |

### Capture

Folders are set in Settings ▸ Capture. Each has Choose…, Open in Finder and Reset.

| Action | How |
| --- | --- |
| Screenshot | ⇧⌘S: one PNG per visible screen. A single screenshot is also copied to the clipboard |
| Record | ⇧⌘R. The menu on the record button chooses the mode: **Separate screens** writes one `.mov` per screen with the Thor's original H.265 stream (no re-encoding). **Window layout** writes one HEVC video of both screens as arranged in the window (60 fps, up to 2560 px) |
| Instant replay | Turn it on in Settings ▸ Capture and choose 30 s, 1 min or 2 min. ⌥⌘S saves the last moments of each screen with audio. It needs about 2 MB/s per screen of memory and asks the Thor for a keyframe every 2 s, which applies from the next link |

### Files, Library, Saves, Cleanup

⇧⌘F opens the inspector with four tabs.

**Files.** Each running transfer has a cancel button; partial files are removed.
- **Storage:** cards for Internal and SD card with free space (click a card to open it).
- **Navigation:** quick places and breadcrumbs.
- **Transfers:** upload with the button or by dragging from Finder; download with the button, a double-click or the context menu, all with progress.
- **Managing files:** rename, new folder, delete.
- **Sizes** (chart button): measures the current folder and sorts it biggest first, with bars (cached).
- **Largest files** (magnifier button): the 100 largest files on the current storage, ready to reveal, download or delete.

**Library.**
- **Import ROMs:** drop files or choose them. The picker lists the systems that have a `Roms/<system>` folder on your Thor (SD or internal), and the file goes into that folder. The most likely system is preselected from the file type and disc header; for CHD and ISO images Bifrost reads the disc header (with the bundled `chdman` for CHD), so a PSP CHD isn't mistaken for PS1.
- **App updates:** sideloaded apps are checked against GitHub releases. ARMSX2 is preset; add `owner/repo` for any other app. Downloads are verified with the bundled `aapt2` (the package name must match) before `adb install -r` keeps your data.
- **Stray ROMs** outside `Roms/` can be moved in place.
- **Space by system:** bar chart; click a system to open its folder.
- **BIOS check:** shows which systems have their BIOS.
- **Leftover artwork:** Cocoon images and gamelist entries for games no longer on the Thor. An image is kept if Cocoon still references it, or if its name matches a ROM after removing edit or copy suffixes, region tags or disc numbers. `multi_disc_roms` counts as well. Gamelists are backed up to the Mac before entries are removed.
- **Shrink disc images:** PS1, PS2, PSP, Dreamcast and Saturn images (ISO, CUE/BIN, GDI, also in subfolders) are listed with checkboxes. Select some or all and shrink them in one go. Each game is copied to the Mac, converted to CHD with the bundled `chdman`, verified, sent back and size-checked, with progress and a Cancel button. Multi-track games are read from their cue/gdi sheet, so all tracks travel together. Games that already have a CHD next to them are skipped. Originals stay until you remove them in one confirmation at the end, or automatically if you tick "Remove originals automatically". When an original is removed, `.m3u` playlists in the same folder and the Cocoon gamelist entry are pointed at the new `.chd` (the gamelist is backed up first). Failed games are skipped without stopping the batch, and the batch stops early if the Mac runs low on space.

**Saves.**
- Snapshots of all emulator saves and states, automatically once a day on link, or manually.
- Restore per emulator.
- Emulators that store saves privately (DuckStation) can't be read over USB; Bifrost says so instead of creating empty backups.

**Cleanup.**
- Caches, dumps, logs, per-game states and saves, measured per emulator.
- Per-game items are backed up before removal; mods and texture packs are never offered.

### Audio

Muting Bifrost also sets the Thor's media volume to 0, so apps that can't be captured stay quiet too. The previous volume comes back when you unmute or unlink, even after an unplug.

The audio popover has three sliders:
- **Both Screens:** the master volume. It also covers background audio.
- **Top Screen** and **Bottom Screen:** only the apps currently visible on that screen.

Every two seconds Bifrost checks which app is in front on each screen and captures audio per app. When an app comes to the front, the new capture starts before the old one stops. Each new capture also "kicks" Android's audio routing for 250 ms, so audio that was already playing moves over immediately. On every check Bifrost also looks for capturable audio that is still playing on the Thor's speaker (for example right after an emulator restarts its audio) and pulls it back to the Mac. Captured audio is recorded at full fixed volume, so the Thor's own volume never affects what you hear on the Mac; only the sliders do.

An app that spans both screens counts as Top. Apps that opt out of audio capture (often older games and emulators) stay on the Thor in this mode. For those, turn off **Separate audio per screen**: Bifrost then captures the whole device output, which works with every app.

### Docking: lid, power button, screens, charging

Settings ▸ Docking:
- **Both screens dark while linked.** It works exactly the way AYN does it for USB-C→HDMI output: both panels' backlight power (`bl_power`) is switched off through AYN's own `PServerBinder` system service. Android keeps rendering, so mirroring continues. "Turn the Thor's screens off as soon as it links" and the toolbar button (⇧⌘P) control this.
- **Closing the lid** makes Android sleep. Bifrost wakes it within about 350 ms, dismisses the keyguard and keeps the screens dark.
- **Opening the lid** turns the screens back on.
- **Pressing power** toggles the Thor's screens instead of disconnecting.
- **Charging separation while linked:** the Thor runs straight from USB power and doesn't charge its battery. Your previous setting comes back on unlink or unplug.
- **Unlinking or unplugging** turns both screens back on. This step runs on the Thor itself inside the mirroring server's cleanup, so it also works when the cable is pulled or the Mac app is closed abruptly. If the lid is closed, the Thor goes back to sleep.
- **Pause Sleep Manager while linked** (optional). Sleep Manager's closed-lid protection would lock the Thor and switch Wi-Fi off while docked.
  - **On link:** Bifrost remembers your usual Wi-Fi/Bluetooth state, taken with the lid open, and keeps it while docked.
  - **On unlink or unplug:** the server cleanup restores those radios and restarts Sleep Manager. It uses a temporary FGS exemption (`cmd deviceidle tempwhitelist`), because Android 12+ blocks starting it from a background broadcast.

Nothing stays installed on the Thor. The temporary server lives in `/data/local/tmp` only while linked and is deleted on unlink.

## How it works

```
Mac (Swift / SwiftUI / AppKit / Metal)              Thor (Android 13)
┌──────────────────────────────┐   adb forward    ┌────────────────────────────────────┐
│ ScreenController (top)       │◀── video+ctrl ──▶│ bifrost-server  display_id=0       │
│ ScreenController (bottom)    │◀── video+ctrl ──▶│ bifrost-server  display_id=4       │
│ AudioRouter ── top           │◀── raw PCM ──────│ bifrost-server  audio_uids=<top>   │
│             ── bottom        │◀── raw PCM ──────│ bifrost-server  audio_uids=<bottom>│
│             ── background    │◀── raw PCM ──────│ bifrost-server  exclude those uids │
│ PowerGuard                   │◀── getevent ─────│ hall_switch / pmic_pwrkey          │
│ FileService                  │─── adb push/pull │                                    │
└──────────────────────────────┘                  └────────────────────────────────────┘
```

- **Device server.** It's based on [scrcpy](https://github.com/Genymobile/scrcpy) v4.1's server (Apache 2.0) plus `server/bifrost.patch`. `server/build.sh` fetches the v4.1 tag read-only, applies the patch and builds `Resources/bifrost-server.jar`. The patch adds:
  - `audio_uids` / `audio_exclude_uids`: per-app playback-capture rules, also covering `USAGE_GAME` and `USAGE_UNKNOWN`.
  - `audio_kick`: the routing kick described under Audio.
  - `charging_separation`: set while linked and restored by the cleanup step.
  - Display power via AYN's `PServerBinder` (`bl_power` for both panels) when that service exists; standard scrcpy behavior otherwise.
  - A cleanup step that restores display power whether the Thor is awake or asleep, and puts it to sleep if the lid is closed.
  - Virtual gamepads with the Xbox One S Bluetooth ID (`045e:02fd`) register on the Bluetooth bus, so the kernel's `hid-microsoft` force-feedback driver attaches.
- **Client.**
  - **Protocol:** speaks the scrcpy 4.x protocol itself (`Core/`).
  - **Video:** decodes H.265/H.264 with VideoToolbox and renders through its own Metal pipeline (`Screen/MetalRenderer.swift`): YCbCr→RGB, optional MetalFX spatial upscaling, presentation.
  - **Audio:** 48 kHz PCM through `AVAudioEngine`, with one mixer per channel and a shared tap for recording and replay.
  - **Control:** touch, scroll, key, text, clipboard, display-power and UHID gamepad messages over the control socket. The Thor sends rumble back as UHID output report 0x03, which Core Haptics plays on the Mac controller.
- **Recording.**
  - **Separate screens:** passthrough writing of the compressed stream (`Capture/Recorder.swift`).
  - **Window layout:** a 60 fps Metal composite using the same `StageLayout` as the window (`Capture/LayoutRecorder.swift`).
  - **Instant replay:** a ring buffer of compressed samples and audio (`Capture/ReplayBuffer.swift`), written pull-based when saved (`Capture/ReplayWriter.swift`).
- **Hidden capture.** The screens are captured through `SurfaceControl.createDisplay` instead of a `DisplayManager` virtual display, so apps never see an extra "presentation" display. Before this, PPSSPP treated the mirror as a TV and moved its picture to the bottom screen.
- **Performance.** While linked, the aurora background is static. Cinema mode only resamples when a new frame arrives, and one poll of the foreground apps serves both audio routing and Now Playing. Bifrost never changes the Mac's display refresh rate, but the mirror can't show more frames than the Thor sends (60 fps).
- **Server jar.** Sessions with `cleanup=true` delete their own jar on start, so each video session runs from its own copy and the shared `/data/local/tmp/bifrost-server.jar` stays for the audio sessions.

## Project layout

```
Package.swift
Sources/BifrostLink/
  App/      BifrostApp (menus, shortcuts), DeviceManager (link lifecycle, capture, replay, stats), LinkSettings, Log
  Core/     ADB, Socket, ServerSession, ControlChannel, VideoStream, AudioOutput, AudioRouter, PowerGuard
  Screen/   ScreenView (input), ScreenController, MetalRenderer
  Input/    KeyMap, GamepadBridge (Xbox descriptor, rumble)
  Capture/  Recorder, LayoutRecorder, ReplayBuffer, ReplayWriter, ScreenStats
  Files/    FileService
  UI/       ContentView, StageView, StageLayout, AudioPanel, FileBrowserView, WelcomeView, SettingsView, WindowObserver, Theme
server/     bifrost.patch, build.sh
scripts/    build-app.sh
Resources/  bifrost-server.jar, logo.png, AppIcon.icns (generated)
```

## Troubleshooting

- **"Allow USB debugging":** confirm the prompt on the Thor and tick "Always allow".
- **Nothing shows up:** run `adb devices`. If another adb version owns the server, run `adb kill-server` and relaunch.
- **No audio on the Mac for a certain app:** it probably opts out of capture. Turn off "Separate audio per screen".
- **Video settings** (codec, bitrate, fps, resolution) apply on the next link. Use Device ▸ Relink to apply them now.
- **Logs:** link, unlink, recording and gamepad events go to `~/Library/Logs/Bifrost Link/bifrost.log`.
- **Cocoon integration:** Now Playing reads the last launch in `Cocoon_Data/launch_debug.log`, also for players with extra labels such as `ARMSX2 (Refresh)`. Games on either screen count, so PPSSPP, which draws on the bottom screen when its "External display" option is on, gets layouts too. Per-game and per-system layouts live in the layout menu next to the layout picker.
- **Per-app layouts:** any other app or Android game in front shows up in the same menu as "Remember Layout for This App". Apps without a saved layout use your normal layout.
- **Latency:** the Thor's encoder runs with real-time priority and minimal frame buffering, the Mac keeps at most two frames queued for display and about 80 ms of audio.
- **Development:** start the app binary with `BIFROST_DEBUG=1`. That logs audio levels and per-screen stats once a second, and accepts commands as distributed notifications named `eu.nicekaleido.bifrostlink.command` (`saveReplay`, `toggleRecording`, `recordLayout`, `recordSeparate`, `layoutStacked`, `layoutSideBySide`, `screenshot`).
