; ============================================================================
; Fisch Macro - main.ahk
; Entry point: dark, cobalt.tools-inspired GUI + macro loop.
;
; Hotkeys:  F2 calibrate (fish icon)   F3 calibrate player bar color (optional)
;           F8 start / stop            F12 exit
;
; Files:    lib/Json.ahk        tiny JSON reader/writer
;           lib/FishSolver.ahk  pixel detection, minigame solver, calibration
;           lib/Webhook.ahk     Discord webhook, reports, in-memory screenshots
;           config.json         saved settings (created on first run)
;
; Licensed under the MIT License (see LICENSE).
; ============================================================================
#Requires AutoHotkey v2.0
#SingleInstance Force
#Include lib/Json.ahk
#Include lib/FishSolver.ahk
#Include lib/Webhook.ahk

SetWorkingDir(A_ScriptDir)
CoordMode("Mouse", "Screen")
CoordMode("Pixel", "Screen")

class FischApp {
    static VERSION := "1.0.0"
    static CONFIG_PATH := A_ScriptDir "\config.json"

    ; Palette (hex RRGGBB, inspired by cobalt.tools)
    static BG := "121214"
    static PANEL := "1B1B1F"
    static BORDER := "2C2C33"
    static TEXT := "F4F4F5"
    static MUTED := "8B8B93"
    static ACCENT := "4F8CFF"
    static GOOD := "4ADE80"
    static WARN := "FBBF24"
    static BAD := "FF5C5C"
    static FONT := "Consolas"

    static BOOL_KEYS := ["WebhookEnabled", "ReportEnabled", "PingOnError", "ScreenshotOnFailure", "Calibrated"]
    static INTERVALS := [15, 30, 60, 120]

    ; ---- setup --------------------------------------------------------------

    static Defaults() {
        return Map(
            "CastHoldTimeMs", 800,
            "ColorTolerance", 20,
            "ScanDelayMs", 25,
            "CatchTimeoutSec", 180,
            "BiteWaitSec", 25,
            "Deadzone", 12,
            "BandHalfHeight", 10,
            "BandMinRelX", 0.2,
            "BandMaxRelX", 0.8,
            "NavKey", "\",
            "ShakeKey", "Enter",
            "WebhookUrl", "",
            "WebhookEnabled", 0,
            "ReportEnabled", 1,
            "ReportIntervalMin", 60,
            "RodName", "Unknown",
            "PingOnError", 0,
            "PingTarget", "@everyone",
            "ScreenshotOnFailure", 1,
            "Calibrated", 0,
            "CalX", 0,
            "CalY", 0,
            "CalRelX", 0.5,
            "CalRelY", 0.8,
            "CalFishColor", "0xFFFFFF",
            "CalBarColor", "0xFFFFFF"
        )
    }

    __New() {
        this.cfg := FischApp.Defaults()
        this.cfgError := ""
        this.LoadConfig()
        this.solver := FishSolver(this.cfg)

        this.running := false
        this.paused := false
        this.loopActive := false
        this.startTick := 0
        this.lastCatchTick := 0
        this.logLines := 0
        this.cd := 0
        this.interval := Integer(this.cfg["ReportIntervalMin"])
        this.stats := Map("totalCaught", 0, "totalAttempts", 0, "intervalCaught", 0, "intervalAttempts", 0)

        this.pages := [[], [], [], []]
        this.tabCtrls := []
        this.tabX := []
        this.toggles := Map()
        this.chips := []
        this.numFields := Map()
        this.numLimits := Map()

        this.loopFn := ObjBindMethod(this, "RunLoop")
        this.reportFn := ObjBindMethod(this, "ReportTick")
        this.cdFn := ObjBindMethod(this, "CountdownTick")

        this.BuildGui()
        this.RefreshCalibrationView()
        this.SwitchTab(1)
        this.g.Show("w560 h630")

        Hotkey("F2", (*) => this.OnCalibrateKey("fish"))
        Hotkey("F3", (*) => this.OnCalibrateKey("bar"))
        Hotkey("F8", (*) => this.ToggleRun())
        Hotkey("F12", (*) => this.Quit())
        SetTimer(ObjBindMethod(this, "TickUi"), 1000)

        if !FileExist(FischApp.CONFIG_PATH)
            this.SaveConfig()
        if this.cfgError != ""
            this.Log(this.cfgError)
        this.Log("Ready. Calibrate with F2, then press Start (or F8).")
        this.TickUi()
    }

