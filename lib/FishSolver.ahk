; ==============================================================================
;  Fischer - lib/FishSolver.ahk
;  Screen capture, OCR scanner, level tracker, shake key handler and the
;  bar-scanning minigame solver, plus the macro engine that ties them together.
;
;  Contents
;    StopMacro / FischerFailure : control-flow exceptions
;    FischerGdi      : GDI+ startup (used only to PNG-encode captures in memory)
;    ScreenGrabber   : fast screen region capture into a pixel buffer
;    FischerOcr      : Windows 10/11 built-in OCR, called through PowerShell
;    FishStats       : session statistics shared with the GUI and webhook
;    FishSolver      : the macro engine (cast, shake, minigame, scans, errors)
; ==============================================================================
#Requires AutoHotkey v2.0


class StopMacro extends Error {
}

class FischerFailure extends Error {
}


; ------------------------------------------------------------------------------
;  GDI+ lifetime
; ------------------------------------------------------------------------------
class FischerGdi {
    static Token := 0

    static Startup() {
        if this.Token
            return
        if !DllCall("GetModuleHandle", "str", "gdiplus", "ptr")
            DllCall("LoadLibrary", "str", "gdiplus")
        si := Buffer(A_PtrSize = 8 ? 24 : 16, 0)
        NumPut("UInt", 1, si, 0)
        token := 0
        DllCall("gdiplus\GdiplusStartup", "ptr*", &token, "ptr", si, "ptr", 0)
        this.Token := token
    }

    static Shutdown() {
        if this.Token {
            DllCall("gdiplus\GdiplusShutdown", "ptr", this.Token)
            this.Token := 0
        }
    }
}


; ------------------------------------------------------------------------------
;  ScreenGrabber
;    Captures a screen rectangle into a 32-bit top-down DIB section whose pixels
;    can be read directly with NumGet. Create once, call Grab() repeatedly.
;    Pixel layout in memory: 0xAARRGGBB per UInt.
;    scale > 1 enlarges the capture (used to help OCR read small text).
; ------------------------------------------------------------------------------
class ScreenGrabber {
    __New(x, y, w, h, scale := 1) {
        this.hbm := 0
        this.hdc := 0
        this.old := 0
        this.bits := 0
        this.x := Integer(x)
        this.y := Integer(y)
        this.w := Max(1, Integer(w))
        this.h := Max(1, Integer(h))
        this.scale := Max(1, Integer(scale))
        this.ow := this.w * this.scale
        this.oh := this.h * this.scale

        hdcScreen := DllCall("GetDC", "ptr", 0, "ptr")
        this.hdc := DllCall("CreateCompatibleDC", "ptr", hdcScreen, "ptr")
        bi := Buffer(40, 0)
        NumPut("UInt", 40, bi, 0)             ; biSize
        NumPut("Int", this.ow, bi, 4)         ; biWidth
        NumPut("Int", -this.oh, bi, 8)        ; biHeight (negative = top-down)
        NumPut("UShort", 1, bi, 12)           ; biPlanes
        NumPut("UShort", 32, bi, 14)          ; biBitCount
        bits := 0
        this.hbm := DllCall("CreateDIBSection", "ptr", hdcScreen, "ptr", bi, "uint", 0
            , "ptr*", &bits, "ptr", 0, "uint", 0, "ptr")
        DllCall("ReleaseDC", "ptr", 0, "ptr", hdcScreen)
        if !this.hbm {
            DllCall("DeleteDC", "ptr", this.hdc)
            this.hdc := 0
            throw Error("ScreenGrabber: could not allocate a " this.ow "x" this.oh " capture buffer.")
        }
        this.bits := bits
        this.old := DllCall("SelectObject", "ptr", this.hdc, "ptr", this.hbm, "ptr")
    }

    ; Copy the current screen contents of the rectangle into the buffer.
    Grab() {
        hdcScreen := DllCall("GetDC", "ptr", 0, "ptr")
        if (this.scale = 1) {
            DllCall("BitBlt", "ptr", this.hdc, "int", 0, "int", 0, "int", this.w, "int", this.h
                , "ptr", hdcScreen, "int", this.x, "int", this.y, "uint", 0x40CC0020)   ; SRCCOPY | CAPTUREBLT
        } else {
            DllCall("SetStretchBltMode", "ptr", this.hdc, "int", 4)                    ; HALFTONE
            DllCall("StretchBlt", "ptr", this.hdc, "int", 0, "int", 0, "int", this.ow, "int", this.oh
                , "ptr", hdcScreen, "int", this.x, "int", this.y, "int", this.w, "int", this.h
                , "uint", 0x40CC0020)
        }
        DllCall("ReleaseDC", "ptr", 0, "ptr", hdcScreen)
    }

