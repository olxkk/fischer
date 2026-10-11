; ============================================================================
; lib/FishSolver.ahk
; Screen scanning, calibration and the reel-minigame solver for Fisch.
;
; How it works
;   * Calibration (F2): you hover the mouse over the fish icon of the reel bar.
;     We store its color and where it sits inside the Roblox window (as
;     fractions, so it survives moving or resizing the window).
;   * A thin horizontal "band" at that height is scanned for the fish color
;     (and the white player bar). If the fish color shows up, the reel
;     minigame is running.
;   * Minigame: if the fish is right of the bar center, hold left click;
;     if it is left, release. Close to the fish, the click is pulsed.
;
; All numbers come from the shared config Map, so edits in the GUI apply live.
; ============================================================================

class FishSolver {
    static CONFIRM_SCANS := 3          ; consecutive hits needed to accept a bite
    static MISS_SCANS_TO_FINISH := 15  ; consecutive misses that end the minigame

    __New(cfg) {
        this.cfg := cfg
        this.held := false
        this.missCount := 0
        this.pulse := false
        CoordMode("Pixel", "Screen")
        CoordMode("Mouse", "Screen")
    }

    ; ---- window helpers -----------------------------------------------------

    ; Returns an object {hwnd, x, y, w, h} for the Roblox client area, or 0.
    GetWindow() {
        hwnd := WinExist("ahk_exe RobloxPlayerBeta.exe")
        if !hwnd
            hwnd := WinExist("Roblox ahk_exe Windows10Universal.exe")
        if !hwnd
            return 0
        if WinGetMinMax(hwnd) = -1
            return 0
        WinGetClientPos(&x, &y, &w, &h, hwnd)
        if w < 50 || h < 50
            return 0
        return { hwnd: hwnd, x: x, y: y, w: w, h: h }
    }

    Focus(w) {
        if !WinActive("ahk_id " w.hwnd) {
            WinActivate("ahk_id " w.hwnd)
            WinWaitActive("ahk_id " w.hwnd, , 2)
        }
    }

    ; ---- color helpers ------------------------------------------------------

    Tol() => Min(255, Max(0, Integer(this.cfg["ColorTolerance"])))

    ColorsClose(a, b, tol) {
        a := Integer(a), b := Integer(b)
        return Abs((a >> 16 & 255) - (b >> 16 & 255)) <= tol
            && Abs((a >> 8 & 255) - (b >> 8 & 255)) <= tol
            && Abs((a & 255) - (b & 255)) <= tol
    }

    ; Scan band [x1, y1, x2, y2, centerY] for the calibrated height.
    BandRect(w) {
        cy := w.y + Round(Number(this.cfg["CalRelY"]) * w.h)
        hh := Integer(this.cfg["BandHalfHeight"])
        x1 := w.x + Round(Number(this.cfg["BandMinRelX"]) * w.w)
        x2 := w.x + Round(Number(this.cfg["BandMaxRelX"]) * w.w)
        return [x1, cy - hh, x2, cy + hh, cy]
    }

    ; ---- calibration --------------------------------------------------------

    ; which = "fish" (fish icon color + height) or "bar" (player bar color).
    ; Returns Map("ok", bool, "msg", text).
    Calibrate(which := "fish") {
        w := this.GetWindow()
        if !w
            return Map("ok", false, "msg", "Roblox window not found. Open Fisch first.")
        MouseGetPos(&mx, &my)
        if mx < w.x || my < w.y || mx > w.x + w.w || my > w.y + w.h
            return Map("ok", false, "msg", "Mouse is not over the Roblox window.")
        color := Format("0x{:06X}", Integer(PixelGetColor(mx, my)))
        if which = "bar" {
            this.cfg["CalBarColor"] := color
            return Map("ok", true, "msg", "Player bar color saved: " color)
        }
        this.cfg["CalX"] := mx
        this.cfg["CalY"] := my
        this.cfg["CalRelX"] := Round((mx - w.x) / w.w, 4)
        this.cfg["CalRelY"] := Round((my - w.y) / w.h, 4)
        this.cfg["CalFishColor"] := color
        this.cfg["Calibrated"] := 1
        return Map("ok", true, "msg", "Calibrated: " mx ", " my " (" color ")")
    }