    ; ---- config -------------------------------------------------------------

    LoadConfig() {
        if !FileExist(FischApp.CONFIG_PATH)
            return
        try {
            data := Json.Parse(FileRead(FischApp.CONFIG_PATH, "UTF-8"))
            for k, v in data {
                if this.cfg.Has(k)
                    this.cfg[k] := v
            }
        } catch as e {
            this.cfgError := "config.json could not be read (" e.Message "). Using defaults."
        }
    }

    SaveConfig() {
        try {
            f := FileOpen(FischApp.CONFIG_PATH, "w", "UTF-8-RAW")
            f.Write(Json.Dump(this.cfg, FischApp.BOOL_KEYS) "`n")
            f.Close()
            return true
        } catch as e {
            this.Log("Could not write config.json: " e.Message)
            return false
        }
    }

    ; ---- GUI building blocks ------------------------------------------------

    Put(page, type, opts, text := "") {
        c := this.g.Add(type, opts, text)
        this.pages[page].Push(c)
        return c
    }

    Style(ctrl, opts) {
        ctrl.SetFont(opts, FischApp.FONT)
    }

    Section(page, y, text) {
        c := this.Put(page, "Text", "x24 y" y " w512 h18", text)
        this.Style(c, "s8 c" FischApp.MUTED)
        return c
    }

    Note(page, opts, text) {
        c := this.Put(page, "Text", opts, text)
        this.Style(c, "s8 c" FischApp.MUTED)
        return c
    }

    Button(page, opts, text, bg, fg, handler) {
        c := this.Put(page, "Text", opts " +0x200 +0x100 Center Background" bg, text)
        this.Style(c, "s10 bold c" fg)
        c.OnEvent("Click", handler)
        return c
    }

    Input(page, opts, text := "") {
        return this.Put(page, "Edit", opts " -E0x200 +Border Background" FischApp.PANEL " c" FischApp.TEXT, text)
    }

    AddToggle(page, y, label, key) {
        c := this.Put(page, "Text", "x24 y" y " w512 h26 +0x200 +0x100", "")
        t := { ctrl: c, label: label, key: key, on: !!this.cfg[key] }
        this.toggles[key] := t
        this.RenderToggle(t)
        c.OnEvent("Click", this.FlipToggle.Bind(this, t))
        return t
    }

    FlipToggle(t, *) {
        t.on := !t.on
        this.RenderToggle(t)
    }

    RenderToggle(t) {
        t.ctrl.Value := (t.on ? "[x]  " : "[ ]  ") t.label
        this.Style(t.ctrl, "s10 c" (t.on ? FischApp.ACCENT : FischApp.TEXT))
    }

    SelectInterval(v, *) {
        this.interval := v
        this.RenderChips()
    }

    RenderChips() {
        for m in this.chips {
            sel := (m["v"] = this.interval)
            m["c"].Opt("Background" (sel ? FischApp.ACCENT : FischApp.PANEL))
            this.Style(m["c"], "s10 c" (sel ? "FFFFFF" : FischApp.MUTED))
            m["c"].Redraw()
        }
    }

    ; ---- GUI ----------------------------------------------------------------

