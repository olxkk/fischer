# Fisch Macro

An auto-fishing macro for the Roblox game **Fisch**, written in AutoHotkey v2. It has a dark, minimalist window (inspired by cobalt.tools), saves its settings to `config.json`, and can report to Discord through a webhook.

> **Use at your own risk.** Automating a game can break the game's or Roblox's rules and may get your account penalised. This project is provided as-is, for learning and personal use. See the [LICENSE](LICENSE).

## Features

- Cast, detect the bite, solve the reel minigame, and loop forever.
- Tabbed GUI: **Control**, **Settings**, **Webhook & Reports**, **Calibration**.
- One-key calibration: hover over the fish icon and press `F2`.
- Discord webhook: start/pause/stop messages, a periodic **Fischer Report** (fish caught, casts, success rate, rod), and instant error alerts with an optional ping and a screenshot.
- Screenshots are captured and sent from memory. **No image file is ever saved to your disk.**
- Web requests run asynchronously, so the macro never freezes while talking to Discord.

## What you need

- Windows 10 or 11
- The Roblox desktop app (the one from roblox.com, or the Microsoft Store version)
- [AutoHotkey v2](https://www.autohotkey.com/) (free)
- Optional: a Discord server where you can create a webhook

## Install (no technical experience needed)

1. **Install AutoHotkey v2.** Go to https://www.autohotkey.com/, click **Download**, choose **Download v2.0**, run the installer and pick **Express Installation**.
2. **Download this project.** On the GitHub page click the green **Code** button, then **Download ZIP**.
3. **Unzip it.** Right-click the ZIP and choose **Extract All**. Keep the folder structure as it is: `main.ahk`, `config.json`, `lib/`, and so on.
4. **Run it.** Double-click `main.ahk`. The Fisch Macro window opens.

If double-clicking does nothing, right-click `main.ahk` and choose **Open with** > **AutoHotkey 64-bit**.

## In-game settings

Do these once before calibrating:

- Run Roblox in **windowed** or **borderless** mode. In true exclusive fullscreen, Windows may not let the macro read pixel colors. Press `F11` in Roblox to toggle fullscreen.
- Keep the Roblox window **visible**. Do not minimize it or cover it with other windows while the macro runs.
- Open Roblox settings (`Esc` > **Settings**) and use a **fixed graphics quality** (manual mode). Avoid very low settings that hide or blur UI icons.
- Equip your fishing rod and stand at a spot where you can fish.
- Leave your Windows display scaling alone; the macro works with 100%-200% scaling.

## Calibration (10 seconds)

The macro needs to know what the fish icon in the reel minigame looks like.

1. Open Roblox Fisch and equip your rod.
2. Cast. When the reel minigame appears, hover your mouse over the **fish icon** on the reel bar.
3. Press **`F2`**.

The **Calibration** tab shows `Calibrated: X, Y (0xRRGGBB)` with a swatch of the captured color. A tooltip also confirms it.

Can't switch windows fast enough? Click **Start 5-second countdown** in the Calibration tab, switch to Roblox, and hover over the fish icon until the countdown ends.

Tips:

- Hover over the *middle* of the icon, on a solid-colored spot.
- The fish icon color should differ from the white player bar.
- Optional: hover over the player bar and press `F3` to capture its color (default is white).

Calibrate again whenever you change your resolution, UI scale or window size.

## Using the macro

1. Calibrate (above).
2. Open the **Control** tab and click **Start Macro** (or press `F8`).
3. Use **Pause / Resume** to pause. Press `F8` again, or click **Stop Macro**, to stop. `F12` closes the program.

Status shows `Idle`, `Fishing...`, `Minigame Active`, `Paused` or `Error`. The activity log lists each catch.

## Set up a Discord webhook

A webhook is a private web address that lets the macro post messages into one Discord channel.

1. Open Discord and go to the server you want to use (you need the **Manage Webhooks** permission).
2. Right-click the channel, choose **Edit Channel**, then **Integrations**.
3. Click **Webhooks**, then **New Webhook**.
4. Give it a name, click **Copy Webhook URL**.
5. In Fisch Macro open **Webhook & Reports**, paste the URL, tick **Enable webhooks**, and click **Test Webhook**. A test message should appear in your channel.
6. Click **Save Settings**.

**Keep the URL secret.** Anyone with it can post in your channel. `config.json` contains your URL, so do not upload it to GitHub after you have entered it.

### Webhook options

| Option | What it does |
| --- | --- |
| Enable webhooks | Master switch for everything Discord-related. |
| Send Fischer Report summaries | Posts a "Fischer Report" embed on the chosen interval. |
| Interval | 15, 30, 60 or 120 minutes. |
| Rod equipped | Text shown in the report. The macro cannot read your rod, so type it here. |
| Ping me on Error / Disconnect | Adds a mention to alerts. |
| Ping target | `@everyone`, or a specific user like `<@123456789012345678>`. |
| Send in-memory screenshot on failure | Attaches a screenshot of the Roblox window to alerts. Nothing is saved to disk. |

The report's success rate is `fish caught / casts * 100` for the interval. A cast with no bite counts as a miss.

An alert is sent when the Roblox window disappears or is minimized, or when no fish has been caught for the **No-catch timeout**. The macro stops after an alert.

## Settings

| Setting | Default | Meaning |
| --- | --- | --- |
| Cast hold time (ms) | 800 | How long left click is held to cast. |
| Color tolerance | 20 | Allowed difference per color channel (0-255). |
| Scan delay (ms) | 25 | Pause between screen scans. |
| No-catch timeout (s) | 180 | Time without a catch before an alert is sent. |
| Bite wait limit (s) | 25 | Recast if no bite appears in this time. |

Advanced options live only in `config.json` (close the program before editing it):

| Key | Default | Meaning |
| --- | --- | --- |
| `Deadzone` | 12 | Pixels of difference before the bar is steered. |
| `BandHalfHeight` | 10 | Half-height of the scanned strip, in pixels. |
| `BandMinRelX` / `BandMaxRelX` | 0.2 / 0.8 | Left and right limits of the scanned strip, as a fraction of the window width. |
| `NavKey` | `\` | Pressed once when the macro starts, to enable Roblox UI navigation. Set to `""` to disable. |
| `ShakeKey` | `Enter` | Pressed repeatedly while waiting for a bite, to confirm the shake prompt. Set to `""` to disable. |

## Troubleshooting

**Double-clicking `main.ahk` does nothing or shows a version error.**
Install AutoHotkey **v2**, not v1. Version 1 cannot run this script.

**"Roblox window not found."**
Start Roblox first, and make sure the window is not minimized. The macro looks for `RobloxPlayerBeta.exe` (desktop app) or the Microsoft Store version.

**F2 says "Mouse is not over the Roblox window."**
Hover over the Roblox window itself, not over the Fisch Macro window.

**It never detects a bite or the minigame.**
- Recalibrate while the reel minigame is on screen, hovering over the fish icon.
- Raise **Color tolerance** to 30-40.
- Make sure Roblox is not in exclusive fullscreen (press `F11`).
- Try a different spot on the fish icon.

**It casts but does nothing else.**
The shake prompt may not be getting confirmed. Try clearing `NavKey` and `ShakeKey` in `config.json`, or change them to match how you press the shake button.

**The bar drifts away from the fish.**
Lower **Scan delay** (try 15-20). If the bar moves the wrong way, recalibrate and make sure the fish icon color is not the same as the player bar color.

**It keeps recasting without a bite.**
Raise **Bite wait limit** or adjust **Cast hold time** so the cast lands in water.

**Test Webhook fails.**
- The URL must start with `https://discord.com/api/webhooks/`.
- Check you copied the whole URL, with no spaces.
- The webhook may have been deleted in Discord. Create a new one.
- HTTP 429 means Discord is rate-limiting you. Wait a minute and retry.

**No screenshot in alerts.**
Make sure **Send in-memory screenshot on failure** is on. In exclusive fullscreen the screenshot can come out black; use windowed or borderless mode.

**Alert says "Possible disconnect."**
Roblox closed, was minimized, or lost connection. Rejoin the game, then press Start again.

**Settings do not stick.**
Click **Save Settings**. If the folder is read-only (for example inside a ZIP), extract the project to a normal folder first.

## Project layout

```
main.ahk            GUI and macro loop
config.json         saved settings
lib/Json.ahk        small JSON reader/writer
lib/FishSolver.ahk  pixel detection, minigame solver, calibration
lib/Webhook.ahk     async Discord requests, embeds, in-memory screenshots
README.md
LICENSE
```

## Contributing

Issues and pull requests are welcome. Please keep the code in AutoHotkey v2 syntax and add comments for anything non-obvious.

## License

MIT. See [LICENSE](LICENSE).
