; =============================================================================
;  GUI.ahk  -  Native AutoHotkey v2 control window for the Fisch macro
;
;  MacroGui builds the window, copies settings between the controls and the
;  config Map, and reacts to events from FishSolver (status text, log lines,
;  running / paused state). The hotkeys in main.ahk call the same methods as
;  the buttons (Toggle, Start, PauseResume, Save), so both always behave alike.
;
;  Settings in the window are applied to the running macro when you press
;  Start / Resume (or a hotkey that starts / resumes it) and when you press
;  Save Settings. Only Save Settings writes config.json.
; =============================================================================
#Requires AutoHotkey v2.0

class MacroGui {
    __New(cfg, solver, hook) {
        this.Cfg := cfg
        this.Solver := solver
        this.Hook := hook
        this.Build()
        this.LoadFromConfig()
        this.UpdateButtons()
        this.SetStatus("Idle")
        solver.Listener := ObjBindMethod(this, "OnSolverEvent")
    }

    ; ---- window ----------------------------------------------------------------
    Build() {
        g := Gui("-MaximizeBox", "Fisch Macro")
        this.G := g
        g.SetFont("s10", "Segoe UI")
        g.OnEvent("Close", (*) => ExitApp())

        g.SetFont("s16 bold")
        g.Add("Text", "x16 y10 w300 h32", "Fisch Macro")
        g.SetFont("s11 bold")
        this.txtStatus := g.Add("Text", "x16 y46 w448 h24", "Status: Idle")
        g.SetFont("s10 norm cDefault")

        ; --- Discord webhook ---
        g.Add("GroupBox", "x16 y78 w448 h98", "Discord webhook")
        this.edUrl := g.Add("Edit", "x30 y102 w300 h24")
        SendMessage(0x1501, 1, StrPtr("Paste your Discord webhook URL here"), this.edUrl.Hwnd)  ; EM_SETCUEBANNER
        this.btnTest := g.Add("Button", "x340 y101 w112 h26", "Test Webhook")
        this.chkEnable := g.Add("Checkbox", "x30 y140 w130", "Enable webhook")
        this.chkCast := g.Add("Checkbox", "x168 y140 w140", "Message on cast")
        this.chkHook := g.Add("Checkbox", "x316 y140 w136", "Message on hook")

        ; --- Fishing settings ---
        g.Add("GroupBox", "x16 y188 w448 h206", "Fishing settings")
        g.Add("Text", "x30 y220 w130", "Cast hold (ms)")
        this.slHold := g.Add("Slider", "x150 y212 w190 h30 Range100-5000 TickInterval1000 ToolTip")
        this.edHold := g.Add("Edit", "x350 y214 w76 h24 Number")
        g.Add("UpDown", "Range0-60000", 1000)

        grey := "cGray"
        g.Add("Text", "x30 y256 w130", "Scan interval (ms)")
        this.edScan := g.Add("Edit", "x160 y252 w76 h24 Number")
        g.Add("UpDown", "Range1-1000", 10)
        g.SetFont("s9 " grey)
        g.Add("Text", "x250 y256 w206", "Delay between screen scans")
        g.SetFont("s10 cDefault")

        g.Add("Text", "x30 y292 w130", "Fish tolerance")
        this.edFishTol := g.Add("Edit", "x160 y288 w76 h24 Number")
        g.Add("UpDown", "Range0-255", 12)
        g.SetFont("s9 " grey)
        g.Add("Text", "x250 y292 w206", "Colour match for the fish icon (0-255)")
        g.SetFont("s10 cDefault")

        g.Add("Text", "x30 y328 w130", "Bar tolerance")
        this.edBarTol := g.Add("Edit", "x160 y324 w76 h24 Number")
        g.Add("UpDown", "Range0-255", 12)
        g.SetFont("s9 " grey)
        g.Add("Text", "x250 y328 w206", "Colour match for the white bar (0-255)")
        g.SetFont("s10 cDefault")

        g.Add("Text", "x30 y364 w130", "Deadzone (px)")
        this.edDead := g.Add("Edit", "x160 y360 w76 h24 Number")
        g.Add("UpDown", "Range0-500", 12)
        g.SetFont("s9 " grey)
        g.Add("Text", "x250 y364 w206", "Slack before the bar chases the fish")
        g.SetFont("s10 cDefault")

        ; --- Controls ---
        this.btnStart := g.Add("Button", "x16 y408 w140 h36", "Start Macro")
        this.btnPause := g.Add("Button", "x166 y408 w140 h36", "Pause Macro")
        this.btnSave := g.Add("Button", "x316 y408 w148 h36", "Save Settings")

        ; --- Log ---
        g.Add("Text", "x16 y456 w200", "Log")
        this.edLog := g.Add("Edit", "x16 y478 w448 h124 ReadOnly Multi VScroll")

        g.SetFont("s9 " grey)
        g.Add("Text", "x16 y610 w448"
            , this.Cfg["ToggleKey"] " start / pause / resume   -   " this.Cfg["ExitKey"] " exit   -   "
            . this.Cfg["CalibrateKey"] " colour helper")
        g.SetFont("s10 cDefault")

        ; --- Events ---
        this.btnStart.OnEvent("Click", (*) => this.Start())
        this.btnPause.OnEvent("Click", (*) => this.PauseResume())
        this.btnSave.OnEvent("Click", (*) => this.Save())
        this.btnTest.OnEvent("Click", (*) => this.TestWebhook())
        this.slHold.OnEvent("Change", (c, *) => this.edHold.Value := c.Value)
        this.edHold.OnEvent("Change", (*) => this.SyncSlider())
    }