    BuildGui() {
        g := Gui("-MaximizeBox", "Fisch Macro")
        this.g := g
        g.BackColor := FischApp.BG
        g.SetFont("s10 c" FischApp.TEXT, FischApp.FONT)
        g.OnEvent("Close", (*) => this.Quit())

        ; Dark title bar (Windows 10 2004+ / 11); ignored where unsupported.
        dark := Buffer(4, 0)
        NumPut("Int", 1, dark)
        try DllCall("dwmapi\DwmSetWindowAttribute", "Ptr", g.Hwnd, "Int", 20, "Ptr", dark, "Int", 4)

        title := g.Add("Text", "x24 y14 w400 h34", "FISCH MACRO")
        this.Style(title, "s18 bold c" FischApp.ACCENT)
        sub := g.Add("Text", "x24 y50 w512 h20", "auto-fisher for Roblox Fisch  |  v" FischApp.VERSION)
        this.Style(sub, "s9 c" FischApp.MUTED)

        ; Custom tab bar (native tab controls cannot be themed dark).
        names := ["Control", "Settings", "Webhook && Reports", "Calibration"]
        widths := [100, 110, 190, 112]
        this.tabW := widths
        x := 24
        for i, name in names {
            this.tabX.Push(x)
            c := g.Add("Text", "x" x " y82 w" widths[i] " h30 +0x200 +0x100 Center", name)
            c.OnEvent("Click", this.SwitchTab.Bind(this, i))
            this.tabCtrls.Push(c)
            x += widths[i]
        }
        this.tabLine := g.Add("Text", "x24 y112 w100 h2 Background" FischApp.ACCENT)
        g.Add("Text", "x24 y114 w512 h1 Background" FischApp.BORDER)

        ; Status bar
        g.Add("Text", "x24 y588 w512 h1 Background" FischApp.BORDER)
        this.footer := g.Add("Text", "x24 y596 w512 h22", "Status: Idle")
        this.Style(this.footer, "s9 c" FischApp.MUTED)

        this.BuildControlPage()
        this.BuildSettingsPage()
        this.BuildWebhookPage()
        this.BuildCalibrationPage()
    }

    BuildControlPage() {
        this.Section(1, 130, "CURRENT STATE")
        this.statusTxt := this.Put(1, "Text", "x24 y150 w512 h34", "Status: Idle")
        this.Style(this.statusTxt, "s16 bold c" FischApp.MUTED)
        this.statsTxt := this.Put(1, "Text", "x24 y190 w512 h22", "")
        this.Style(this.statsTxt, "s9 c" FischApp.MUTED)

        this.startBtn := this.Button(1, "x24 y226 w250 h40", "Start Macro", FischApp.ACCENT, "FFFFFF", this.ToggleRun.Bind(this))
        this.pauseBtn := this.Button(1, "x286 y226 w250 h40 +Border", "Pause / Resume", FischApp.PANEL, FischApp.TEXT, this.TogglePause.Bind(this))

        this.Section(1, 284, "ACTIVITY LOG")
        this.logBox := this.Input(1, "x24 y304 w512 h236 Multi ReadOnly VScroll")
        this.Note(1, "x24 y550 w512 h20", "F8 start / stop     F2 calibrate     F12 exit")
    }

    BuildSettingsPage() {
        rows := [
            ["CastHoldTimeMs", "Cast hold time (ms)", "How long left click is held to cast.", 50, 10000],
            ["ColorTolerance", "Color tolerance (0-255)", "Higher = more forgiving color matching.", 0, 255],
            ["ScanDelayMs", "Scan delay (ms)", "Pause between screen scans. Lower = faster.", 5, 500],
            ["CatchTimeoutSec", "No-catch timeout (s)", "Send an alert if nothing is caught in this time.", 30, 3600],
            ["BiteWaitSec", "Bite wait limit (s)", "Recast if no bite shows up in this time.", 5, 120]
        ]
        y := 134
        for r in rows {
            this.Put(2, "Text", "x24 y" y " w340 h22", r[2])
            this.Note(2, "x24 y" (y + 22) " w350 h18", r[3])
            this.numFields[r[1]] := this.Input(2, "x384 y" (y + 4) " w152 h28", this.cfg[r[1]])
            this.numLimits[r[1]] := [r[4], r[5], r[2]]
            y += 58
        }
        this.Button(2, "x24 y444 w512 h40", "Save Settings", FischApp.ACCENT, "FFFFFF", this.OnSave.Bind(this))
        this.setMsg := this.Put(2, "Text", "x24 y494 w512 h40", "")
        this.Style(this.setMsg, "s9 c" FischApp.MUTED)
    }