    ; Encode the current buffer as PNG entirely in memory. Returns a Buffer.
    ToPng() {
        FischerGdi.Startup()
        pBitmap := 0
        rc := DllCall("gdiplus\GdipCreateBitmapFromScan0", "int", this.ow, "int", this.oh
            , "int", this.ow * 4, "int", 0x22009, "ptr", this.bits, "ptr*", &pBitmap)  ; 32bppRGB
        if (rc != 0 || !pBitmap)
            throw Error("GDI+ could not wrap the capture (code " rc ").")

        clsid := Buffer(16, 0)
        DllCall("ole32\CLSIDFromString", "wstr", "{557CF406-1A04-11D3-9A73-0000F81EF32E}", "ptr", clsid)  ; PNG encoder
        pStream := 0
        DllCall("ole32\CreateStreamOnHGlobal", "ptr", 0, "int", true, "ptr*", &pStream)
        rc := DllCall("gdiplus\GdipSaveImageToStream", "ptr", pBitmap, "ptr", pStream, "ptr", clsid, "ptr", 0)
        if (rc != 0) {
            ObjRelease(pStream)
            DllCall("gdiplus\GdipDisposeImage", "ptr", pBitmap)
            throw Error("GDI+ PNG encoding failed (code " rc ").")
        }

        ; IStream::Seek(0, STREAM_SEEK_CUR) tells us how many bytes were written.
        size := 0
        ComCall(5, pStream, "int64", 0, "uint", 1, "int64*", &size)
        hGlobal := 0
        DllCall("ole32\GetHGlobalFromStream", "ptr", pStream, "ptr*", &hGlobal)
        pMem := DllCall("GlobalLock", "ptr", hGlobal, "ptr")
        out := Buffer(size)
        DllCall("RtlMoveMemory", "ptr", out.Ptr, "ptr", pMem, "uptr", size)
        DllCall("GlobalUnlock", "ptr", hGlobal)
        ObjRelease(pStream)
        DllCall("gdiplus\GdipDisposeImage", "ptr", pBitmap)
        return out
    }

    Free() {
        if this.hbm {
            DllCall("SelectObject", "ptr", this.hdc, "ptr", this.old)
            DllCall("DeleteObject", "ptr", this.hbm)
            DllCall("DeleteDC", "ptr", this.hdc)
            this.hbm := 0
            this.hdc := 0
        }
    }

    __Delete() {
        this.Free()
    }
}


; ------------------------------------------------------------------------------
;  OCR through the Windows.Media.Ocr engine that ships with Windows 10 / 11.
;  A tiny PowerShell script is written to %TEMP% and run hidden for each read.
;  The capture is handed over as a temporary PNG which is deleted right after.
; ------------------------------------------------------------------------------
class FischerOcr {
    static ScriptPath := ""

    static _EnsureScript() {
        if (this.ScriptPath != "" && FileExist(this.ScriptPath))
            return
        path := A_Temp "\fischer_ocr_v1.ps1"
        script := "
        (LTrim
        param([string]$ImagePath, [string]$OutPath)
        $ErrorActionPreference = 'Stop'
        try {
            Add-Type -AssemblyName System.Runtime.WindowsRuntime
            $null = [Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime]
            $null = [Windows.Storage.Streams.IRandomAccessStream, Windows.Storage.Streams, ContentType = WindowsRuntime]
            $null = [Windows.Graphics.Imaging.BitmapDecoder, Windows.Graphics.Imaging, ContentType = WindowsRuntime]
            $null = [Windows.Graphics.Imaging.SoftwareBitmap, Windows.Graphics.Imaging, ContentType = WindowsRuntime]
            $null = [Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType = WindowsRuntime]
            $null = [Windows.Media.Ocr.OcrResult, Windows.Foundation, ContentType = WindowsRuntime]
            $opName = 'IAsyncOperation' + [char]96 + '1'
            $asTask = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq $opName })[0]
            function Await($op, $type) {
                $m = $asTask.MakeGenericMethod($type)
                $t = $m.Invoke($null, @($op))
                $t.Wait(-1) | Out-Null
                $t.Result
            }
            $file = Await ([Windows.Storage.StorageFile]::GetFileFromPathAsync($ImagePath)) ([Windows.Storage.StorageFile])
            $stream = Await ($file.OpenAsync([Windows.Storage.FileAccessMode]::Read)) ([Windows.Storage.Streams.IRandomAccessStream])
            $decoder = Await ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
            $bmp = Await ($decoder.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
            $engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()
            if ($null -eq $engine) { throw 'No OCR language pack installed' }
            $res = Await ($engine.RecognizeAsync($bmp)) ([Windows.Media.Ocr.OcrResult])
            $text = ($res.Lines | ForEach-Object { $_.Text }) -join [Environment]::NewLine
            [System.IO.File]::WriteAllText($OutPath, $text, [System.Text.Encoding]::UTF8)
        } catch {
            [System.IO.File]::WriteAllText($OutPath, 'FISCHER_OCR_ERROR: ' + $_.Exception.Message, [System.Text.Encoding]::UTF8)
        }
        )"
        f := FileOpen(path, "w", "UTF-8")
        f.Write(script)
        f.Close()
        this.ScriptPath := path
    }

    ; png : Buffer. Returns the recognized text, or "" when OCR is unavailable.
    static Recognize(png) {
        this._EnsureScript()
        stamp := A_TickCount "_" A_MSec
        img := A_Temp "\fischer_ocr_" stamp ".png"
        out := A_Temp "\fischer_ocr_" stamp ".txt"
        text := ""
        try {
            f := FileOpen(img, "w")
            f.RawWrite(png)
            f.Close()
            cmd := Format('powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{1}" -ImagePath "{2}" -OutPath "{3}"'
                , this.ScriptPath, img, out)
            pid := 0
            Run(cmd, , "Hide", &pid)
            t0 := A_TickCount
            while ProcessExist(pid) {
                Sleep(40)
                if (A_TickCount - t0 > 20000) {
                    ProcessClose(pid)
                    break
                }
            }
            if FileExist(out)
                text := FileRead(out, "UTF-8")
        }
        try FileDelete(img)
        try FileDelete(out)
        if (SubStr(text, 1, 17) = "FISCHER_OCR_ERROR")
            return ""
        return text
    }
}


