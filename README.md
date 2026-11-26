# Bifrost Link

**Dock your AYN Thor to your Mac.** Plug the Thor in with a USB cable and both of its screens show up in a window on your Mac. Play with your Mac's keyboard, mouse or any controller, hear the sound through your Mac, and keep using the Thor's own apps, emulators and launcher as if it were a small console under your desk.

While it's docked, Bifrost also helps you look after your Thor:
- copy files back and forth
- sort new games into the right folders
- back up your saves
- clean up space
- install and update native game ports

Everything happens directly over the USB cable. Nothing is uploaded anywhere, and nothing stays installed on your Thor.

---

## Contents

1. [What you need](#what-you-need)
2. [Install](#install)
3. [Your first link](#your-first-link)
4. [The window](#the-window)
5. [Playing](#playing): keyboard, mouse, controllers
6. [Sound](#sound)
7. [Screenshots, recordings and clips](#screenshots-recordings-and-clips)
8. [The side panel](#the-side-panel): Files, Apps, Library, Saves, Cleanup
9. [Ports](#ports): native games for your Thor
10. [Play Time](#play-time)
11. [Performance](#performance): live frame rate, load and temperatures
12. [Docking: lid, screens, power and charging](#docking-lid-screens-power-and-charging)
13. [Menu bar, login and updates](#menu-bar-login-and-updates)
14. [Settings at a glance](#settings-at-a-glance)
15. [Keyboard shortcuts](#keyboard-shortcuts)
16. [Troubleshooting](#troubleshooting)
17. [For developers](#for-developers)

---

## What you need

- A Mac with Apple silicon (M1 or newer) and macOS 14 Sonoma or later.
- An AYN Thor, or an AYN Odin (Odin 2, Odin 2 Mini, Odin 2 Portal, Odin 3). On an Odin there is one screen instead of two, so the layout and second-screen options are simply not shown, and ratings in Ports come from owners of the same Odin. Other Android devices mostly work too.
- Cocoon is optional. Bifrost reads its library, artwork and play time when it's installed; without it, Play Time counts docked sessions only, and layouts are remembered per app instead of per game. Wherever Cocoon is needed, Bifrost says so.
- A USB-C cable that carries data, not just power.
- **USB debugging** turned on on the Thor (explained below).

## Install

1. Download the latest `Bifrost-Link-<version>.dmg` from the [Releases page](https://github.com/NiceKaleido/Bifrost-Link/releases).
2. Open it and drag **Bifrost Link** into your Applications folder.
3. The first time, **right-click** Bifrost Link in Applications and choose **Open**, then confirm. This is needed once because the app isn't notarized by Apple. If macOS still refuses, run this in Terminal:
   ```sh
   xattr -dr com.apple.quarantine "/Applications/Bifrost Link.app"
   ```

Everything Bifrost needs, including the tools for talking to Android, is inside the app. There's nothing else to install.

## Your first link

1. **Turn on USB debugging on the Thor** (one time only):
   1. Open **Settings ▸ About device** and tap **Build number** seven times until it says you're a developer.
   2. Go to **Settings ▸ System ▸ Developer options** and turn on **USB debugging**.
2. **Connect the Thor** to your Mac with the USB cable and open Bifrost Link.
3. On the Thor, a dialog asks **"Allow USB debugging?"**. Tick **Always allow from this computer** and tap **Allow**.

That's it. Bifrost links on its own and both screens appear. From now on, plugging in the cable is all it takes.

While linked, the Thor's own screens turn dark to save power and keep the picture only on your Mac. Pull the cable, or choose **Device ▸ Unlink**, and the Thor goes back to normal.

## The window

The toolbar, from left to right:

| Button | What it does |
| --- | --- |
| Status pill | Shows the Thor, its battery, and the game you're playing |
| Layout | How the two screens are arranged (see below), plus per-game layouts, controls and separate windows |
| Back · Home · Recents · Close App | Android's navigation buttons. Close App quits whatever is in front on the screen you clicked last; your launcher is never closed |
| Mute · Volume | Sound on the Mac, with a slider per screen |
| Screenshot · Replay · Record | Capture what's on screen |
| More (⋯) | Picture options, recording mode, instant replay, pause mirroring, Thor screens on/off, rotate, notifications, and Ports, Play Time and Controls |
| Full Screen · Sidebar | Full screen, and the side panel with Files, Library, Ports, Play Time, Saves and Cleanup |

**Layouts.** Choose them in the Layout menu or with ⌘1 to ⌘5:
- **Stacked:** top screen above bottom screen, like the Thor itself.
- **Side by Side:** the two screens next to each other.
- **Picture in Picture:** one screen big, the other small on top of it. ⌘-drag the small one to move it, ⌘-drag a corner to resize it.
- **Top Only** and **Bottom Only:** a single screen.

⌘0 swaps the screens. ⌥⌘0 resizes the window to fit the layout.

**Remember a layout per game.** While a game is running, the Layout menu offers "Remember Layout for This Game" and "…for All <System> Games". The next time you start that game, its layout comes back by itself. This works for Android apps and games too ("Remember Layout for This App").

**A screen in its own window.** Layout menu ▸ "Open Bottom Screen in Its Own Window" (or the top screen) gives that screen a window of its own. You could, for example, put the top screen full screen on your TV and keep the bottom screen on the MacBook. "Move Its Window to" sends it to any connected display, optionally straight into full screen. Close that window, or choose "Bring the … Back", to put the screen back. Bifrost remembers this for the next time you dock.

**Full screen** (⌘F) shows the screens edge to edge on black, without the toolbar. Move the pointer to the top edge to bring the controls back. Pop-up messages stay hidden in full screen; you can change that in Settings ▸ Picture.

**Picture options** (More menu):
- **Cinema mode** (⌥⌘C): a soft glow of the game's colors around the screens, like ambient TV lighting. Black bars and loading screens are ignored.
- **Sharper picture** (⌥⌘U, on by default): upscales the image to your Mac's display.
- **Stats overlay** (⌥⌘I): the Thor's frame rate, CPU and GPU load, temperature and memory, plus the stream's frame rate, bitrate and delay. Also switchable from the **Performance** tab.

## Playing

**Touch.** Click and drag to touch the Thor's screen. A trackpad pinch zooms with two fingers. Right click is Back, middle click is Home.

**Typing.** Your Mac keyboard types into whatever screen you clicked last, in your own keyboard layout. ⌘C and ⌘V copy and paste between the Mac and the Thor.

Cocoon's on-screen keyboard is made for controllers. It would turn Enter into a "q" and steal the arrow keys, so Bifrost switches it off while docked and back on when you unplug. If you'd rather type with a controller on Cocoon's keyboard, turn off "Type with the Mac keyboard" in Settings ▸ Input.

**Controllers.** Any controller connected to your Mac (Xbox, PlayStation, Switch Pro, 8BitDo…) shows up on the Thor as an **Odin controller**, the same kind as the Thor's built-in controls. Your existing button setups in every emulator just work. Bifrost also follows the Thor's Xbox/Nintendo button-style tile: in Nintendo style the button in the same position does the same thing. Want rumble? Settings ▸ Input ▸ "Show up on the Thor as" ▸ Xbox Wireless Controller.

**Controls per game.** Device ▸ Controls… lets you:
- remap every button
- swap or invert the sticks
- set the dead zone

Choose who the settings are for: only the game that's running, all games of its system, or every game. When a game starts, its own settings are used automatically. While the window is open, a dot lights up next to each button as you press it, so you can see what's what.

**Controller shortcuts.** Hold **Home** on your controller and press another button:

| Combo | Action |
| --- | --- |
| Home + R1 | Quick save |
| Home + L1 | Quick load |
| Home + R2 | Save replay |
| Home + L2 | Screenshot |
| Home + Start | Close the game |
| Home + Select | Start / stop recording |

Tapping Home on its own still goes Home. Change the combos, or use Select as the button to hold, in Controls… ▸ Shortcuts. On the keyboard, Quick Save is ⌃⌘S and Quick Load ⌃⌘L.

**Quick save and load** use the emulator's own save-state keys, read from its settings, so they follow whatever you set up there. That covers RetroArch (its save/load state keys, F2/F4 by default) and PPSSPP (its Save State / Load State mapping, including controller combos). Dolphin, DuckStation, ARMSX2 and Azahar on Android don't offer save-state keys that another app can press; Bifrost tells you so and you use their in-game menu instead.

**No controller? Use the keyboard and mouse.** Device ▸ Keyboard Plays as Controller (⌃⌘K) turns your keyboard into a controller:

| Keys | Controller |
| --- | --- |
| W A S D | Left stick |
| Arrow keys | D-pad |
| K · L · J · I | A · B · X · Y |
| Q · E | Shoulder buttons |
| 1 · 3 | Triggers |
| R · T | Stick clicks |
| Return · Tab | Start · Select |

Every key can be changed in Controls… Click the screen to hand the mouse to the game: the pointer disappears, moving the mouse turns the camera, left click is the right trigger and right click the left trigger. **Esc** gives the pointer back, and ⌃⌘K switches the keyboard back to typing.

**Sending files.** Drop files onto a screen to put them in the Thor's Download folder. Drop an `.apk` and it gets installed.

## Sound

The Thor's sound plays on your Mac, and the Thor itself stays quiet.
- **Mute** (⇧⌘M) silences the Mac without sending the sound back to the Thor.
- **Volume** has three sliders: one for everything, one for the top screen and one for the bottom screen. That's handy when a game plays on top and a video on the bottom.
- While docked, the Thor's own volume is held at full, so only Bifrost's sliders matter. Your usual Thor volume comes back when you unplug.
- If a game's sound ends up on the Thor's speaker anyway, Bifrost notices within a couple of seconds and brings it back.
- Some older games and emulators don't allow their sound to be captured per app. If one stays silent on the Mac, turn off **Separate audio per screen** in the Volume popover; then all of the Thor's sound is captured at once.
- **"Also play on the Thor's speakers"** in the Volume popover plays the sound on both.

## Screenshots, recordings and clips

| | How |
| --- | --- |
| **Screenshot** | ⇧⌘S saves a picture of each screen and copies it to the clipboard |
| **Record** | ⇧⌘R starts and stops a recording. Choose in the record button's menu between **Separate screens** (one video per screen, original quality) and **Window layout** (one video of both screens exactly as arranged in your window) |
| **Instant replay** | Turn it on in the More menu and choose 30 seconds, 1 minute or 2 minutes. When something great happens, press ⌥⌘S to save the last moments, with sound |
| **Clips** | After a replay or recording, click **Edit** in the message, or use Device ▸ Make a Clip… (⌥⌘E). Trim the start and end, then export a share-ready MP4 (with or without sound) or a GIF |

When a game is running, captures are named after the game and sorted into a folder per game. Choose the folders in Settings ▸ Capture.

## The side panel

⇧⌘F or the sidebar button opens a panel next to the screens. The column on its left lists the sections by name, grouped into **Files** and **Apps**; **Library**, **Ports** and **Play Time** for your games; and **Saves** and **Cleanup** to look after them. A number on Ports means updates are waiting. Each section starts with a short explanation, and its main action is always in the top-right corner: Rescan, Refresh, Back Up Now or Measure. Drag the panel's left edge to make it wider.

At the bottom of the panel, the **Activity** strip shows everything that's running, such as file copies, game shrinking and port installs, each with its own progress and a Cancel button.

### Files
Browse the Thor's internal storage and SD card.
- **Copy to the Thor:** drag files in from Finder, or use Upload….
- **Go to** (next to the path) jumps to Downloads, Roms, screenshots and other common folders.
- **Select files** to download, rename or delete them.
- **Sizes** shows how big each folder is, biggest first.
- **Find Largest Files** (⋯ menu) helps when space runs low.
- Right-click a folder and choose **Back Up With Saves** to include it in your save backups.

### Apps
Every app you installed yourself, biggest first, with its version and how much space the app, its data and its cache take. Click an app for its actions:
- **Open** and **Close**.
- **Clear Cache** frees the app's cache without touching anything else.
- **More ▸ Back Up APK to Mac** keeps a copy of exactly this version (all its parts) in `~/Library/Application Support/Bifrost Link/APKs`. **Install a backed-up version** puts it back, handy when an update breaks something.
- **More ▸ Reset App…** deletes the app's private data, like a fresh install. **Remove App…** uninstalls it, optionally keeping its data.

Emulators, ports and the launcher are labeled. Drop `.apk`, `.apks`, `.xapk` or `.apkm` files on the box at the bottom to install them, or click **Choose Files…** there.

### Library
Everything about your games. It checks itself a few seconds after you link.
- **Import games:** drop ROMs or disc images here. Bifrost recognizes the system (it even reads disc headers, so a PSP image isn't mistaken for PlayStation) and puts each game into the right `Roms/<system>` folder. With many files, "Set all to" picks one system for all of them.
- **Patches:** drop a translation or ROM-hack patch (`.ips`, `.ups`, `.bps`, `.xdelta`) together with the game, or on its own and pick the game from your Mac or your Thor. The patched game goes onto the Thor under the patch's name; your original stays as it is. If the patch belongs to a different version of the game, Bifrost tells you instead of making a broken copy.
- **Stray games** lying outside your `Roms` folders can be moved into place.
- **Rescan** (top right) checks everything again; hover over it to see when the library was last checked.
- **Space by system** shows which consoles take up the most room.
- **BIOS check** shows which systems are missing BIOS files.
- **Leftover artwork:** removes Cocoon artwork for games you deleted. Cocoon's game lists are backed up first.
- **Shrink games:**
  - Disc images (PS1, PS2, PSP, Dreamcast, Saturn) are converted to CHD.
  - Cartridge games (Game Boy, GBA, SNES, N64, Mega Drive and more) are zipped.
  - Each game is copied to the Mac, shrunk and checked there, then sent back. Your originals are only removed once you confirm, and playlists and Cocoon entries are updated to the new file.
- **App updates:** sideloaded emulators and apps are checked against their GitHub releases. Native ports from the Recompa catalog are left out here; they get their updates in the **Ports** section.

### Achievements
Your [RetroAchievements](https://retroachievements.org) progress.

**Signing in:** use your RetroAchievements username and your *web API key* (retroachievements.org ▸ Settings ▸ Keys). Both are kept on this Mac only, in a file only your account can read.

What the tab shows:
- **Profile:** points and what you're playing right now.
- **Your games:** progress bar and count per game, with beaten/mastered tags and an "on Thor" tag for games whose ROM is in your Roms folders. Filters: all, in progress, mastered, on my Thor.
- **Game details:** click a game for all its achievements, with badges and unlock dates (normal or hardcore).
- **Recent unlocks:** from the last 30 days.

### Pokémon
Your Pokémon from every mainline game, Red/Green through Legends: Z-A, in one place.

Where saves are found:
- PokeDaisy, RetroArch and melonDS (Game Boy, GBA, DS)
- Azahar (3DS)
- Dolphin (Colosseum, XD)
- Peanuts Native (Let's Go, Sword/Shield, BD/SP, Legends: Arceus, Scarlet/Violet, Z-A)
- other native ports that keep a regular save file

Games you haven't installed yet are picked up as soon as they have a save.

What you can do:
- **Look through your party and boxes.**
  - **Icons** come from [Pokémon Showdown](https://pokemonshowdown.com)'s icon sheet. It covers all 1,025 species plus regional forms and Megas. It's downloaded once and cached on your Mac.
  - **Offline:** if the download isn't possible, icons are read from the Pokémon GBA/DS ROMs in your Roms folders instead.
  - **Game art:** each game shows its Cocoon box art (for Peanuts Native, the Cocoon shortcut icon), or PokeDaisy's cover.
- **Edit moves.** The list shows the moves the Pokémon learns by level up to its current level in that game. Switch on **Show TMs, tutors and egg moves** for everything else it could know. **Use the moves it would know at level …** fills in the four newest level-up moves.
- **Trade evolutions** (Kadabra, Haunter, Onix holding a Metal Coat, Karrablast and Shelmet, …) evolve without a second player. When an item is needed, it's given and used up.
- **Move Pokémon to another game.** A preview lists everything that changes:
  - moves, items or Poké Balls the other game doesn't have
  - the hidden ability
  - Game Boy DVs and IVs
  - nickname length

  Pokémon that don't exist in the other game (Incineroar in Emerald, a Pikachu in a cap in FireRed, Bulbasaur in Legends: Arceus) can't be moved, and you're told why. Moves the real games can't make (newer → older, for example) are marked **Not possible in the real games**, and the Pokémon is rebuilt for the older game.

Every change is saved like this:
1. If the game is open, it's closed first (you're asked).
2. Both saves are backed up on this Mac ("Before Pokémon change" / "Before Pokémon move" in the Saves tab).
3. The new file is checked, then swapped in.

Romhack saves (Unbound and friends) and Japanese Gen 1–3 saves can be looked at but not changed. Peanuts Native saves are view-only until writing to them has been tested.

### Saves
Backups of your emulator saves on your Mac. They cover:
- RetroArch, PPSSPP, Dolphin, DuckStation, Eden, Azahar, melonDS and ARMSX2
- PokeDaisy and Peanuts Native (only the game saves, not Peanuts' keys and firmware)
- each emulator's settings (as a separate item)
- any folder you add yourself

How it works:
- **Automatic backup** once a day when you link, or **Back Up Now** at the top.
- **What gets backed up:** tick or untick each emulator. **Add Folder…** adds any folder on the Thor.
- **Keep the last 3 to 50 backups**, or all of them. **Pin** a backup to keep it forever.
- **Open a backup** to see every saved game and state with its date and size.
- **Restore** one emulator, only its settings, or everything. Your current saves are backed up first ("Before restore"), so a restore can always be undone.

Some apps keep their saves in private storage that can't be read over USB; Bifrost tells you which ones.

### Cleanup
Finds what piles up in emulators over time: shader caches, logs, dumps, old save states. It shows the size per emulator. Saves and states are backed up before they're removed, and mods and texture packs are never touched.

## Ports

The **Ports** tab in the side panel (⌥⌘R, or More ▸ Ports in the toolbar).

Native ports are PC, console and handheld games rebuilt to run directly on Android, without an emulator. Bifrost shows the community catalog from [Recompa](https://recompa.app), which lists hundreds of them.

- **Browse** all ports, the ones **On Thor**, or **Updates**. Search, and use **Filters** for **Works on the Thor** (rated by other Thor owners), **Dual screen**, type or original platform. Every port shows its Thor rating: great, playable or broken. Click a port for its details, screenshots and versions.
- **My Games** shows which ports you can use with games you already have. Bifrost compares the games in your `Roms` folders on the Thor with the catalog by name, ignoring region tags and punctuation, so "Mario Kart - Double Dash!! (USA).iso" counts for Mario Kart: Double Dash. Where the catalog lists exact dumps (N64, GBA and other cartridge games), the files are also checked by checksum and marked **Your copy** when they're exactly the version the port accepts; name matches are marked **You have**, because some ports need a specific version or a file prepared on a PC (see "Your game files" in the port's details). Zipped ROMs only match by name. Check Again (or Refresh at the top) looks again after you add games.
- **Install** with one click. The download comes straight from the port's GitHub page and is checked against the catalog before anything is installed.
- **Already installed?** Bifrost recognizes the exact version on your Thor and tells you when there's an update. **Update All** updates everything at once, and older versions are available if a new one misbehaves.
- **Your game files:** most ports need files from your own copy of the game. **Find on Thor** looks through your `Roms` folders for a file that matches exactly. **Choose on Mac…** checks a file from your Mac. Bifrost then puts the file where the port expects it and shows the port's own instructions. Game files are never downloaded from the internet.

After you link, Bifrost checks for port updates and lets you know when some are ready.

## Play Time

The **Play Time** tab in the side panel (⇧⌘T) shows how much you play:
- total hours, games played this week and your longest session
- your 10 most played games
- hours per system
- a 30-day chart

It combines several sources without counting anything twice:
- the play time Cocoon records for games it launches
- Android games you added to Cocoon, timed by Android's own usage statistics (with their real app names and Cocoon's artwork)
- RetroArch's own per-game play time, including games you start inside RetroArch without Cocoon
- the sessions Bifrost records while you're docked

Emulators and game launchers (like GameNative) never count as games themselves; the time goes to the game.

Right-click a game in **Most played** or **Recent sessions** to:
- **Rename** it (handy when Cocoon shows a nicer name than the app has, like "Burnout 3" for Takedawn)
- **Don't Count** it, if it isn't really a game. The "not counted" menu under the list brings it back.

## Performance

The **Performance** tab in the side panel shows what the Thor is doing right now, updated every second while the tab is open:
- **Frame rate** of the game or app in front, measured from Android's own frame timestamps, with the time per frame and how many frames were late
- **CPU, GPU and memory** load, with clock speeds per CPU core group and for the GPU
- **Temperatures** for the CPU, GPU, NPU, memory, battery and more
- **Battery** level and the power coming in over USB
- the **busiest processes**, and the stream's own numbers while mirroring
- live charts of the last two minutes; hover them for exact values

The **Overlay** button at the top shows the same numbers over the stream.

Frame rates are exact, not rounded to the display's nominal rate. A game locked to the screen can show 59.4 rather than 60, because that's how often its frames are actually shown.

## Docking: lid, screens, power and charging

Bifrost is made so the Thor can sit closed next to your Mac. You'll find these options in Settings ▸ Docking.

- **The screens go dark while linked.** Android keeps running, so the picture and sound on your Mac don't stop. ⇧⌘P turns the Thor's screens back on if you want to see them.
- **Close the lid** and the Thor keeps running.
- **Open the lid** and its screens come back on.
- **The power button** turns the Thor's screens on and off instead of disconnecting.
- **Charging separation:** while docked, the Thor runs straight from USB power and doesn't charge its battery, which is kinder to the battery. Your usual setting comes back when you unplug.
- **Pause mirroring** (⌃⌘P) stops the picture and gives the screens and sound back to the Thor, while Files, Library and controllers keep working. Resume when you want the picture back.
- **Unplugging** puts everything back the way it was: the screens, the volume, the keyboard, charging, Wi-Fi and Bluetooth. This happens on the Thor itself, so it works even if you just pull the cable. If the lid is closed, the Thor waits 30 seconds before it sleeps; open it in that time and it simply stays awake.
- **Sleep Manager** (optional): if you use the Sleep Manager app, Bifrost can pause it while docked so it doesn't switch Wi-Fi off, and restarts it when you unplug.

## Menu bar, login and updates

- **Menu bar:** a link icon in the menu bar shows your device, its battery and what you're playing, with quick actions: Screenshot, Save Replay, Quick Save/Load, Mute, Pause Mirroring and Unlink. With the menu bar item on, closing the window keeps Bifrost running there. Turn it off in Settings ▸ General.
- **Open at login** (Settings ▸ General) starts Bifrost when you log in, so plugging in the cable is all it takes. **Go full screen when it links** does what it says.
- **Updates:** Bifrost checks GitHub for a new release once a day (or Bifrost Link ▸ Check for Updates…). It shows what's new and, if you agree, downloads the disk image, checks it against the release's checksum, swaps the app and restarts. Your settings, backups and logs stay where they are.

## Settings at a glance

| Tab | What's there |
| --- | --- |
| **General** | Linking automatically, full screen on link, open at login, menu bar item, updates, the folder for downloaded files |
| **Picture** | Sharper picture, cinema mode, stats, full screen controls and pop-ups, codec, quality, frame rate and resolution |
| **Capture** | Folders for screenshots and recordings, instant replay length |
| **Docking** | Dark screens, lid and power button, charging separation, Sleep Manager |
| **Input** | Controllers, rumble, mouse pointer, typing with the Mac keyboard, Edit Controls… |
| **Emulation** | Save backup folder and how many to keep, port updates, shrinking |

Video settings (quality, codec, frame rate) apply on the next link. Device ▸ Relink applies them right away.

## Keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| ⌘1 – ⌘5 | Stacked · Side by Side · Picture in Picture · Top Only · Bottom Only |
| ⌘0 | Swap screens |
| ⌥⌘0 | Fit the window to the screens |
| ⌘F | Full screen |
| ⌥⌘C · ⌥⌘U · ⌥⌘I | Cinema mode · sharper picture · stats overlay |
| ⌥⌘+ · ⌥⌘− | Bigger / smaller picture-in-picture screen |
| ⌘⌫ · ⇧⌘H · ⇧⌘A | Back · Home · Recent apps |
| ⇧⌘N · ⇧⌘O | Notifications · Rotate |
| ⌥⌘↑ · ⌥⌘↓ | Thor volume up / down |
| ⌃⌘W | Close the app in front |
| ⇧⌘M | Mute |
| ⇧⌘P | Thor screens on / off |
| ⌃⌘P | Pause / resume mirroring |
| ⇧⌘S · ⇧⌘R · ⌥⌘S | Screenshot · Record · Save replay |
| ⌥⌘E | Make a clip |
| ⌃⌘S · ⌃⌘L | Quick save · Quick load |
| ⇧⌘F | Side panel |
| ⌃⌘K | Keyboard plays as controller |
| ⌥⌘R · ⇧⌘T | Ports · Play Time |

## Troubleshooting

**Bifrost doesn't find the Thor.**
- Check that USB debugging is on and that you allowed this Mac on the Thor.
- Try another cable or port; some cables only charge.
- If you also use Android tools on your Mac, run `adb kill-server` in Terminal and reopen Bifrost.

**A game is silent on the Mac.** It probably doesn't allow its sound to be captured per app. Turn off **Separate audio per screen** in the Volume popover.

**PPSSPP shows the game on the bottom screen.** That's PPSSPP's own Settings ▸ Graphics ▸ "External display" option. The Thor reports its bottom screen as an external display, so PPSSPP moves the game there. Turn the option off in PPSSPP.

**The picture stutters while copying big files.** Files are copied one at a time to keep the picture smooth. If it still stutters, lower the quality in Settings ▸ Picture.

**A port won't update.** If it says the installed version comes from a different author or is newer, Android needs the old one removed first. Bifrost offers "Back Up, Uninstall & Install". Data that the app keeps privately is lost in that case.

**A patch says "different version of the game".** The patch was made for another region or revision. Check the patch's notes for the exact version it needs.

**Logs.** If something goes wrong, `~/Library/Logs/Bifrost Link/bifrost.log` records what Bifrost did. Attach it when you report a problem.

---

## For developers

### Build

```sh
./scripts/build-app.sh            # builds build/Bifrost Link.app
./scripts/build-app.sh --install  # also copies it to /Applications
./scripts/build-app.sh --dmg      # also makes a disk image (set BIFROST_VERSION)
```

What you need to build:
- Xcode Command Line Tools (Swift 5.9 or newer)
- `adb` and the Android build tools (`/opt/homebrew/share/android-commandlinetools`)
- To bundle the optional tools: `brew install rom-tools xdelta`, which provides `chdman` and `xdelta3`
- To rebuild the device server: JDK 17

The build bundles `adb`, `aapt2`, `chdman`, `xdelta3`, the device server and the Pokémon data file into the app.

### Tests

```sh
./scripts/test.sh
```

This works with just the Command Line Tools. The save-format tests use your own saves when you put copies in `tmp/pokemon-fixtures/` (git ignores that folder), for example `blue.sav`, `black.sav`, `3ds-<title id>.main`. Without them, the tests fall back to save files they build themselves.

### Pokémon data

`Resources/pokedata.json.deflate` holds names, base stats, learnsets, evolutions, regional dexes and the per-game index tables. It contains no artwork. To rebuild it:

```sh
python3 scripts/gen-pokedata.py <pokeapi>/data/v2/csv [<PKHeX>/PKHeX.Core/Resources/byte/personal]
```

- The first folder is the [PokeAPI](https://github.com/PokeAPI/pokeapi) CSV dump.
- The optional second folder is PKHeX's personal tables. They provide the "present in game" flags, which say exactly which species and forms each Switch game accepts.

The save formats under `Sources/BifrostLink/Pokemon/Formats/` are written from scratch in Swift. PKHeX and the Project Pokémon / Bulbapedia docs were used as references for the layouts and constants.

### Releases

Every push to `main` that touches more than Markdown builds a release with GitHub Actions (`.github/workflows/release.yml`):
1. The version is `VERSION` plus the run number.
2. The release notes list the commits since the previous release.
3. A signed-ad-hoc, Apple-silicon DMG is attached.

The server jar is used as committed: after changing `server/bifrost.patch`, run `./server/build.sh` and commit `Resources/bifrost-server.jar`.

### How it works

```
Mac (Swift / SwiftUI / AppKit / Metal)              Thor (Android 13)
┌──────────────────────────────┐   adb forward    ┌────────────────────────────────────┐
│ ScreenController (top)       │◀── video+ctrl ──▶│ bifrost-server  display_id=0       │
│ ScreenController (bottom)    │◀── video+ctrl ──▶│ bifrost-server  display_id=4       │
│ AudioRouter (per screen)     │◀── raw PCM ──────│ bifrost-server  per-app capture    │
│ PowerGuard                   │◀── getevent ─────│ hall_switch / pmic_pwrkey          │
│ FileService, Library, Ports  │─── adb shell / push / pull                            │
└──────────────────────────────┘                  └────────────────────────────────────┘
```

**Device server.** It's [scrcpy](https://github.com/Genymobile/scrcpy) 4.1's server (Apache 2.0) with `server/bifrost.patch`. The patch adds:
- **Audio:** per-app audio capture, plus an audio-routing kick.
- **Video and power:** hidden display capture, so apps don't see an extra display; AYN `PServerBinder` backlight control; pause/resume video (control messages 23/24); charging separation.
- **Cleanup on the Thor:** it restores everything on unlink, waits for the lid before sleeping, and stands down when a new session links.
- **Gamepads:** UHID gamepads with Odin and Xbox identities.

The server runs from `/data/local/tmp` only while linked.

**Client.**
- **Protocol:** the scrcpy 4.x protocol.
- **Video:** VideoToolbox decoding and a Metal renderer with optional MetalFX upscaling.
- **Audio:** `AVAudioEngine` with adaptive buffering.
- **Recordings and replay:** passthrough writing.
- **Gamepads:** game controllers, keyboard and mouse share one input pipeline with per-game profiles.

**Project layout.**
```
Sources/BifrostLink/
  App/        BifrostApp (menus, windows), DeviceManager, LinkSettings, Log
  Core/       ADB, ServerSession, ControlChannel, VideoStream, AudioOutput, AudioRouter, PowerGuard
  Screen/     ScreenView (input), ScreenController, MetalRenderer
  Input/      KeyMap, GamepadBridge, ControllerProfile
  Capture/    Recorder, LayoutRecorder, ReplayBuffer, ReplayWriter, ScreenStats
  Emulation/  EmulationHub, Systems, CocoonBridge, Emulators (saves), EmulatorCleanup, DiscShrinker,
              RomPatcher, PortCatalog, PlayStats, EmulatorUpdater
  Files/      FileService
  UI/         ContentView, StageView, side panel tabs (Files, Library, Ports, Play Time, Saves, Cleanup),
              Controls, Clip editor, Settings
server/       bifrost.patch, build.sh
scripts/      build-app.sh
```

**Debugging.** Start the app binary with `BIFROST_DEBUG=1`. It then logs audio levels and stats every second, and accepts test commands as distributed notifications named `eu.nicekaleido.bifrostlink.command`.