    Show() {
        this.G.Show("x20 y20")
    }

    ; ---- config <-> controls -----------------------------------------------------
    LoadFromConfig() {
        c := this.Cfg
        this.edUrl.Value := c["DiscordWebhookURL"]
        this.chkEnable.Value := c["EnableWebhook"] ? 1 : 0
        this.chkCast.Value := c["WebhookOnCast"] ? 1 : 0
        this.chkHook.Value := c["WebhookOnHook"] ? 1 : 0
        this.edHold.Value := c["CastHoldTimeMs"]
        this.SyncSlider()
        this.edScan.Value := c["ScanIntervalMs"]
        this.edFishTol.Value := c["FishTolerance"]
        this.edBarTol.Value := c["BarTolerance"]
        this.edDead.Value := c["DeadzonePx"]
    }

    ; Copy the control values into the config Map and push them to the webhook
    ; and solver. Out-of-range numbers are clamped; empty fields keep the old value.
    ApplyToConfig() {
        c := this.Cfg
        c["DiscordWebhookURL"] := Trim(this.edUrl.Value)
        c["EnableWebhook"] := this.chkEnable.Value = 1
        c["WebhookOnCast"] := this.chkCast.Value = 1
        c["WebhookOnHook"] := this.chkHook.Value = 1
        c["CastHoldTimeMs"] := MacroGui.ReadInt(this.edHold, 0, 60000, c["CastHoldTimeMs"])
        c["ScanIntervalMs"] := MacroGui.ReadInt(this.edScan, 1, 1000, c["ScanIntervalMs"])
        c["FishTolerance"] := MacroGui.ReadInt(this.edFishTol, 0, 255, c["FishTolerance"])
        c["BarTolerance"] := MacroGui.ReadInt(this.edBarTol, 0, 255, c["BarTolerance"])
        c["DeadzonePx"] := MacroGui.ReadInt(this.edDead, 0, 500, c["DeadzonePx"])
        warning := this.Hook.Configure(c["DiscordWebhookURL"], c["EnableWebhook"])
        if (warning != "")
            this.Log(warning)
        this.Solver.ApplyConfig()
    }

    static ReadInt(ctrl, lo, hi, fallback) {
        t := Trim(ctrl.Value)
        v := IsInteger(t) ? Min(hi, Max(lo, Integer(t))) : fallback
        ctrl.Value := v
        return v
    }

    SyncSlider() {
        t := Trim(this.edHold.Value)
        if IsInteger(t)
            this.slHold.Value := Min(5000, Max(100, Integer(t)))
    }

    ; ---- actions (buttons and hotkeys) ------------------------------------------------
    Start() {
        if (this.Solver.Running || this.Solver.Paused)
            return
        this.ApplyToConfig()
        this.Solver.Begin()
    }

    PauseResume() {
        if this.Solver.Running {
            this.Solver.Pause()
        } else if this.Solver.Paused {
            this.ApplyToConfig()
            this.Solver.Begin()
        }
    }

    ; Hotkey behaviour: idle -> start, running -> pause, paused -> resume.
    Toggle() {
        if this.Solver.Running {
            this.Solver.Pause()
        } else {
            this.ApplyToConfig()
            this.Solver.Begin()
        }
    }

    Save() {
        this.ApplyToConfig()
        if Config.Save(this.Cfg) {
            this.Log("Settings saved to config.json.")
        } else {
            this.Log("Could not write config.json.")
            MsgBox("Could not write config.json. Is the folder read-only?", "Fisch Macro", "Icon!")
        }
    }

    TestWebhook() {
        url := Trim(this.edUrl.Value)
        if (url = "") {
            this.Log("Paste a webhook URL first.")
            return
        }
        this.btnTest.Enabled := false
        this.btnTest.Text := "Testing..."
        SetTimer(() => this.RunWebhookTest(url), -30)   ; let the button repaint first
    }

    RunWebhookTest(url) {
        result := this.Hook.Test(url)
        this.btnTest.Text := "Test Webhook"
        this.btnTest.Enabled := true
        this.Log("Webhook test: " result["message"])
    }

    ; ---- display ----------------------------------------------------------------------
    OnSolverEvent(kind, text) {
        if (kind = "status") {
            this.SetStatus(text)
            this.Log(text)
        } else if (kind = "state") {
            this.UpdateButtons()
        }
    }

    UpdateButtons() {
        running := this.Solver.Running
        paused := this.Solver.Paused
        idle := !running && !paused
        this.btnStart.Enabled := idle
        this.btnPause.Enabled := !idle
        this.btnPause.Text := paused ? "Resume Macro" : "Pause Macro"
    }

    SetStatus(text) {
        color := this.Solver.Running ? "008000" : (this.Solver.Paused ? "B36B00" : "666666")
        this.txtStatus.SetFont("s11 bold c" color, "Segoe UI")
        this.txtStatus.Value := "Status: " text
    }

    ; Append a timestamped line to the log box and keep it scrolled to the end.
    Log(text) {
        try {
            line := FormatTime(, "HH:mm:ss") "  " text "`r`n"
            ed := this.edLog.Hwnd
            len := SendMessage(0x000E, 0, 0, ed)              ; WM_GETTEXTLENGTH
            if (len > 30000) {
                this.edLog.Value := ""
                len := 0
            }
            SendMessage(0x00B1, len, len, ed)                 ; EM_SETSEL: caret to the end
            SendMessage(0x00C2, 0, StrPtr(line), ed)          ; EM_REPLACESEL: append
            SendMessage(0x00B7, 0, 0, ed)                     ; EM_SCROLLCARET
        }
    }
}