; ------------------------------------------------------------------------------
;  Session statistics
; ------------------------------------------------------------------------------
class FishStats {
    static Caught := 0
    static Minigames := 0
    static Casts := 0
    static Rod := "Unknown"
    static Primary := "Unknown"
    static Secondary := "Unknown"
    static Level := 0
    static LevelAtLastReport := 0
    static Currency := ""
    static LevelPng := ""
    static LastInfoText := ""
    static LastLevelText := ""
    static StartTick := 0

    static Reset() {
        this.Caught := 0
        this.Minigames := 0
        this.Casts := 0
        this.Rod := "Unknown"
        this.Primary := "Unknown"
        this.Secondary := "Unknown"
        this.Level := 0
        this.LevelAtLastReport := 0
        this.Currency := ""
        this.LevelPng := ""
        this.StartTick := A_TickCount
    }

    ; Success rate = caught / minigames started (casts with no bite are not counted).
    static Rate() {
        return this.Minigames > 0 ? Round(this.Caught / this.Minigames * 100, 1) : 0.0
    }

    static LevelsGained() {
        if (this.Level > 0 && this.LevelAtLastReport > 0)
            return Max(0, this.Level - this.LevelAtLastReport)
        return 0
    }

    static MarkReported() {
        if (this.Level > 0)
            this.LevelAtLastReport := this.Level
    }
}


; ------------------------------------------------------------------------------
;  FishSolver : the macro engine
; ------------------------------------------------------------------------------
class FishSolver {
    static Active := false
    static Paused := false
    static StopRequested := false
    static Status := "Idle"
    static PrePauseStatus := "Fishing..."
    static MouseHeld := false
    static HeldKey := ""
    static ReportDue := false
    static LastProgressTick := 0
    static LastDisconnectCheck := 0

    ; Callbacks wired up by main.ahk
    static OnStatus := (*) => 0
    static OnCatch := (*) => 0
    static OnError := (*) => 0
    static OnReport := (*) => 0

    ; ==========================================================================
    ;  Lifecycle and control
    ; ==========================================================================

    static Start() {
        if this.Active
            return false
        this.Active := true
        this.Paused := false
        this.StopRequested := false
        this.ReportDue := false
        FishStats.Reset()
        SetTimer(ObjBindMethod(FishSolver, "Run"), -10)
        return true
    }

    ; Emergency stop: flags the engine, releases every input at once, resets to Idle.
    static Stop() {
        if !this.Active {
            this.SetStatus("Idle")
            return
        }
        this.StopRequested := true
        this.Paused := false
        this.ReleaseAll()
        this.SetStatus("Idle")
    }

    static TogglePause() {
        if !this.Active
            return
        if this.Paused {
            this.Paused := false
            this.SetStatus(this.PrePauseStatus)
        } else {
            this.PrePauseStatus := this.Status
            this.Paused := true
            this.ReleaseAll()
            this.SetStatus("Paused")
        }
    }

    static SetStatus(s) {
        if (this.Paused && s != "Paused") {
            this.PrePauseStatus := s      ; remember it, show it again on resume
            return
        }
        this.Status := s
        try this.OnStatus.Call(s)
    }

    ; Release the mouse button and any key that is mid-press. Safe to call anytime.
    static ReleaseAll() {
        if this.MouseHeld {
            this.MouseHeld := false
            try Click("Up")
        }
        if (this.HeldKey != "") {
            k := this.HeldKey
            this.HeldKey := ""
            try Send("{" k " up}")
        }
    }

    static SetHold(down) {
        if (down = this.MouseHeld)
            return
        if down {
            this.MouseHeld := true
            Click("Down")
        } else {
            this.MouseHeld := false
            Click("Up")
        }
    }