    BuildWebhookPage() {
        this.Section(3, 134, "DISCORD WEBHOOK URL")
        this.urlEdit := this.Input(3, "x24 y154 w512 h28", this.cfg["WebhookUrl"])
        this.Button(3, "x24 y192 w160 h34 +Border", "Test Webhook", FischApp.PANEL, FischApp.TEXT, this.OnTestWebhook.Bind(this))
        this.testMsg := this.Put(3, "Text", "x196 y199 w340 h22", "")
        this.Style(this.testMsg, "s9 c" FischApp.MUTED)
        this.AddToggle(3, 238, "Enable webhooks", "WebhookEnabled")

        this.Section(3, 280, "REPORTS")
        this.AddToggle(3, 300, "Send Fischer Report summaries", "ReportEnabled")
        this.Put(3, "Text", "x24 y338 w190 h22 +0x200", "Interval (minutes)")
        x := 220
        for v in FischApp.INTERVALS {
            c := this.Put(3, "Text", "x" x " y334 w60 h28 +0x200 +0x100 Center +Border", v)
            c.OnEvent("Click", this.SelectInterval.Bind(this, v))
            this.chips.Push(Map("v", v, "c", c))
            x += 70
        }
        this.RenderChips()
        this.Put(3, "Text", "x24 y376 w190 h22 +0x200", "Rod equipped")
        this.rodEdit := this.Input(3, "x220 y372 w316 h28", this.cfg["RodName"])

        this.Section(3, 416, "ERROR && DISCONNECT ALERTS")
        this.AddToggle(3, 436, "Ping me on Error / Disconnect", "PingOnError")
        this.Put(3, "Text", "x24 y474 w190 h22 +0x200", "Ping target")
        this.pingEdit := this.Input(3, "x220 y470 w316 h28", this.cfg["PingTarget"])
        this.AddToggle(3, 506, "Send in-memory screenshot on failure", "ScreenshotOnFailure")

        this.Button(3, "x24 y544 w512 h36", "Save Settings", FischApp.ACCENT, "FFFFFF", this.OnSave.Bind(this))
    }

    BuildCalibrationPage() {
        this.Section(4, 130, "QUICK SETUP  (about 10 seconds)")
        steps := "1.  Open Roblox Fisch and equip your fishing rod.`n`n"
            . "2.  Cast, and when the reel minigame appears, hover your`n    mouse over the FISH ICON on the reel bar.`n`n"
            . "3.  Press F2. Done - the macro learns where the fish`n    is and what color it is."
        this.Put(4, "Text", "x24 y154 w512 h150", steps)

        this.Button(4, "x24 y314 w512 h36 +Border", "Start 5-second countdown instead of F2", FischApp.PANEL, FischApp.TEXT, this.StartCountdown.Bind(this))
        this.calHint := this.Put(4, "Text", "x24 y358 w512 h22", "")
        this.Style(this.calHint, "s9 c" FischApp.WARN)

        this.calSwatch := this.Put(4, "Text", "x24 y396 w28 h28 +Border Background" FischApp.PANEL, "")
        this.calText := this.Put(4, "Text", "x64 y399 w472 h24", "Not calibrated yet.")
        this.Style(this.calText, "s10 bold c" FischApp.WARN)

        this.Section(4, 448, "ADVANCED (OPTIONAL)")
        this.Note(4, "x24 y468 w512 h36", "Hover over the white player bar and press F3 to capture its color. The default is white, which works for most setups.")
        this.barText := this.Put(4, "Text", "x24 y512 w512 h22", "")
        this.Style(this.barText, "s9 c" FischApp.MUTED)
    }