    ; ---- detection ----------------------------------------------------------

    FindFish(w, &fx) {
        fx := 0
        r := this.BandRect(w)
        try {
            return PixelSearch(&fx, &fy, r[1], r[2], r[3], r[4], Integer(this.cfg["CalFishColor"]), this.Tol())
        }
        return false
    }

    ; Finds the player bar and returns its approximate center X in cx.
    FindBar(w, &cx) {
        cx := 0
        r := this.BandRect(w)
        barColor := Integer(this.cfg["CalBarColor"])
        tol := this.Tol()
        try {
            if !PixelSearch(&lx, &ly, r[1], r[2], r[3], r[4], barColor, tol)
                return false
        } catch {
            return false
        }
        ; Walk right along the row until the bar color stops (tolerating the
        ; fish icon overlapping the bar for a few samples).
        lastHit := lx
        x := lx
        misses := 0
        loop 200 {
            x += 4
            if x > r[3]
                break
            if this.ColorsClose(PixelGetColor(x, ly), barColor, tol) {
                lastHit := x
                misses := 0
            } else {
                misses++
                if misses >= 3
                    break
            }
        }
        cx := (lx + lastHit) / 2
        return true
    }

    ; ---- actions ------------------------------------------------------------

    Hold(down) {
        if down = this.held
            return
        if down
            Click("Down")
        else
            Click("Up")
        this.held := down
    }

    Release() {
        if this.held {
            Click("Up")
            this.held := false
        }
    }

    SendKey(k) {
        if k != ""
            Send("{" k "}")
    }

    ; Optional: enable Roblox UI navigation once (so Enter can press the shake
    ; button). Called once when the macro starts.
    PrimeNavigation() {
        this.SendKey(this.cfg["NavKey"])
        Sleep(150)
    }

    Cast(w) {
        this.Release()
        MouseMove(w.x + w.w // 2, w.y + w.h // 2, 0)
        Click("Down")
        Sleep(Integer(this.cfg["CastHoldTimeMs"]))
        Click("Up")
    }

    ; Waits for the reel minigame to appear.
    ; stopFn() should return true when the caller wants to abort.
    ; Returns "bite", "timeout", "abort" or "nowindow".
    WaitForReel(timeoutMs, stopFn) {
        start := A_TickCount
        lastShake := 0
        hits := 0
        shakeKey := this.cfg["ShakeKey"]
        delay := Integer(this.cfg["ScanDelayMs"])
        loop {
            if stopFn()
                return "abort"
            if A_TickCount - start > timeoutMs
                return "timeout"
            w := this.GetWindow()
            if !w
                return "nowindow"
            if this.FindFish(w, &fx) {
                hits++
                if hits >= FishSolver.CONFIRM_SCANS {
                    this.missCount := 0
                    return "bite"
                }
            } else {
                hits := 0
            }
            if shakeKey != "" && A_TickCount - lastShake > 180 {
                this.SendKey(shakeKey)
                lastShake := A_TickCount
            }
            Sleep(delay)
        }
    }

    ; One scan/steer step of the minigame.
    ; Returns true while the minigame is still running, false when it is over.
    SolveStep() {
        w := this.GetWindow()
        if !w {
            this.Release()
            return false
        }
        if !this.FindFish(w, &fx) {
            this.missCount++
            if this.missCount >= FishSolver.MISS_SCANS_TO_FINISH {
                this.missCount := 0
                this.Release()
                return false
            }
            return true
        }
        this.missCount := 0
        dz := Integer(this.cfg["Deadzone"])
        if this.FindBar(w, &bx) {
            err := fx - bx
            if err > dz {
                this.Hold(true)
            } else if err < -dz {
                this.Hold(false)
            } else {
                this.pulse := !this.pulse
                this.Hold(this.pulse)
            }
        } else {
            this.Hold(false)
        }
        return true
    }
}