    static Coord() {
        CoordMode("Mouse", "Screen")
        CoordMode("Pixel", "Screen")
    }

    ; Called constantly by the engine. Throws StopMacro when stopped, blocks while
    ; paused, and waits (without stealing focus) while Roblox is not the active window.
    static Checkpoint() {
        if !this.Active
            return
        if this.StopRequested
            throw StopMacro("stopped")
        if this.Paused {
            this.ReleaseAll()
            while (this.Paused && !this.StopRequested)
                Sleep(40)
            if this.StopRequested
                throw StopMacro("stopped")
        }
        match := FischerConfig.Get("Game", "WindowMatch")
        if WinActive(match)
            return
        this.ReleaseAll()
        if !WinExist(match) {
            prev := this.Status
            this.SetStatus("Waiting for Roblox...")
            t := A_TickCount
            while !WinExist(match) {
                Sleep(250)
                if this.StopRequested
                    throw StopMacro("stopped")
                if (A_TickCount - t > 8000)
                    throw FischerFailure("Roblox window not found. The game was closed or you were disconnected.")
            }
            this.SetStatus(prev)
        }
        if !WinActive(match) {
            prev := this.Status
            this.SetStatus("Waiting for Roblox focus...")
            while !WinActive(match) {
                Sleep(150)
                if this.StopRequested
                    throw StopMacro("stopped")
            }
            this.SetStatus(prev)
        }
    }

    ; Sleep that stays responsive to Stop / Pause.
    static Wait(ms) {
        endTick := A_TickCount + ms
        while (A_TickCount < endTick) {
            this.Checkpoint()
            Sleep(Min(25, Max(1, endTick - A_TickCount)))
        }
    }

    ; ==========================================================================
    ;  Main loop
    ; ==========================================================================

    static Run() {
        failed := false
        this.Coord()
        try {
            this.SetStatus("Preparing...")
            this._PrepareGame()
            this._InitialScan()
            this.LastProgressTick := A_TickCount
            this.LastDisconnectCheck := A_TickCount
            loop {
                this.Checkpoint()
                this._Housekeeping()
                this.Cast()
                if this.ShakePhase() {
                    this.LastProgressTick := A_TickCount
                    FishStats.Minigames++
                    outcome := this.Minigame()
                    this.LastProgressTick := A_TickCount
                    if (outcome = "caught") {
                        FishStats.Caught++
                        try this.OnCatch.Call()
                    }
                }
                this.SetStatus("Fishing...")
                this.Wait(FischerConfig.Int("Timing", "PostCatchDelayMs"))
            }
        } catch StopMacro {
            ; normal stop requested by the user
        } catch FischerFailure as e {
            failed := true
            this._Fail(e.Message)
        } catch as e {
            failed := true
            this._Fail("Unexpected error: " e.Message " (line " e.Line ")")
        }
        this.ReleaseAll()
        this.Active := false
        this.Paused := false
        if !failed
            this.SetStatus("Idle")
    }

    static _Fail(msg) {
        this.ReleaseAll()
        this.SetStatus("Error")
        try this.OnError.Call(msg)
    }

    static _PrepareGame() {
        match := FischerConfig.Get("Game", "WindowMatch")
        if !WinExist(match)
            throw FischerFailure("Roblox window not found. Open Fisch first. (Window match: " match ")")
        WinActivate(match)
        if !WinWaitActive(match, , 3)
            throw FischerFailure("Could not bring the Roblox window to the front.")
        this.CenterMouse()
    }

