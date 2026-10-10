; =============================================================================
;  FishSolver.ahk  -  Cast / bite detection / reel minigame logic for "Fisch"
;
;  Flow of one fishing cycle (see FishSolver.Run):
;    1. Cast      hold CastKey for CastHoldTimeMs, release.
;    2. Shake     wait for the bite. The shake UI is driven with the keyboard:
;                 NavKey ("\") turns on Roblox UI navigation, Enter "clicks"
;                 the selected shake button. We spam Enter until the reel bar
;                 shows up.
;    3. Hooked    the reel minigame is detected by finding the fish icon.
;    4. Reel      keep the white bar under the fish: hold CastKey to push the
;                 bar right, release to let it fall left.
;    5. Caught    when the fish icon is gone for CatchEndMisses scans in a
;                 row, the minigame is over. Count it, wait, recast.
;
;  HOW THE PIXEL DETECTION WORKS
;  The reel UI is a horizontal track. We convert the ReelLeft/Top/Right/Bottom
;  ratios (fractions of the Roblox client area) to screen pixels, then copy ONE
;  row of the screen across that region into memory (BitBlt). Reading one row
;  from memory is far faster than many PixelGetColor calls. On that row we look
;  for:
;     - a run of pixels close to FishColor   -> fish icon, its centre = fish X
;     - a run of pixels close to BarColor    -> player bar, left/right edges
;  "Close" means every RGB channel differs by at most the tolerance
;  (FishTolerance / BarTolerance). We sample every BarScanStepPx pixels and
;  allow up to BarMaxGapSteps missed samples inside one run, because the fish
;  icon is drawn on top of the bar and splits it.
;
;  WHERE TO ADJUST THINGS
;    - Wrong area scanned:      ReelLeft/Top/Right/Bottom in config.json
;    - Fish/bar not recognised: FishColor / BarColor (use the calibration
;                               hotkey) and raise FishTolerance / BarTolerance
;    - Bar jitters:             raise DeadzonePx
;    - Minigame ends too early: raise CatchEndMisses
;  The row scanned is the vertical middle of the region (50%). If nothing is
;  found there, 35% and 65% are tried. Edit ScanRowFractions below to change.
; =============================================================================
#Requires AutoHotkey v2.0

; -----------------------------------------------------------------------------
;  ScreenRow: copies one horizontal line of the screen into a 32-bit buffer.
; -----------------------------------------------------------------------------
class ScreenRow {
    __New(step, gapMax) {
        this.Step := Max(1, step)
        this.GapMax := Max(0, gapMax)
        this.Width := 0
        this.Bits := 0
        this.Bitmap := 0
        this.OldBitmap := 0
        this.hdcScreen := DllCall("GetDC", "Ptr", 0, "Ptr")
        this.hdcMem := DllCall("gdi32\CreateCompatibleDC", "Ptr", this.hdcScreen, "Ptr")
    }

    __Delete() {
        this.FreeBitmap()
        if this.hdcMem
            DllCall("gdi32\DeleteDC", "Ptr", this.hdcMem)
        if this.hdcScreen
            DllCall("ReleaseDC", "Ptr", 0, "Ptr", this.hdcScreen)
    }

    FreeBitmap() {
        if this.Bitmap {
            DllCall("gdi32\SelectObject", "Ptr", this.hdcMem, "Ptr", this.OldBitmap)
            DllCall("gdi32\DeleteObject", "Ptr", this.Bitmap)
            this.Bitmap := 0
            this.Bits := 0
        }
    }

    ; (Re)create a w x 1 top-down 32-bit DIB section.
    Resize(w) {
        this.FreeBitmap()
        bi := Buffer(40, 0)
        NumPut("UInt", 40, bi, 0)       ; biSize
        NumPut("Int", w, bi, 4)         ; biWidth
        NumPut("Int", -1, bi, 8)        ; biHeight (negative = top-down), 1 row
        NumPut("UShort", 1, bi, 12)     ; biPlanes
        NumPut("UShort", 32, bi, 14)    ; biBitCount
        bits := 0
        hbm := DllCall("gdi32\CreateDIBSection", "Ptr", this.hdcMem, "Ptr", bi, "UInt", 0
            , "Ptr*", &bits, "Ptr", 0, "UInt", 0, "Ptr")
        if !hbm
            return false
        old := DllCall("gdi32\SelectObject", "Ptr", this.hdcMem, "Ptr", hbm, "Ptr")
        if !this.OldBitmap
            this.OldBitmap := old
        this.Bitmap := hbm
        this.Bits := bits
        this.Width := w
        return true
    }

    ; Copy the screen row at (x, y) with width w into the buffer.
    Capture(x, y, w) {
        if (w < 1)
            return false
        if (w != this.Width || !this.Bitmap) {
            if !this.Resize(w)
                return false
        }
        ; 0x40CC0020 = SRCCOPY | CAPTUREBLT (also captures layered windows)
        return DllCall("gdi32\BitBlt", "Ptr", this.hdcMem, "Int", 0, "Int", 0, "Int", w, "Int", 1
            , "Ptr", this.hdcScreen, "Int", x, "Int", y, "UInt", 0x40CC0020, "Int")
    }

    ; Colour of sample i as 0xRRGGBB.
    PixelAt(i) {
        return NumGet(this.Bits, i * 4, "UInt") & 0xFFFFFF
    }

    ; True if every RGB channel of c is within tol of target.
    static Near(c, target, tol) {
        return Abs(((c >> 16) & 255) - ((target >> 16) & 255)) <= tol
            && Abs(((c >> 8) & 255) - ((target >> 8) & 255)) <= tol
            && Abs((c & 255) - (target & 255)) <= tol
    }

    ; Find the longest run of pixels matching `color` on the captured row.
    ; Returns {left, right} (x offsets inside the region) or 0 if none.
    ; minSamples = how many matching samples a run needs to count (noise filter).
    FindRun(color, tol, minSamples := 1) {
        step := this.Step
        bestLen := -1
        best := 0
        start := -1
        last := -1
        count := 0
        i := 0
        while (i < this.Width) {
            if ScreenRow.Near(this.PixelAt(i), color, tol) {
                if (start >= 0 && ((i - last) // step - 1) > this.GapMax) {
                    ; gap too large: close the current run, start a new one
                    if (count >= minSamples && (last - start) > bestLen) {
                        bestLen := last - start
                        best := {left: start, right: last}
                    }
                    start := -1
                }
                if (start < 0) {
                    start := i
                    count := 0
                }
                last := i
                count++
            }
            i += step
        }
        if (start >= 0 && count >= minSamples && (last - start) > bestLen)
            best := {left: start, right: last}
        return best
    }
}

; -----------------------------------------------------------------------------
;  FishSolver: the state machine that drives the whole macro.
; -----------------------------------------------------------------------------
class FishSolver {
    ; Vertical positions (fraction of the reel region height) that are scanned.
    ScanRowFractions := [0.5, 0.35, 0.65]

    Running := false
    Paused := false
    Listener := ""          ; callback(kind, text) set by the GUI: "status", "state"
    LastStatus := ""
    Catches := 0
    RunId := 0
    Held := false
    SessionStart := 0

    RegionX := 0
    RegionY := 0
    RegionW := 0
    RegionH := 0

    __New(cfg, hook) {
        this.Cfg := cfg
        this.Hook := hook
        this.Row := ScreenRow(cfg["BarScanStepPx"], cfg["BarMaxGapSteps"])
    }

    ; ---- public controls (called from hotkeys in main.ahk) -------------------
    Begin() {
        if this.Running
            return
        resuming := this.Paused
        this.Running := true
        this.Paused := false
        this.RunId += 1
        this.LastStatus := ""
        if !this.SessionStart
            this.SessionStart := A_TickCount
        this.Emit("state", "running")
        this.Hook.Send(resuming ? "Macro Resumed" : "Macro Started"
            , resuming ? "Auto-fishing resumed." : "Auto-fishing started."
            , Webhook.COLOR_GREEN, this.StatFields())
        SetTimer(ObjBindMethod(this, "Run", this.RunId), -1)
    }

    Pause() {
        if !this.Running
            return
        this.Running := false
        this.Paused := true
        this.RunId += 1                       ; invalidates the running loop
        this.Release()
        this.Emit("state", "paused")
        this.Status("Paused")
        this.Hook.Send("Macro Paused", "Auto-fishing paused.", Webhook.COLOR_YELLOW, this.StatFields())
    }

    Shutdown() {
        this.Running := false
        this.RunId += 1
        this.Release()
        this.Hook.Send("Macro Stopped", "Script exited.", Webhook.COLOR_RED, this.StatFields())
        this.Hook.Flush(2)                    ; let the last webhook go out
    }

    ; ---- main loop -------------------------------------------------------------
    Run(id) {
        while this.Alive(id) {
            if !this.UpdateRegion() {
                this.Status("Roblox window not found, waiting...")
                this.SleepAlive(id, 1000)
                continue
            }
            this.Focus()
            this.KeepMouseInGame()
            if !this.Cast(id)
                break
            if !this.WaitForBite(id) {
                if this.Alive(id)
                    this.Status("No bite, recasting...")
                continue
            }
            if this.Cfg["WebhookOnHook"]
                this.Hook.Send("Fish Hooked", "Reel minigame started.", Webhook.COLOR_BLUE)
            result := this.Reel(id)
            if (result = "caught") {
                this.Catches += 1
                this.Hook.Send("Fish Caught", "Catch #" this.Catches " this session.", Webhook.COLOR_GREEN
                    , this.StatFields(true))
                this.Status("Caught! Total: " this.Catches)
            } else if (result = "timeout") {
                this.Status("Minigame timed out")
            }
            this.SleepAlive(id, this.Cfg["PostCatchDelayMs"])
        }
    }

    ; Step 1: hold the cast key, then release.
    Cast(id) {
        holdMs := this.Cfg["CastHoldTimeMs"]
        this.Status("Fishing... casting rod (" holdMs " ms)")
        if !this.Alive(id)
            return false
        this.Hold()
        this.SleepAlive(id, holdMs)
        this.Release()
        if !this.Alive(id)
            return false
        if this.Cfg["WebhookOnCast"]
            this.Hook.Send("Rod Cast", "Cast with a hold time of " holdMs " ms.", Webhook.COLOR_BLUE
                , [Map("name", "Hold time", "value", holdMs " ms", "inline", true)])
        return true
    }

    ; Steps 2-3: shake until the reel minigame (fish icon) appears.
    ; Returns true if the fish got hooked, false on timeout or stop.
    WaitForBite(id) {
        cfg := this.Cfg
        this.Status("Fishing... waiting for bite")
        this.SleepAlive(id, cfg["ShakeStartDelayMs"])
        if (cfg["ShakeEnabled"] && cfg["ShakeNavKeyEveryCast"] && this.Alive(id))
            this.PressKey(cfg["NavKey"])
        interval := Max(cfg["ScanIntervalMs"], 20)    ; do not flood Roblox with Enter presses
        start := A_TickCount
        while (this.Alive(id) && A_TickCount - start < cfg["BiteTimeoutMs"]) {
            if this.Scan()
                return true
            if cfg["ShakeEnabled"] {
                this.Focus()                              ; Enter must go to the game, not to the macro window
                this.PressKey("Enter")
            }
            Sleep(interval)
        }
        return false
    }

    ; Steps 4-5: keep the bar under the fish. Returns "caught", "timeout" or "stopped".
    Reel(id) {
        cfg := this.Cfg
        this.Status("Fish Hooked! Reeling...")
        deadzone := cfg["DeadzonePx"]
        interval := cfg["ScanIntervalMs"]
        start := A_TickCount
        misses := 0
        pulse := false
        while this.Alive(id) {
            if (A_TickCount - start > cfg["MinigameTimeoutMs"]) {
                this.Release()
                return "timeout"
            }
            s := this.Scan()
            if !s {
                misses += 1
                if (misses >= cfg["CatchEndMisses"]) {
                    this.Release()
                    return "caught"
                }
            } else {
                misses := 0
                if (s.barLeft < 0) {
                    ; bar not seen: fall back to the side of the region the fish is on
                    if (s.fish > this.RegionW / 2)
                        this.Hold()
                    else
                        this.Release()
                } else {
                    diff := s.fish - (s.barLeft + s.barRight) / 2
                    if (diff > deadzone)
                        this.Hold()                 ; fish is right of the bar: push right
                    else if (diff < -deadzone)
                        this.Release()              ; fish is left of the bar: let it fall
                    else {
                        pulse := !pulse             ; inside the deadzone: tap to hover
                        if pulse
                            this.Hold()
                        else
                            this.Release()
                    }
                }
            }
            Sleep(interval)
        }
        this.Release()
        return "stopped"
    }

    ; ---- detection --------------------------------------------------------------
    ; Returns {fish, barLeft, barRight} (x offsets in the region, -1 = bar not
    ; found) or 0 when no fish icon is visible.
    Scan() {
        cfg := this.Cfg
        for frac in this.ScanRowFractions {
            y := this.RegionY + Round(this.RegionH * frac)
            if !this.Row.Capture(this.RegionX, y, this.RegionW)
                continue
            fish := this.Row.FindRun(cfg["FishColor"], cfg["FishTolerance"], 1)
            if !fish
                continue
            bar := this.Row.FindRun(cfg["BarColor"], cfg["BarTolerance"], 2)
            return {
                fish: (fish.left + fish.right) / 2,
                barLeft: bar ? bar.left : -1,
                barRight: bar ? bar.right : -1
            }
        }
        return 0
    }

    ; Convert the ratio-based reel region to screen pixels.
    UpdateRegion() {
        cfg := this.Cfg
        hwnd := WinExist(cfg["RobloxWindow"])
        if !hwnd
            return false
        if (WinGetMinMax("ahk_id " hwnd) = -1)
            WinRestore("ahk_id " hwnd)
        WinGetClientPos(&x, &y, &w, &h, "ahk_id " hwnd)
        if (w < 1 || h < 1)
            return false
        left := Min(cfg["ReelLeft"], cfg["ReelRight"])
        right := Max(cfg["ReelLeft"], cfg["ReelRight"])
        top := Min(cfg["ReelTop"], cfg["ReelBottom"])
        bottom := Max(cfg["ReelTop"], cfg["ReelBottom"])
        this.RegionX := x + Round(w * left)
        this.RegionY := y + Round(h * top)
        this.RegionW := Max(1, Round(w * (right - left)))
        this.RegionH := Max(1, Round(h * (bottom - top)))
        return true
    }

    ; ---- input helpers ------------------------------------------------------------
    Focus() {
        hwnd := WinExist(this.Cfg["RobloxWindow"])
        if (hwnd && !WinActive("ahk_id " hwnd)) {
            try {
                WinActivate("ahk_id " hwnd)
                WinWaitActive("ahk_id " hwnd, , 2)
            }
        }
    }

    Hold() {
        if this.Held
            return
        Send("{" this.Cfg["CastKey"] " down}")
        this.Held := true
    }

    Release() {
        if !this.Held
            return
        Send("{" this.Cfg["CastKey"] " up}")
        this.Held := false
    }

    PressKey(key) {
        try Send("{" key "}")
    }

    ; ---- misc helpers ---------------------------------------------------------------
    ; True while this loop instance should keep going.
    Alive(id) {
        return this.Running && id = this.RunId
    }

    ; Sleep in small slices so Pause/Exit react quickly.
    SleepAlive(id, ms) {
        end := A_TickCount + ms
        while (this.Alive(id) && A_TickCount < end)
            Sleep(Min(50, Max(1, end - A_TickCount)))
    }

    ; Report a state change to the GUI. Repeated identical text is ignored so
    ; the log is not flooded while waiting.
    Status(text) {
        if (text = this.LastStatus)
            return
        this.LastStatus := text
        this.Emit("status", text)
    }

    Emit(kind, text) {
        if this.Listener
            try this.Listener.Call(kind, text)       ; a GUI problem must never stop the fishing loop
    }

    ; Re-read settings that were copied at start-up (the GUI calls this after
    ; it changed values in the shared config Map).
    ApplyConfig() {
        this.Row.Step := Max(1, this.Cfg["BarScanStepPx"])
        this.Row.GapMax := Max(0, this.Cfg["BarMaxGapSteps"])
    }

    ; Clicks go to the window under the pointer. After pressing a button in the
    ; macro window the pointer is still over it, so move it onto the game first.
    KeepMouseInGame() {
        hwnd := WinExist(this.Cfg["RobloxWindow"])
        if !hwnd
            return
        MouseGetPos(&mx, &my, &under)
        if (under != hwnd) {
            WinGetClientPos(&x, &y, &w, &h, "ahk_id " hwnd)
            MouseMove(x + w // 2, y + h // 2, 0)
        }
    }

    ; Embed fields with session statistics.
    StatFields(withTime := false) {
        fields := [Map("name", "Total catches", "value", String(this.Catches), "inline", true)]
        if this.SessionStart {
            secs := (A_TickCount - this.SessionStart) // 1000
            fields.Push(Map("name", "Session time"
                , "value", Format("{:02}:{:02}:{:02}", secs // 3600, Mod(secs // 60, 60), Mod(secs, 60))
                , "inline", true))
        }
        if withTime
            fields.Push(Map("name", "Caught at", "value", FormatTime(, "yyyy-MM-dd HH:mm:ss"), "inline", false))
        return fields
    }
}
