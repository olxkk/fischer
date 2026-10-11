# Fischer

Fischer is an open-source fishing macro for the Roblox game **Fisch**, written in AutoHotkey v2. It has a dark, minimalist GUI, a bar-scanning minigame solver, Discord webhook reports, and multi-profile config management.

> **Disclaimer.** Macros can break the rules of Roblox and of individual games, and accounts may be penalized. You use Fischer at your own risk. The authors give no warranty (see `LICENSE`).

## Features

- Dark GUI with four tabs: **Control**, **Settings & Profiles**, **Webhook & Reports**, **Calibration**
- Global hotkeys: `F5` start, `F6` pause / resume, `F7` emergency stop, `F2` calibrate
- Bar solver: scans the reel bar, finds the fish and your slider, predicts fish movement, and holds or taps the mouse to keep the slider under the fish
- Shake handling by mouse: finds the shake button by color and clicks it (optional extra keys)
- OCR scan of hotbar slot 1 (rod name, primary and secondary enchant) and of the level text
- Discord webhook: periodic **Fischer Report**, optional per-catch message, error and disconnect alerts with optional ping and in-memory screenshot
- Profiles: save, switch, export, and import config files

## Requirements

- Windows 10 or 11
- [AutoHotkey v2](https://www.autohotkey.com/) (64-bit)
- Windows OCR language pack (English is normally installed already). Needed only for rod, level, and disconnect reading.
- Windows PowerShell 5.1 (built into Windows). Fischer uses it to call the Windows OCR engine.

## Beginner guide

### 1. Install AutoHotkey v2

1. Go to <https://www.autohotkey.com/> and click **Download**.
2. Choose **Download v2.0**, run the installer, and pick **Express Installation**.
3. Make sure you installed **v2**, not v1. Fischer will not start on v1.

### 2. Get Fischer

1. Download this repository as a ZIP (green **Code** button, then **Download ZIP**) and extract it.
2. Keep the folder structure intact:

```
Fischer/
  main.ahk
  config.json
  lib/
    Webhook.ahk
    FishSolver.ahk
  README.md
  LICENSE
```

3. Double-click `main.ahk`. The Fischer window opens.

If Roblox ignores the macro's clicks or keys, right-click `main.ahk` and choose **Run as administrator**.

### 3. Prepare the game

- Start Fisch and equip your rod in hotbar slot 1.
- Pick one display mode and do not change it afterwards. Calibration stores screen pixels, so changing resolution, window size, or UI scale means you must calibrate again.
- Keep Roblox on your primary monitor.

### 4. Shake button

Fischer does not use UI navigation keys. It finds the shake button on screen by its color and clicks it with the mouse. You teach it the color in calibration step 5.

On the **Settings & Profiles** tab:

- **Shake click interval (ms)**: how often Fischer scans for the button and clicks it.
- **Extra keys (optional)**: keys tapped each cycle, such as `enter`. Leave it empty to only click.

### 5. Calibrate with F2

Open the **Calibration** tab. The idea is simple: pick a step, hover the mouse over the target, press `F2`. Fischer stores the coordinates or color and moves to the next step.

| Step | What to hover | What F2 stores |
|------|---------------|----------------|
| 1 | Top-left corner of the reel bar | Reel bar region |
| 2 | Bottom-right corner of the reel bar | Reel bar region |
| 3 | The fish icon inside the bar | Fish color |
| 4 | Your slider bar | Slider color |
| 5 | The shake button, while it is on screen | Shake button color |
| 6 | Center of hotbar slot 1 | Hotbar slot position |
| 7 | Top-left of the rod name / enchant text | Rod info region |
| 8 | Bottom-right of that text | Rod info region |
| 9 | Top-left of the level text (bottom-right of the screen) | Level region |
| 10 | Bottom-right of the level text | Level region |

Tips:

- Step 5 needs the shake button on screen: cast, wait for it, then hover it and press `F2`. Pick a pixel on the button itself, not on its text or border.
- Steps 1 to 4 need the reel bar on screen. Cast manually, let the minigame appear, and press `F2` on each point without clicking. If the bar disappears, cast again and continue from the step you were on.
- **Multi-color rods** (for example a rod whose slider is a gradient): on step 4, press `F2` on several different colors of the slider, up to 8, then click **Skip Step**. The first press replaces the old colors, later presses add to the list. You can also edit `Colors.SliderColor` by hand as a comma list, for example `"0xFF3366,0x33CCFF"`. `Colors.FishColor` accepts a list too.
- Choose **different** colors for the fish and the slider. If they look the same, raise or lower the color tolerance until they separate.
- The rod info region (steps 7 and 8) must cover the text that lists the rod name and its enchants. Fischer moves the mouse over slot 1 first so a tooltip can show. If your rod text is always visible, you can leave step 6 uncalibrated.
- Steps 6 to 10 are optional. Without them Fischer still fishes, but the report shows `Unknown` for rod, enchants, and level.
- Press **Test Scan (OCR)** to see what Fischer reads from your regions. If the output is empty or garbled, recalibrate those regions so they tightly cover only the text.
- The default colors in `config.json` are only starting points. Always run steps 3, 4 and 5.

The **Saved Calibration** box and the color swatches confirm what is stored. Calibration saves automatically.

### 6. Start fishing

1. Open the **Control** tab.
2. Press `F5` (or click **Start Macro**). Fischer focuses Roblox, scans your rod and level, and starts casting.
3. Press `F6` to pause or resume, and `F7` to stop. Stop releases every held mouse button and key right away and returns the status to **Idle**.

The Control tab shows the active config name, the live status (`Idle`, `Fishing...`, `Minigame Active`, `Paused`, `Error`), and your session statistics.

### 7. Set up the Discord webhook

1. In Discord, open your server settings, then **Integrations**, then **Webhooks**, then **New Webhook**.
2. Choose the channel, set the name and avatar you want, and click **Copy Webhook URL**.
3. In Fischer, open **Webhook & Reports**, tick **Enable Discord webhook**, paste the URL, and click **Test Webhook**. The status line under the field turns green on success.
4. Choose what to send:
   - **Send periodic Fischer Report**: every 15, 30, or 60 minutes. **Send Report Now** sends one immediately.
   - **Attach level screenshot to reports**: includes a picture of your level display.
   - **Post "fish successfully caught" on every catch**: one short message per catch.
   - **Ping me on Error / Disconnect**: adds `@everyone` (or the text in **Ping target**, for example `<@123456789012345678>`) to error alerts.
   - **Send In-Memory Screenshot on Failure**: attaches a screenshot to error alerts. It is never saved to your disk.
5. Click **Save Config**.

Fischer never sends a webhook username or avatar, so the name and icon from your Discord webhook settings are always used.

**Keep your webhook URL private.** Anyone with the URL can post to your channel. `config.json` and the files in `profiles/` contain it in plain text, so do not commit them after you enter a URL. If you ever leak it, delete the webhook in Discord and create a new one.

## What a Fischer Report contains

- Total fish caught and success rate
- Equipped rod, primary enchant, secondary enchant (`None` if there is only a primary enchant)
- Current level and levels gained since the previous report
- Active config profile and session time
- Optional screenshot of the level display

**Success rate** is fish caught divided by minigames started. Casts that never get a bite are not counted.

## Profiles and config files

- `config.json` is loaded on startup. It always mirrors the profile you saved or switched to last.
- **Save Config** writes the current settings to `profiles/<Name>.json` and to `config.json`. Type a new name in the **Name** box to create a new profile.
- Use the **Profile** drop-down to switch profiles.
- **Export Config** writes a standalone `.json` file. Fischer asks whether to include your webhook URL; choose **No** if you will share the file.
- **Load Config** imports an external `.json` file, stores it as a profile, and activates it. If the file has no webhook URL, your current one is kept.

Exported files include shake keys, timing values, colors, and all calibrated regions.

## Settings reference

| Setting | Meaning |
|---------|---------|
| Cast hold time (`CastHoldTimeMs`) | How long left click is held to cast |
| Wait after cast (`CastWaitMs`) | Pause between releasing the cast and starting the shake keys |
| Bite timeout (`CastTimeoutMs`) | Give up and recast if no minigame appears in this time |
| Scan interval (`ScanIntervalMs`) | Delay between bar scans while the minigame runs |
| Click / hold response (`ClickResponseMs`) | When the slider is already under the fish, the mouse is tapped on and off at this rate |
| Hold deadzone (`HoldDeadzonePx`) | Pixel distance within which the slider counts as centered |
| Color tolerance (`Tolerance`) | Allowed difference per color channel (0 to 255) |
| Min. catch time (`MinCatchMs`) | A minigame that lasts at least this long and then ends counts as a catch |
| Minigame timeout (`MinigameTimeoutMs`) | Safety limit for one minigame |
| Fish prediction frames (`PredictFrames`) | How far ahead the solver extrapolates fish movement |
| Scan step (`ScanStep`) | Samples every Nth pixel. Higher is faster but less precise. |
| Delay after catch (`PostCatchDelayMs`) | Pause before the next cast |

Advanced keys live only in the JSON files:

| Key | Meaning |
|-----|---------|
| `Game.WindowMatch` | AutoHotkey window match for Roblox (default `ahk_exe RobloxPlayerBeta.exe`) |
| `Game.StuckTimeoutSec` | Raise an error if there was no bite or catch for this long (0 disables) |
| `Game.DisconnectOcrCheckSec` | How often to OCR the game window for a disconnect dialog (0 disables) |
| `Scanner.OcrScale` | Enlarges OCR captures to help read small text |
| `Scanner.ShakeStep` / `Scanner.ShakeMinPixels` | Sampling step and minimum matching samples when searching for the shake button |
| `Scanner.HoverDelayMs` | How long to wait after hovering slot 1 before reading the tooltip |
| `Timing.EndGraceMs` | How long the fish (or slider) must be missing before the minigame counts as over |
| `Timing.StaticEndMs` | If the fish and slider do not move for this long, the minigame counts as over (handles leftover UI that matches the colors) |
| `Colors.MinMatchPixels` | Minimum matching pixels to accept the fish icon |

## How it works

1. **Cast**: holds left click for `CastHoldTimeMs`.
2. **Shake**: scans the Roblox window for the shake button color and clicks it, repeatedly, while watching the reel bar region for the fish color.
3. **Minigame**: captures the reel bar region, finds the fish icon and the slider by color, and holds or releases the mouse so the slider follows the fish. The minigame ends when the fish icon has been gone for `EndGraceMs`.
4. **Catch detection**: a minigame that ran for at least `MinCatchMs` and then ended counts as a catch. This is a timing heuristic, so tune `MinCatchMs` if the counts look wrong.
5. **Scans**: rod, enchants, and level are read with the built-in Windows OCR engine between casts. The macro also checks for a closed Roblox window, an OCR-detected disconnect dialog, and a stuck state, then sends an alert and stops.

Fischer needs the Roblox window to be active. If you switch away, it releases all inputs and waits instead of clicking elsewhere.

## Troubleshooting

| Problem | What to try |
|---------|-------------|
| "The reel bar is not calibrated yet" | Complete calibration steps 1 and 2. |
| Macro casts but never finds the minigame | Recalibrate fish color (step 3). Raise color tolerance a little. Recalibrate the shake button color (step 5). |
| Slider jitters or overshoots | Increase the hold deadzone, or adjust click / hold response and fish prediction frames. |
| CPU usage is high | Raise scan step or scan interval. |
| Inputs are ignored in Roblox | Run `main.ahk` as administrator. |
| OCR returns nothing | Make the region tight around the text, and install an OCR language in Windows Settings under Time & language. |
| Rod name is wrong | Re-run steps 6 to 8 and use **Test Scan (OCR)**. Lines that contain digits or stat words such as Lure or Luck are ignored. |
| Webhook test fails | Check that the URL starts with `https://discord.com/api/webhooks/` and has not been deleted. |
| Catch messages are missing | Fischer sends at most one catch message every 1.5 seconds to avoid Discord rate limits. |

## Project layout

| File | Purpose |
|------|---------|
| `main.ahk` | Entry point, config manager, GUI, hotkeys |
| `config.json` | Default configuration, loaded on startup |
| `lib/Webhook.ahk` | JSON helper, asynchronous webhook client, embeds, screenshot upload |
| `lib/FishSolver.ahk` | Screen capture, OCR, level tracker, shake handler, bar solver, macro engine |
| `profiles/` | Created automatically when you save profiles |
| `LICENSE` | MIT License |

## Contributing

Issues and pull requests are welcome. Please keep the code AutoHotkey v2 only, keep comments up to date, and test on a clean Windows install when you touch OCR or capture code.

## License

MIT. See [LICENSE](LICENSE).