    static CenterMouse() {
        match := FischerConfig.Get("Game", "WindowMatch")
        if WinExist(match) {
            WinGetPos(&x, &y, &w, &h, match)
            MouseMove(x + w // 2, y + h // 2, 0)
        }
    }

    static _InitialScan() {
        if this.RegionValid("Info") || this.RegionValid("Level") {
            this.SetStatus("Scanning...")
            this.ScanEquipment()
            if this.ScanLevel()
                FishStats.LevelAtLastReport := FishStats.Level
            this.CenterMouse()
        }
    }

    ; Periodic checks that happen between casts (never while a button is held).
    static _Housekeeping() {
        if this.ReportDue {
            this.ReportDue := false
            this.DoReport()
        }
        stuckMs := FischerConfig.Int("Game", "StuckTimeoutSec") * 1000
        if (stuckMs > 0 && A_TickCount - this.LastProgressTick > stuckMs)
            throw FischerFailure("Macro appears stuck: no bite or catch for " (stuckMs // 1000) " seconds. Check calibration and shake keys.")
        dcSec := FischerConfig.Int("Game", "DisconnectOcrCheckSec")
        if (dcSec > 0 && A_TickCount - this.LastDisconnectCheck > dcSec * 1000) {
            this.LastDisconnectCheck := A_TickCount
            this.CheckDisconnect()
        }
    }

    ; OCR the middle of the Roblox window and look for the disconnect dialog.
    static CheckDisconnect() {
        match := FischerConfig.Get("Game", "WindowMatch")
        if !WinExist(match) || WinGetMinMax(match) = -1
            return
        WinGetPos(&x, &y, &w, &h, match)
        if (w < 200 || h < 200)
            return
        gr := ScreenGrabber(x + w // 4, y + h // 4, w // 2, h // 2, 1)
        try {
            gr.Grab()
            png := gr.ToPng()
        } finally {
            gr.Free()
        }
        text := FischerOcr.Recognize(png)
        if RegExMatch(text, "i)disconnect|reconnect|error\s*code|lost\s+connection")
            throw FischerFailure("Disconnected from the game (Roblox disconnect dialog detected).")
    }

    static DoReport() {
        prev := this.Status
        this.SetStatus("Scanning...")
        this.ScanEquipment()
        this.ScanLevel()
        this.CenterMouse()
        this.SetStatus(prev = "Scanning..." ? "Fishing..." : prev)
        try this.OnReport.Call()
    }

    ; ==========================================================================
    ;  Casting, shaking, minigame
    ; ==========================================================================

    ; Hold left click for CastHoldTimeMs.
    static Cast() {
        this.SetStatus("Fishing...")
        this.Checkpoint()
        FishStats.Casts++
        this.SetHold(true)
        try {
            this.Wait(FischerConfig.Int("Timing", "CastHoldTimeMs"))
        } finally {
            this.SetHold(false)
        }
    }

    ; Click the shake button (found by color) until the reel bar shows up.
    ; Optional extra keys from Shake.Keys are also tapped each cycle.
    ; Returns true when the minigame is detected, false on bite timeout.
    static ShakePhase() {
        this.SetStatus("Fishing...")
        this.Wait(FischerConfig.Int("Timing", "CastWaitMs"))

        r := this.Region("ReelBar")
        w := r.R - r.L
        gr := ScreenGrabber(r.L, r.T, w, r.B - r.T)
        ctx := this._MakeScanCtx(w)

        ; The shake button can appear anywhere, so search the whole Roblox window.
        match := FischerConfig.Get("Game", "WindowMatch")
        WinGetPos(&wx, &wy, &ww, &wh, match)
        sx := Max(0, wx)
        sy := Max(0, wy)
        sw := Min(A_ScreenWidth, wx + ww) - sx
        sh := Min(A_ScreenHeight, wy + wh) - sy
        if (sw < 50 || sh < 50)
            throw FischerFailure("The Roblox window is not visible on the primary monitor.")
        sstep := Max(1, FischerConfig.Int("Scanner", "ShakeStep"))
        sg := ScreenGrabber(sx, sy, sw, sh)
        scols := (sw + sstep - 1) // sstep
        srows := (sh + sstep - 1) // sstep
        colBuf := Buffer(scols * 2, 0)
        rowBuf := Buffer(srows * 2, 0)

        keys := []
        for part in StrSplit(FischerConfig.Get("Shake", "Keys"), ",") {
            part := Trim(part)
            if (part != "")
                keys.Push(part)
        }
        interval := Max(10, FischerConfig.Int("Shake", "KeyIntervalMs"))
        timeout := FischerConfig.Int("Timing", "CastTimeoutMs")
        t0 := A_TickCount
        found := false
        try {
            loop {
                this.Checkpoint()
                if (A_TickCount - t0 > timeout)
                    break
                gr.Grab()
                this._Scan(gr, ctx)
                if ctx.fish {
                    found := true
                    break
                }
                sg.Grab()
                pt := this.FindShake(sg, sx, sy, colBuf, rowBuf, sstep, scols, srows)
                if pt {
                    this.Checkpoint()
                    MouseMove(Round(pt.x), Round(pt.y), 0)
                    this.Wait(30)
                    Click()
                }
                for k in keys {
                    this.Checkpoint()
                    this.PressKey(k)
                }
                this.Wait(interval)
            }
        } finally {
            gr.Free()
            sg.Free()
        }
        return found
    }

    ; Find the shake button: the densest cluster of pixels matching the calibrated
    ; shake color. Returns {x, y} in screen coordinates, or 0 when not found.
    static FindShake(sg, ox, oy, colBuf, rowBuf, step, cols, rows) {
        DllCall("RtlZeroMemory", "ptr", colBuf.Ptr, "uptr", colBuf.Size)
        DllCall("RtlZeroMemory", "ptr", rowBuf.Ptr, "uptr", rowBuf.Size)
        sc := FischerConfig.Int("Colors", "ShakeColor")
        sR := (sc >> 16) & 0xFF
        sG := (sc >> 8) & 0xFF
        sB := sc & 0xFF
        tol := FischerConfig.Int("Colors", "Tolerance")
        minPx := Max(1, FischerConfig.Int("Scanner", "ShakeMinPixels"))
        bits := sg.bits
        w := sg.w
        h := sg.h
        total := 0
        y := 0
        while (y < h) {
            rowOff := y * w * 4
            x := 0
            while (x < w) {
                px := NumGet(bits, rowOff + x * 4, "UInt")
                if (Abs(((px >> 16) & 0xFF) - sR) <= tol && Abs(((px >> 8) & 0xFF) - sG) <= tol && Abs((px & 0xFF) - sB) <= tol) {
                    co := (x // step) * 2
                    ro := (y // step) * 2
                    NumPut("UShort", NumGet(colBuf, co, "UShort") + 1, colBuf, co)
                    NumPut("UShort", NumGet(rowBuf, ro, "UShort") + 1, rowBuf, ro)
                    total++
                }
                x += step
            }
            y += step
        }
        if (total < minPx)
            return 0
        cr := this._BestRun(colBuf, cols, 2)
        rr := this._BestRun(rowBuf, rows, 2)
        if (!cr || !rr || cr.hits < minPx)
            return 0
        return {x: ox + (cr.s + cr.e) / 2 * step, y: oy + (rr.s + rr.e) / 2 * step}
    }

    ; Tap one key. Accepts single keys (s), key names (enter, space) or a full
    ; AHK token such as {Enter}.
    static PressKey(key) {
        key := Trim(key)
        if (key = "")
            return
        try {
            if (SubStr(key, 1, 1) = "{" && StrLen(key) > 2 && SubStr(key, -1) = "}") {
                Send(key)
            } else if (key = "{" || key = "}") {
                Send("{" key "}")
            } else {
                this.HeldKey := key
                Send("{" key " down}")
                Sleep(12)
                Send("{" key " up}")
                this.HeldKey := ""
            }
        } catch as e {
            this.HeldKey := ""
            throw FischerFailure("Invalid shake key '" key "': " e.Message)
        }
    }

    ; The refined bar solver.
    ;   Every scan finds the fish icon and the slider inside the reel bar region.
    ;   The fish position is extrapolated a few frames ahead from its velocity.
    ;   Fish right of the slider -> hold left mouse; fish left of it -> release;
    ;   inside the deadzone -> pulse the button every ClickResponseMs so the
    ;   slider stays centered under the fish.
    ; Returns "caught" or "missed".
    static Minigame() {
        this.SetStatus("Minigame Active")
        r := this.Region("ReelBar")
        w := r.R - r.L
        gr := ScreenGrabber(r.L, r.T, w, r.B - r.T)
        ctx := this._MakeScanCtx(w)

        scanMs := Max(1, FischerConfig.Int("Timing", "ScanIntervalMs"))
        deadzone := FischerConfig.Int("Timing", "HoldDeadzonePx")
        respMs := Max(5, FischerConfig.Int("Timing", "ClickResponseMs"))
        predict := FischerConfig.Int("Timing", "PredictFrames")
        endGrace := FischerConfig.Int("Timing", "EndGraceMs")
        minCatch := FischerConfig.Int("Timing", "MinCatchMs")
        timeout := FischerConfig.Int("Timing", "MinigameTimeoutMs")

        startTick := A_TickCount
        lastSeen := startTick
        haveFish := false
        prevFish := 0.0
        haveSlider := false
        sliderPx := 0.0
        lastToggle := 0
        prevSlider := 0.0
        lastMove := startTick
        staticEnd := FischerConfig.Int("Timing", "StaticEndMs")
        outcome := "missed"
        try {
            loop {
                this.Checkpoint()
                now := A_TickCount
                if (now - startTick > timeout)
                    break
                gr.Grab()
                this._Scan(gr, ctx)
                ; The minigame is only "on screen" while the fish AND (once seen) the slider are found.
                visible := ctx.fish && (ctx.slider || !haveSlider)
                if visible {
                    lastSeen := now
                    fishPx := (ctx.fish.s + ctx.fish.e) / 2 * ctx.step
                    prevSlider := sliderPx
                    if ctx.slider {
                        sliderPx := (ctx.slider.s + ctx.slider.e) / 2 * ctx.step
                        haveSlider := true
                    }
                    ; Frozen detection: leftover UI that matches the colors never moves.
                    if (!haveFish || Abs(fishPx - prevFish) > 2 || Abs(sliderPx - prevSlider) > 2)
                        lastMove := now
                    else if (now - lastMove > staticEnd) {
                        outcome := ((lastMove - startTick) >= minCatch) ? "caught" : "missed"
                        break
                    }
                    velocity := haveFish ? fishPx - prevFish : 0
                    prevFish := fishPx
                    haveFish := true
                    if haveSlider {
                        err := (fishPx + velocity * predict) - sliderPx
                        if (err > deadzone) {
                            want := true
                        } else if (err < -deadzone) {
                            want := false
                        } else {
                            want := (now - lastToggle >= respMs) ? !this.MouseHeld : this.MouseHeld
                        }
                    } else {
                        ; slider not visible: pulse so it keeps moving until it shows up
                        want := (now - lastToggle >= respMs) ? !this.MouseHeld : this.MouseHeld
                    }
                    if (want != this.MouseHeld) {
                        this.SetHold(want)
                        lastToggle := now
                    }
                } else if (now - lastSeen > endGrace) {
                    outcome := ((lastSeen - startTick) >= minCatch) ? "caught" : "missed"
                    break
                }
                Sleep(scanMs)
            }
        } finally {
            this.SetHold(false)
            gr.Free()
        }
        return outcome
    }

    ; ==========================================================================
    ;  Pixel scanning
    ; ==========================================================================

    ; "0xRRGGBB,0xRRGGBB" -> [[r,g,b], ...]. Invalid entries are skipped.
    static _ParseColors(str, fallback) {
        list := []
        for part in StrSplit(str, ",", " `t") {
            if (part != "" && IsInteger(part)) {
                c := Integer(part)
                list.Push([(c >> 16) & 0xFF, (c >> 8) & 0xFF, c & 0xFF])
            }
        }
        if (list.Length = 0)
            list.Push([(fallback >> 16) & 0xFF, (fallback >> 8) & 0xFF, fallback & 0xFF])
        return list
    }

    static _MakeScanCtx(w) {
        step := Max(1, FischerConfig.Int("Timing", "ScanStep"))
        cols := (w + step - 1) // step
        return {
            step: step,
            cols: cols,
            tol: FischerConfig.Int("Colors", "Tolerance"),
            minHits: Max(1, FischerConfig.Int("Colors", "MinMatchPixels")),
            fishList: this._ParseColors(FischerConfig.Get("Colors", "FishColor"), 0xFFFFFF),
            sliderList: this._ParseColors(FischerConfig.Get("Colors", "SliderColor"), 0xB4B4B4),
            fishBuf: Buffer(cols * 2, 0),
            sliderBuf: Buffer(cols * 2, 0),
            fish: 0,
            slider: 0
        }
    }

    ; Scan the captured bar. Fills c.fish and c.slider with {s, e, hits} column
    ; runs (or 0 when the color was not found).
    static _Scan(gr, c) {
        DllCall("RtlZeroMemory", "ptr", c.fishBuf.Ptr, "uptr", c.fishBuf.Size)
        DllCall("RtlZeroMemory", "ptr", c.sliderBuf.Ptr, "uptr", c.sliderBuf.Size)
        bits := gr.bits
        w := gr.w
        h := gr.h
        step := c.step
        tol := c.tol
        fishList := c.fishList
        sliderList := c.sliderList
        fishBuf := c.fishBuf
        sliderBuf := c.sliderBuf
        y := 0
        while (y < h) {
            rowOff := y * w * 4
            x := 0
            while (x < w) {
                px := NumGet(bits, rowOff + x * 4, "UInt")
                pr := (px >> 16) & 0xFF
                pg := (px >> 8) & 0xFF
                pb := px & 0xFF
                hit := 0
                for col in fishList {
                    if (Abs(pr - col[1]) <= tol && Abs(pg - col[2]) <= tol && Abs(pb - col[3]) <= tol) {
                        hit := 1
                        break
                    }
                }
                if !hit {
                    for col in sliderList {
                        if (Abs(pr - col[1]) <= tol && Abs(pg - col[2]) <= tol && Abs(pb - col[3]) <= tol) {
                            hit := 2
                            break
                        }
                    }
                }
                if (hit = 1) {
                    o := (x // step) * 2
                    NumPut("UShort", NumGet(fishBuf, o, "UShort") + 1, fishBuf, o)
                } else if (hit = 2) {
                    o := (x // step) * 2
                    NumPut("UShort", NumGet(sliderBuf, o, "UShort") + 1, sliderBuf, o)
                }
                x += step
            }
            y += step
        }
        fish := this._BestRun(fishBuf, c.cols, 2)
        if (fish && fish.hits < c.minHits)
            fish := 0
        c.fish := fish
        c.slider := this._BestRun(sliderBuf, c.cols, 3)
    }

    ; Heaviest run of non-empty columns (gaps up to gapMax columns are bridged).
    static _BestRun(buf, cols, gapMax) {
        bestHits := 0
        bestS := -1
        bestE := -1
        curS := -1
        curE := -1
        curHits := 0
        gap := 0
        c := 0
        while (c < cols) {
            n := NumGet(buf, c * 2, "UShort")
            if (n > 0) {
                if (curS < 0)
                    curS := c
                curE := c
                curHits += n
                gap := 0
            } else if (curS >= 0) {
                gap++
                if (gap > gapMax) {
                    if (curHits > bestHits) {
                        bestHits := curHits
                        bestS := curS
                        bestE := curE
                    }
                    curS := -1
                    curHits := 0
                    gap := 0
                }
            }
            c++
        }
        if (curS >= 0 && curHits > bestHits) {
            bestHits := curHits
            bestS := curS
            bestE := curE
        }
        return bestHits > 0 ? {s: bestS, e: bestE, hits: bestHits} : 0
    }

    ; ==========================================================================
    ;  Regions
    ; ==========================================================================

    static Region(prefix) {
        return {
            L: FischerConfig.Int("Regions", prefix "L"),
            T: FischerConfig.Int("Regions", prefix "T"),
            R: FischerConfig.Int("Regions", prefix "R"),
            B: FischerConfig.Int("Regions", prefix "B")
        }
    }

    static RegionValid(prefix) {
        r := this.Region(prefix)
        return (r.R - r.L >= 4) && (r.B - r.T >= 4)
    }

    ; ==========================================================================
    ;  OCR scanners: hotbar / equipment and level
    ; ==========================================================================

    ; Capture a configured region (enlarged for OCR) and read it.
    ; Returns {text, png}.
    static OcrRegion(prefix) {
        r := this.Region(prefix)
        scale := Max(1, FischerConfig.Int("Scanner", "OcrScale"))
        gr := ScreenGrabber(r.L, r.T, r.R - r.L, r.B - r.T, scale)
        try {
            gr.Grab()
            png := gr.ToPng()
        } finally {
            gr.Free()
        }
        return {text: FischerOcr.Recognize(png), png: png}
    }

    ; Hover hotbar slot 1 so its tooltip appears, then read rod name and enchants.
    static ScanEquipment() {
        if !this.RegionValid("Info")
            return false
        this.Coord()
        MouseGetPos(&ox, &oy)
        hx := FischerConfig.Int("Regions", "HotbarX")
        hy := FischerConfig.Int("Regions", "HotbarY")
        if (hx > 0 && hy > 0) {
            MouseMove(hx, hy, 0)
            this.Wait(FischerConfig.Int("Scanner", "HoverDelayMs"))
        }
        res := this.OcrRegion("Info")
        MouseMove(ox, oy, 0)
        FishStats.LastInfoText := res.text
        info := this.ParseEquipment(res.text)
        if (info.rod = "")
            return false
        FishStats.Rod := info.rod
        FishStats.Primary := info.primary
        FishStats.Secondary := info.secondary
        return true
    }

    ; First usable line = rod name. Following usable lines = enchants.
    ; Stat lines (Lure, Luck, Control, anything with digits or %) are ignored.
    ; Missing enchants become "None".
    static ParseEquipment(text) {
        rod := ""
        enchants := []
        for line in StrSplit(text, "`n", "`r") {
            line := Trim(line)
            line := Trim(RegExReplace(line, "i)^enchants?\s*[:\-]\s*", ""))
            if (StrLen(line) < 3)
                continue
            if RegExMatch(line, "i)^(lure|luck|control|resilience|max\.?\s*weight|strength|durability|passive|stats?|rarity|abilit|description)")
                continue
            if RegExMatch(line, "[\d%]")
                continue
            if (rod = "")
                rod := line
            else
                enchants.Push(line)
        }
        return {
            rod: rod,
            primary: enchants.Length >= 1 ? enchants[1] : "None",
            secondary: enchants.Length >= 2 ? enchants[2] : "None"
        }
    }

    ; Read "Level 1079" (and the currency amount, if visible) from the bottom-right UI.
    static ScanLevel() {
        if !this.RegionValid("Level")
            return false
        res := this.OcrRegion("Level")
        text := res.text
        FishStats.LastLevelText := text
        if (res.png is Buffer)
            FishStats.LevelPng := res.png
        lvl := 0
        if RegExMatch(text, "i)le\w{0,3}l\D{0,3}(\d[\d,\.]*)", &m)
            lvl := Integer(RegExReplace(m[1], "\D"))
        else if RegExMatch(text, "(\d[\d,\.]*)", &m2)
            lvl := Integer(RegExReplace(m2[1], "\D"))
        if RegExMatch(text, "i)(?:c?\$)\s*(\d[\d,\.]*\s*[kmbt]?)", &c)
            FishStats.Currency := Trim(c[1])
        if (lvl > 0) {
            FishStats.Level := lvl
            if (FishStats.LevelAtLastReport = 0)
                FishStats.LevelAtLastReport := lvl
            return true
        }
        return false
    }

    ; PNG of the Roblox window (or the primary screen) for failure alerts. Memory only.
    static ScreenshotPng() {
        x := 0
        y := 0
        w := A_ScreenWidth
        h := A_ScreenHeight
        match := FischerConfig.Get("Game", "WindowMatch")
        if (WinExist(match) && WinGetMinMax(match) != -1) {
            WinGetPos(&wx, &wy, &ww, &wh, match)
            if (ww > 100 && wh > 100) {
                x := wx
                y := wy
                w := ww
                h := wh
            }
        }
        try {
            gr := ScreenGrabber(x, y, w, h)
            try {
                gr.Grab()
                return gr.ToPng()
            } finally {
                gr.Free()
            }
        } catch {
            return ""
        }
    }
}