    SwitchTab(i, *) {
        for j, pg in this.pages {
            for c in pg
                c.Visible := (j = i)
        }
        for j, t in this.tabCtrls
            this.Style(t, "s10 c" (j = i ? FischApp.TEXT : FischApp.MUTED))
        this.tabLine.Move(this.tabX[i], 112, this.tabW[i], 2)
    }

    ; ---- UI feedback --------------------------------------------------------

    SetStatus(kind, extra := "") {
        switch kind {
            case "Fishing":  text := "Fishing...",        color := FischApp.ACCENT
            case "Minigame": text := "Minigame Active",   color := FischApp.GOOD
            case "Paused":   text := "Paused",            color := FischApp.WARN
            case "Error":    text := "Error",             color := FischApp.BAD
            default:         text := "Idle",              color := FischApp.MUTED
        }
        if extra != ""
            text .= " - " extra
        this.statusTxt.Value := "Status: " text
        this.Style(this.statusTxt, "s16 bold c" color)
        this.footer.Value := "Status: " text
    }

    Log(msg) {
        line := "[" FormatTime(, "HH:mm:ss") "] " msg "`r`n"
        if ++this.logLines > 300 {
            this.logBox.Value := ""
            this.logLines := 1
        }
        SendMessage(0x00B1, -1, -1, this.logBox)           ; EM_SETSEL (end)
        SendMessage(0x00C2, 0, StrPtr(line), this.logBox)  ; EM_REPLACESEL
        SendMessage(0x00B7, 0, 0, this.logBox)             ; EM_SCROLLCARET
    }

    Tip(msg) {
        ToolTip(msg)
        SetTimer(() => ToolTip(), -2500)
    }

    UpdateButtons() {
        this.startBtn.Value := this.running ? "Stop Macro" : "Start Macro"
        this.startBtn.Opt("Background" (this.running ? FischApp.BAD : FischApp.ACCENT))
        this.startBtn.Redraw()
        this.pauseBtn.Value := this.paused ? "Resume" : "Pause"
    }

