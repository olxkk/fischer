# Fisch Fishing Macro (AutoHotkey v2)

An automated fishing macro for the Roblox game **Fisch**, written in AutoHotkey v2, with a small native control window. It casts, shakes, detects the reel minigame, keeps the bar under the fish, counts catches and can report everything to a Discord webhook.

> **Use at your own risk.** Automating gameplay may break the rules of Roblox or of the game, and can get an account banned. This project is provided as-is, without any guarantee. The game UI can change with updates, so the default colours and positions may need tuning (see [Calibration](#calibration)).

## Features

- Control window: paste your webhook, tune the main settings, start / pause / resume, watch the status and log
- Settings saved to `config.json` and loaded again on the next start
- Cast with a configurable hold time
- Shake handling (UI navigation key + Enter) and bite detection
- Reel minigame solver: tracks the fish icon and the player bar by pixel colour
- Automatic loop: catch, wait, recast
- Discord webhook embeds (non-blocking, never freezes the minigame)
- Global hotkeys that work while the game is focused
- Calibration hotkey that shows the colour and relative position under the mouse

## Project structure

```
fisch-macro/
├── main.ahk              Entry point: start-up, hotkeys, calibration helper
├── config.example.json   Reference copy of the default settings
├── config.json           Your settings (created on first run, not committed)
├── lib/
│   ├── GUI.ahk           The control window
│   ├── Config.ahk        Loads, validates and saves config.json
│   ├── Json.ahk          Small JSON reader
│   ├── Webhook.ahk       Async Discord webhook sender and test
│   └── FishSolver.ahk    Cast, bite detection, minigame solver
├── .gitignore
└── README.md
```

## Prerequisites

- Windows 10 or 11
- [AutoHotkey v2](https://www.autohotkey.com/) (v2.0 or newer; v1 will not work)
- Roblox desktop client (`RobloxPlayerBeta.exe`) with Fisch
- Display setup (important for pixel detection):
  - Windowed or fullscreen both work, but keep the same mode and resolution you calibrated with
  - Use 100% Windows display scaling if possible (or at least keep it constant)
  - No overlays or colour filters (night light, HDR tweaks) over the reel bar
  - **Do not let the macro window cover the reel bar.** The reel bar is near the bottom centre of the game. Put the macro window on a second monitor or at the side of the screen (it opens at the top left)

## Setup

1. Download or clone this repository.
2. Install AutoHotkey v2.
3. Double-click `main.ahk`. The control window opens. On the first run `config.json` is created with default values.
4. Paste your Discord webhook URL (optional), adjust the settings, and press **Save Settings**.
5. Join a world, equip your rod, stand where you want to fish.
6. Press **Start Macro** or the toggle hotkey (default `F8`).

## The control window

| Control | What it does |
|---------|--------------|
| **Status** (top) | Current state: Idle, Fishing..., Fish Hooked! Reeling..., Caught!, Paused. Green = running, orange = paused, grey = idle |
| **Webhook URL** | Your Discord webhook URL |
| **Test Webhook** | Sends a test message to the URL in the box (works even if the webhook is switched off) and reports the result in the log |
| **Enable webhook** | Turns all webhook messages on or off |
| **Message on cast / hook** | Also send a message for every cast / every hooked fish (can be noisy) |
| **Cast hold (ms)** | How long the cast button is held. Use the slider (100-5000) or type any value up to 60000 |
| **Scan interval (ms)** | Delay between screen scans. Lower = more responsive, more CPU |
| **Fish / Bar tolerance** | How closely a pixel colour must match (0-255 per channel) |
| **Deadzone (px)** | Slack around the bar centre before the bar chases the fish. Raise it if the bar jitters |
| **Start Macro** | Starts the fishing loop (only available while idle) |
| **Pause Macro / Resume Macro** | Stops the loop and releases the mouse button; press again to continue |
| **Save Settings** | Writes the current values to `config.json` |
| **Log** | Timestamped messages: state changes, webhook test results, saved settings, config warnings |

Changed values are applied to the running macro when you press Start / Resume or Save. They are only written to `config.json` when you press **Save Settings**. Closing the window exits the script.

## Hotkeys

| Default | Setting | Action |
|---------|---------|--------|
| `F8` | `ToggleKey` | Same as the buttons: start when idle, pause when running, resume when paused |
| `F12` | `ExitKey` | Exit the script completely |
| `F9` | `CalibrateKey` | Show the colour and relative position under the mouse (log + clipboard) |

Hotkeys work while the game is in focus, so you do not need to touch the macro window.

## Configuration (`config.json`)

`config.json` is created on the first run and rewritten by **Save Settings**. It contains your webhook URL, so it is listed in `.gitignore` and will not be committed. `config.example.json` shows the defaults. If a value is missing or invalid, its default is used and a note appears in the log. If the file is not valid JSON, it is kept as `config.json.bad` and defaults are used.

Colours are written as text (`"0x5B4B43"`, `"#5B4B43"` is accepted too). Key names are not case sensitive.

### Settings in the window

| Key | Default | Description |
|-----|---------|-------------|
| `DiscordWebhookURL` | empty | Discord webhook URL |
| `EnableWebhook` | `false` | `true` / `false` |
| `WebhookOnCast` | `true` | Message on every cast |
| `WebhookOnHook` | `true` | Message when a fish is hooked |
| `CastHoldTimeMs` | `1000` | Milliseconds the cast button is held |
| `ScanIntervalMs` | `10` | Delay between pixel scans |
| `FishTolerance` / `BarTolerance` | `12` | Allowed difference per colour channel |
| `DeadzonePx` | `12` | Pixel margin where the bar hovers instead of chasing |

Started, resumed, paused, stopped and caught events are always sent when the webhook is enabled. The caught message includes a timestamp, the session catch count and the session time.

### Settings only in the file

Edit `config.json` while the script is not running (the window would overwrite changes when you press Save).

| Key | Default | Description |
|-----|---------|-------------|
| `CastKey` | `"LButton"` | Key or mouse button for casting and reeling |
| `RobloxWindow` | `"ahk_exe RobloxPlayerBeta.exe"` | Window selector (AHK WinTitle syntax) |
| `ToggleKey` / `ExitKey` / `CalibrateKey` | `F8` / `F12` / `F9` | Any AutoHotkey key name (`^F1` = Ctrl+F1). An invalid key falls back to the default |
| `ShakeEnabled` | `true` | Spam Enter to click shake buttons |
| `NavKey` | `"\\"` | Key that enables Roblox UI navigation (a backslash is written `\\` in JSON) |
| `ShakeNavKeyEveryCast` | `true` | Press `NavKey` once per cast |
| `ShakeStartDelayMs` | `1200` | Delay after casting before shaking |
| `BiteTimeoutMs` | `30000` | Recast if no bite after this long |
| `ReelLeft/Top/Right/Bottom` | `0.28 / 0.76 / 0.72 / 0.88` | Reel area as a fraction of the Roblox client area |
| `FishColor` | `"0x5B4B43"` | Fish icon colour (0xRRGGBB) |
| `BarColor` | `"0xFFFFFF"` | Player bar colour (0xRRGGBB) |
| `BarScanStepPx` | `4` | Sample spacing along the scanned row |
| `BarMaxGapSteps` | `3` | Missed samples allowed inside one run |
| `CatchEndMisses` | `25` | Scans without the fish before the catch counts as done |
| `MinigameTimeoutMs` | `90000` | Abort the minigame after this long |
| `PostCatchDelayMs` | `1500` | Pause after a catch before recasting |

## Calibration

The default colours and area are a starting point. Check them once for your setup:

1. Start a cast so the reel bar is on screen.
2. Hover the mouse over the fish icon and press `F9`. The log shows the colour (for example `0x5B4B43`) and the position. Put the colour into `FishColor`.
3. Hover over the white player bar, press `F9`, and put the colour into `BarColor`.
4. Hover over the left and right ends of the reel track, and the top and bottom. The log shows `x` / `y` as ratios; use them for `ReelLeft`, `ReelRight`, `ReelTop`, `ReelBottom`.
5. Raise the tolerances (try 20-30) if detection is flaky; lower them if the script latches onto background pixels.

## How it works

1. **Cast:** holds `CastKey` for `CastHoldTimeMs`, then releases. The pointer is moved onto the game first so clicks never land on the macro window.
2. **Shake / bite:** presses `NavKey`, then repeatedly presses Enter while scanning for the reel UI.
3. **Hooked:** the reel minigame counts as started once the fish icon is found.
4. **Reel:** one row of the reel area is copied from the screen into memory and scanned for the fish colour and bar colour. If the fish is right of the bar centre (beyond the deadzone), the button is held; if left, it is released; inside the deadzone it taps to hover.
5. **Caught:** when the fish icon has been missing for `CatchEndMisses` scans, the catch is counted, a webhook is sent, and the next cast starts.

Webhook messages use `WinHttp.WinHttpRequest.5.1` in asynchronous mode, so network delays never block the minigame loop. Only the **Test Webhook** button waits for the answer, for up to a few seconds.

## Troubleshooting

- **Nothing happens on Start:** check that `RobloxWindow` matches your client; the log says "Roblox window not found" if it does not.
- **Casts but never detects the minigame:** recalibrate `FishColor`, the reel area, and tolerances. Make sure the macro window is not covering the reel bar.
- **Bar jitters or overshoots:** raise `Deadzone` or `Scan interval`.
- **Minigame ends early:** raise `CatchEndMisses` in `config.json`.
- **Shaking does not work:** try `ShakeNavKeyEveryCast` set to `false`, or change `NavKey` to match your keyboard layout.
- **Webhook silent:** use **Test Webhook**. The URL must start with `https://discord.com/api/webhooks/`.
- **Settings reset:** the log lists invalid values or an unreadable `config.json` (kept as `config.json.bad`).

## License

Add the license of your choice (for example MIT) before publishing.