    TickUi() {
        caught := this.stats["totalCaught"]
        att := this.stats["totalAttempts"]
        rate := att > 0 ? Format("{:.1f}%", caught / att * 100) : "--"
        up := this.running ? Webhook.Uptime((A_TickCount - this.startTick) // 1000) : "00:00:00"
        this.statsTxt.Value := "Caught " caught "   Casts " att "   Success " rate "   Uptime " up
    }

    ; ---- settings -----------------------------------------------------------

    ; Reads every field into this.cfg. Returns true on success.
    ApplyAll() {
        try {
            for key, f in this.numFields {
                lim := this.numLimits[key]
                v := Trim(f.Value)
                if !IsInteger(v) || v < lim[1] || v > lim[2]
                    throw Error(lim[3] " must be a whole number from " lim[1] " to " lim[2] ".")
                this.cfg[key] := Integer(v)
            }
        } catch as e {
            this.ShowMsg(e.Message, FischApp.BAD)
            return false
        }
        url := Trim(this.urlEdit.Value)
        this.cfg["WebhookUrl"] := url
        this.cfg["RodName"] := Trim(this.rodEdit.Value) = "" ? "Unknown" : Trim(this.rodEdit.Value)
        this.cfg["PingTarget"] := Trim(this.pingEdit.Value)
        this.cfg["ReportIntervalMin"] := this.interval
        for key, t in this.toggles
            this.cfg[key] := t.on ? 1 : 0
        if this.cfg["WebhookEnabled"] && !Webhook.IsValidUrl(url) {
            this.ShowMsg("Webhooks are on, but the URL does not look like a Discord webhook.", FischApp.WARN)
        }
        return true
    }

    ShowMsg(text, color) {
        this.setMsg.Value := text
        this.Style(this.setMsg, "s9 c" color)
        this.testMsg.Value := text
        this.Style(this.testMsg, "s9 c" color)
    }

    OnSave(*) {
        if !this.ApplyAll()
            return
        if this.SaveConfig() {
            this.ShowMsg("Saved to config.json", FischApp.GOOD)
            this.Log("Settings saved.")
        }
    }

    OnTestWebhook(*) {
        url := Trim(this.urlEdit.Value)
        if !Webhook.IsValidUrl(url) {
            this.ShowMsg("That does not look like a Discord webhook URL.", FischApp.BAD)
            return
        }
        this.ShowMsg("Sending...", FischApp.MUTED)
        Webhook.Test(url, this.OnTestResult.Bind(this))
    }

    OnTestResult(status, text) {
        if status >= 200 && status < 300 {
            this.ShowMsg("Webhook works (HTTP " status ")", FischApp.GOOD)
        } else if status = 0 {
            this.ShowMsg(text, FischApp.BAD)
        } else {
            this.ShowMsg("Failed: HTTP " status, FischApp.BAD)
        }
    }

    ; ---- macro control ------------------------------------------------------

    ToggleRun(*) {
        if this.running
            this.Stop()
        else
            this.Start()
    }

    Start() {
        if this.running
            return
        if !this.ApplyAll()
            return
        if !this.cfg["Calibrated"] {
            this.Log("Not calibrated yet. Hover over the fish icon and press F2.")
            this.SwitchTab(4)
            return
        }
        if !this.solver.GetWindow() {
            this.SetStatus("Error", "Roblox not found")
            this.Log("Roblox window not found. Open Fisch first.")
            return
        }
        this.SaveConfig()
        this.running := true
        this.paused := false
        this.startTick := A_TickCount
        this.lastCatchTick := A_TickCount
        for k in ["totalCaught", "totalAttempts", "intervalCaught", "intervalAttempts"]
            this.stats[k] := 0
        this.UpdateButtons()
        this.SetStatus("Fishing")
        this.Log("Macro started.")
        Webhook.SendEvent(this.cfg, "Macro started", "Fisch Macro is now fishing.", Webhook.GREEN)
        if this.cfg["ReportEnabled"] && Webhook.Ready(this.cfg)
            SetTimer(this.reportFn, this.cfg["ReportIntervalMin"] * 60000)
        SetTimer(this.loopFn, -10)
    }

    Stop() {
        if !this.running
            return
        this.running := false
        this.paused := false
        SetTimer(this.reportFn, 0)
        this.solver.Release()
        this.SetStatus("Idle")
        this.UpdateButtons()
        this.Log("Macro stopped.")
        Webhook.SendEvent(this.cfg, "Macro stopped", this.Summary(), Webhook.YELLOW)
    }

    TogglePause(*) {
        if !this.running
            return
        this.paused := !this.paused
        if this.paused {
            this.solver.Release()
            this.SetStatus("Paused")
            this.Log("Paused.")
            Webhook.SendEvent(this.cfg, "Macro paused", this.Summary(), Webhook.YELLOW)
        } else {
            this.SetStatus("Fishing")
            this.Log("Resumed.")
            Webhook.SendEvent(this.cfg, "Macro resumed", "Back to fishing.", Webhook.GREEN)
        }
        this.UpdateButtons()
    }

    Summary() {
        return this.stats["totalCaught"] " fish / " this.stats["totalAttempts"] " casts this session."
    }

    Snapshot() {
        s := Map()
        for k, v in this.stats
            s[k] := v
        s["uptimeSec"] := this.running ? (A_TickCount - this.startTick) // 1000 : 0
        return s
    }

    ; ---- main loop ----------------------------------------------------------

    RunLoop() {
        if this.loopActive
            return
        this.loopActive := true
        try {
            this.solver.PrimeNavigation()
            while this.running {
                if this.paused {
                    Sleep(200)
                    continue
                }
                this.FishOnce()
            }
        } catch as e {
            this.Fail("Script error: " e.Message)
        }
        this.solver.Release()
        this.loopActive := false
    }

    FishOnce() {
        s := this.solver
        w := s.GetWindow()
        if !w {
            this.Fail("Roblox window not found or minimized. Possible disconnect or crash.")
            return
        }
        s.Focus(w)
        this.SetStatus("Fishing")
        this.stats["totalAttempts"]++
        this.stats["intervalAttempts"]++
        s.Cast(w)

        stopFn := () => !this.running || this.paused
        result := s.WaitForReel(Integer(this.cfg["BiteWaitSec"]) * 1000, stopFn)
        if result = "abort" {
            this.UndoAttempt()
            return
        }
        if result = "nowindow" {
            this.Fail("Roblox window lost while waiting for a bite. Possible disconnect.")
            return
        }
        if result = "timeout" {
            this.Log("No bite, recasting.")
            this.CheckStuck()
            return
        }

        this.SetStatus("Minigame")
        this.Log("Fish on! Reeling...")
        delay := Integer(this.cfg["ScanDelayMs"])
        while this.running && !this.paused {
            if !s.SolveStep()
                break
            Sleep(delay)
        }
        s.Release()
        if !this.running || this.paused {
            this.UndoAttempt()
            return
        }

        this.stats["totalCaught"]++
        this.stats["intervalCaught"]++
        this.lastCatchTick := A_TickCount
        this.Log("Caught fish #" this.stats["totalCaught"])
        this.SetStatus("Fishing")
        Sleep(1200)          ; let the catch screen clear before the next cast
        this.CheckStuck()
    }

    UndoAttempt() {
        this.stats["totalAttempts"]--
        this.stats["intervalAttempts"]--
    }

    CheckStuck() {
        limit := Integer(this.cfg["CatchTimeoutSec"]) * 1000
        if A_TickCount - this.lastCatchTick > limit
            this.Fail("No fish caught for " this.cfg["CatchTimeoutSec"] " seconds. The game may be stuck or disconnected.")
    }

    Fail(reason) {
        if !this.running
            return
        this.running := false
        this.paused := false
        SetTimer(this.reportFn, 0)
        this.solver.Release()
        this.SetStatus("Error")
        this.UpdateButtons()
        this.Log("ERROR: " reason)
        Webhook.SendAlert(this.cfg, reason, this.Snapshot(), this.solver)
    }

    ReportTick() {
        if !this.running
            return
        if Webhook.SendReport(this.cfg, this.Snapshot())
            this.Log("Fischer Report sent.")
        this.stats["intervalCaught"] := 0
        this.stats["intervalAttempts"] := 0
    }

    ; ---- calibration --------------------------------------------------------

    OnCalibrateKey(which) {
        res := this.solver.Calibrate(which)
        this.Log(res["msg"])
        this.Tip(res["msg"])
        if res["ok"] {
            this.SaveConfig()
            this.RefreshCalibrationView()
        }
    }

    StartCountdown(*) {
        this.cd := 5
        this.calHint.Value := "Switch to Roblox and hover over the fish icon... 5"
        SetTimer(this.cdFn, 1000)
    }

    CountdownTick() {
        this.cd--
        if this.cd > 0 {
            this.calHint.Value := "Switch to Roblox and hover over the fish icon... " this.cd
            return
        }
        SetTimer(this.cdFn, 0)
        this.calHint.Value := ""
        this.OnCalibrateKey("fish")
    }

    RefreshCalibrationView() {
        if this.cfg["Calibrated"] {
            col := Integer(this.cfg["CalFishColor"])
            this.calText.Value := "Calibrated: " this.cfg["CalX"] ", " this.cfg["CalY"] " (" Format("0x{:06X}", col) ")"
            this.Style(this.calText, "s10 bold c" FischApp.GOOD)
            this.calSwatch.Opt("Background" Format("{:06X}", col))
        } else {
            this.calText.Value := "Not calibrated yet."
            this.Style(this.calText, "s10 bold c" FischApp.WARN)
            this.calSwatch.Opt("Background" FischApp.PANEL)
        }
        this.calSwatch.Redraw()
        this.barText.Value := "Player bar color: " Format("0x{:06X}", Integer(this.cfg["CalBarColor"]))
    }

    Quit() {
        this.solver.Release()
        ExitApp()
    }
}

app := FischApp()
