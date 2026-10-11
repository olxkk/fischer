; ==============================================================================
;  Fischer - automated fishing macro for the Roblox game "Fisch"
;  main.ahk : entry point, configuration manager, dark GUI, global hotkeys
;
;  Requires : AutoHotkey v2.0+ (64-bit recommended), Windows 10 or 11
;  License  : MIT (see LICENSE)
;
;  Hotkeys  : F5 start | F6 pause / resume | F7 emergency stop | F2 calibrate
; ==============================================================================
#Requires AutoHotkey v2.0
#SingleInstance Force
#Include lib\Webhook.ahk
#Include lib\FishSolver.ahk


; ==============================================================================
;  FischerConfig : defaults, load, save, profiles
;    Data is a Map of Maps: Data[group][key]. Missing keys fall back to defaults,
;    so older config files keep working after updates.
; ==============================================================================
class FischerConfig {
    static Data := Map()

    static Path => A_ScriptDir "\config.json"
    static ProfileDir => A_ScriptDir "\profiles"

    static Defaults() {
        d := Map()
        d["General"] := Map("ProfileName", "Default")
        d["Timing"] := Map(
            "CastHoldTimeMs", 600,
            "CastWaitMs", 1500,
            "CastTimeoutMs", 25000,
            "ScanIntervalMs", 15,
            "ClickResponseMs", 60,
            "HoldDeadzonePx", 6,
            "PredictFrames", 2,
            "ScanStep", 2,
            "MinCatchMs", 1500,
            "MinigameTimeoutMs", 90000,
            "EndGraceMs", 700,
            "StaticEndMs", 2500,
            "PostCatchDelayMs", 1500
        )
        d["Shake"] := Map(
            "Keys", "",
            "KeyIntervalMs", 80
        )
        d["Colors"] := Map(
            "FishColor", "0xFFFFFF",
            "ShakeColor", "0xFFFFFF",
            "SliderColor", "0xB4B4B4",
            "Tolerance", 20,
            "MinMatchPixels", 3
        )
        d["Regions"] := Map(
            "ReelBarL", 0, "ReelBarT", 0, "ReelBarR", 0, "ReelBarB", 0,
            "HotbarX", 0, "HotbarY", 0,
            "InfoL", 0, "InfoT", 0, "InfoR", 0, "InfoB", 0,
            "LevelL", 0, "LevelT", 0, "LevelR", 0, "LevelB", 0
        )
        d["Scanner"] := Map("OcrScale", 2, "HoverDelayMs", 500, "ShakeStep", 4, "ShakeMinPixels", 12)
        d["Game"] := Map(
            "WindowMatch", "ahk_exe RobloxPlayerBeta.exe",
            "StuckTimeoutSec", 180,
            "DisconnectOcrCheckSec", 60
        )
        d["Webhook"] := Map(
            "Enabled", 0,
            "Url", "",
            "NotifyCatch", 0,
            "ReportEnabled", 1,
            "ReportIntervalMin", 30,
            "AttachLevelImage", 1,
            "PingOnError", 0,
            "PingTarget", "@everyone",
            "ScreenshotOnFailure", 1
        )
        return d
    }

    ; Overlay loaded values on top of fresh defaults. Unknown keys are dropped.
    static Merge(loaded) {
        if !(loaded is Map)
            throw Error("The config root must be a JSON object.")
        d := this.Defaults()
        for gk, group in d {
            if (loaded.Has(gk) && loaded[gk] is Map) {
                for k, def in group {
                    if loaded[gk].Has(k)
                        group[k] := this._Coerce(loaded[gk][k], def)
                }
            }
        }
        return d
    }

    static _Coerce(val, def) {
        if (def is Number)
            return IsNumber(val) ? Number(val) : def
        return String(val)
    }

    static Load(path) {
        this.Data := this.Merge(FischerJson.Parse(FileRead(path, "UTF-8")))
    }

    static LoadOrDefault() {
        try {
            this.Load(this.Path)
        } catch {
            this.Data := this.Defaults()
            try this.Save(this.Path)
        }
    }

    static Save(path, data := "") {
        if !IsObject(data)
            data := this.Data
        f := FileOpen(path, "w", "UTF-8-RAW")
        if !f
            throw Error("Cannot write to " path)
        f.Write(FischerJson.Stringify(data))
        f.Close()
    }

    static Get(group, key) => this.Data[group][key]
    static Set(group, key, value) => this.Data[group][key] := value
    static Int(group, key) => Integer(this.Data[group][key])

    static SafeName(name) {
        n := Trim(RegExReplace(Trim(name), '[\\/:*?"<>|]', "_"), " .")
        return (n = "") ? "Default" : n
    }

    static ProfilePath(name) => this.ProfileDir "\" this.SafeName(name) ".json"

    static ListProfiles() {
        names := []
        if DirExist(this.ProfileDir) {
            pattern := this.ProfileDir "\*.json"
            loop files pattern
                names.Push(RegExReplace(A_LoopFileName, "i)\.json$"))
        }
        return names
    }
}


; ==============================================================================
;  FischerApp : GUI (cobalt.tools-inspired dark theme) and hotkey actions
; ==============================================================================
class FischerApp {
    static Version := "1.0.0"

    ; ---- palette ---------------------------------------------------------------
    static BG := "121214"
    static FIELD := "1B1B20"
    static BORDER := "2C2C34"
    static FG := "F2F2F5"
    static MUTED := "8B8B96"
    static ACCENT := "2F8AF5"
    static DANGER := "E5484D"
    static AMBER := "F5A524"
    static GOOD := "30A46C"

    ; ---- state -----------------------------------------------------------------
    static G := ""
    static Ctl := Map()
    static TabCtrls := []
    static TabBtns := []
    static TabNames := ["Control", "Settings && Profiles", "Webhook && Reports", "Calibration"]
    static Underline := ""
    static ActiveLbl := ""
    static StatusLbl := ""
    static StatsLbl := ""
    static WebhookLbl := ""
    static StepLbl := ""
    static FishSw := ""
    static SliderSw := ""
    static StepIdx := 1
    static ReportFn := ""
    static Intervals := [15, 30, 60]

    ; [group, key, label, min, max, column (1 or 2), y]
    static NumFields := [
        ["Timing", "CastHoldTimeMs", "Cast hold time (ms)", 50, 10000, 1, 162],
        ["Timing", "CastWaitMs", "Wait after cast (ms)", 0, 30000, 1, 196],
        ["Timing", "CastTimeoutMs", "Bite timeout (ms)", 1000, 120000, 1, 230],
        ["Timing", "ScanIntervalMs", "Scan interval (ms)", 1, 500, 1, 264],
        ["Timing", "ClickResponseMs", "Click / hold response (ms)", 10, 1000, 1, 298],
        ["Timing", "HoldDeadzonePx", "Hold deadzone (px)", 0, 200, 1, 332],
        ["Colors", "Tolerance", "Color tolerance (0-255)", 0, 255, 2, 162],
        ["Timing", "MinCatchMs", "Min. catch time (ms)", 0, 60000, 2, 196],
        ["Timing", "MinigameTimeoutMs", "Minigame timeout (ms)", 5000, 600000, 2, 230],
        ["Timing", "PredictFrames", "Fish prediction frames", 0, 20, 2, 264],
        ["Timing", "ScanStep", "Scan step (px)", 1, 10, 2, 298],
        ["Timing", "PostCatchDelayMs", "Delay after catch (ms)", 0, 30000, 2, 332],
        ["Shake", "KeyIntervalMs", "Shake click interval (ms)", 10, 2000, 2, 402]
    ]

    ; [id, short name, instruction]
    static Steps := [
        ["BarTL", "Reel bar: TOP-LEFT corner", "the TOP-LEFT corner of the reel bar"],
        ["BarBR", "Reel bar: BOTTOM-RIGHT corner", "the BOTTOM-RIGHT corner of the reel bar"],
        ["Fish", "Fish icon color", "the FISH icon inside the reel bar"],
        ["Slider", "Slider (your bar) color", "the SLIDER bar that you control"],
        ["Shake", "Shake button color", "the SHAKE button (cast once and wait for it to appear)"],
        ["Slot1", "Hotbar: slot 1 (rod)", "the center of hotbar SLOT 1 (your rod)"],
        ["InfoTL", "Rod info text: TOP-LEFT", "the TOP-LEFT corner of the rod name / enchant text"],
        ["InfoBR", "Rod info text: BOTTOM-RIGHT", "the BOTTOM-RIGHT corner of the rod name / enchant text"],
        ["LevelTL", "Level text: TOP-LEFT", "the TOP-LEFT corner of the level text (bottom-right of the screen)"],
        ["LevelBR", "Level text: BOTTOM-RIGHT", "the BOTTOM-RIGHT corner of the level text"]
    ]

    ; ==========================================================================
    ;  Startup
    ; ==========================================================================

    static Init() {
        CoordMode("Mouse", "Screen")
        CoordMode("Pixel", "Screen")
        SetWorkingDir(A_ScriptDir)
        FischerConfig.LoadOrDefault()
        this.BuildGui()
        this.LoadConfigToUi()
        this.ShowTab(1)

        FishSolver.OnStatus := (s) => FischerApp.OnStatus(s)
        FishSolver.OnCatch := () => FischerApp.OnCatch()
        FishSolver.OnError := (m) => FischerApp.OnError(m)
        FishSolver.OnReport := () => FischerApp.OnReport()

        Hotkey("F5", (*) => FischerApp.Start())
        Hotkey("F6", (*) => FischerApp.TogglePause())
        Hotkey("F7", (*) => FischerApp.Stop())
        Hotkey("F2", (*) => FischerApp.Calibrate())
        OnExit((*) => FischerApp.Cleanup())
        SetTimer(() => FischerApp.UpdateStats(), 1000)

        this.G.Show("w720 h640")
    }

    static Cleanup() {
        try FishSolver.Stop()
        try FishSolver.ReleaseAll()
        try FischerGdi.Shutdown()
        return 0
    }

    ; ==========================================================================
    ;  GUI construction helpers
    ; ==========================================================================

    static Reg(tab, ctrl) {
        this.TabCtrls[tab].Push(ctrl)
    }

    static Lbl(tab, x, y, w, text, fontOpts := "s9", color := "", fontName := "Segoe UI", h := 0) {
        opts := "x" x " y" y " w" w (h > 0 ? " h" h : "")
        c := this.G.AddText(opts, text)
        c.SetFont(fontOpts " c" (color = "" ? this.FG : color), fontName)
        this.Reg(tab, c)
        return c
    }

    static Section(tab, x, y, w, text) {
        this.Lbl(tab, x, y, w, text, "s8 bold", this.MUTED, "Consolas")
        r := this.G.AddText("x" x " y" (y + 18) " w" w " h1 Background" this.BORDER)
        this.Reg(tab, r)
    }

    ; Bordered dark single-line input.
    static Input(tab, x, y, w, value := "", opts := "") {
        fr := this.G.AddText("x" (x - 1) " y" (y - 1) " w" (w + 2) " h26 Background" this.BORDER)
        ed := this.G.AddEdit("x" x " y" y " w" w " h24 -E0x200 Background" this.FIELD " c" this.FG " " opts, value)
        ed.SetFont("s9", "Segoe UI")
        SendMessage(0xD3, 3, 8 | (8 << 16), ed.Hwnd)       ; EM_SETMARGINS: 8px left and right padding
        this.Reg(tab, fr)
        this.Reg(tab, ed)
        return ed
    }

    ; Native checkbox with a clickable label next to it.
    static Check(tab, x, y, w, text, key) {
        cb := this.G.AddCheckbox("x" x " y" (y + 2) " w18 h18", "")
        lb := this.G.AddText("x" (x + 26) " y" y " w" w " h22 +0x100 +0x200", text)
        lb.SetFont("s9 c" this.FG, "Segoe UI")
        lb.OnEvent("Click", this._ToggleHandler(cb))
        this.Reg(tab, cb)
        this.Reg(tab, lb)
        this.Ctl[key] := cb
        return cb
    }

    static _ToggleHandler(cb) => (*) => (cb.Value := !cb.Value)

    static _TabHandler(i) => (*) => FischerApp.ShowTab(i)

    ; Flat button: optional 1px border, centered label.
    static Button(tab, x, y, w, h, text, handler, fill, fg := "FFFFFF", border := "") {
        if (border != "")
            this.Reg(tab, this.G.AddText("x" (x - 1) " y" (y - 1) " w" (w + 2) " h" (h + 2) " Background" border))
        b := this.G.AddText("x" x " y" y " w" w " h" h " +0x200 +0x100 Center Background" fill " c" fg, text)
        b.SetFont("s9 bold", "Consolas")
        b.OnEvent("Click", handler)
        this.Reg(tab, b)
        return b
    }

    static DarkCombo(ctrl) {
        try DllCall("uxtheme\SetWindowTheme", "ptr", ctrl.Hwnd, "str", "DarkMode_CFD", "ptr", 0)
    }

    ; ==========================================================================
    ;  GUI construction
    ; ==========================================================================

    static BuildGui() {
        g := Gui("-MaximizeBox", "Fischer")
        this.G := g
        g.BackColor := this.BG
        g.MarginX := 0
        g.MarginY := 0
        g.SetFont("s9 c" this.FG, "Segoe UI")
        try DllCall("dwmapi\DwmSetWindowAttribute", "ptr", g.Hwnd, "int", 20, "int*", 1, "int", 4)   ; dark title bar
        g.OnEvent("Close", (*) => ExitApp())
        this.TabCtrls := [[], [], [], []]
        this.TabBtns := []

        title := g.AddText("x24 y12 w400 h34", "FISCHER")
        title.SetFont("s20 bold c" this.ACCENT, "Consolas")
        sub := g.AddText("x24 y48 w600", "auto-fishing macro for Fisch  |  v" this.Version)
        sub.SetFont("s8 c" this.MUTED, "Consolas")

        ; tab strip
        g.AddText("x24 y112 w672 h1 Background" this.BORDER)
        this.Underline := g.AddText("x24 y111 w168 h3 Background" this.ACCENT)
        loop 4 {
            i := A_Index
            b := g.AddText("x" (24 + (i - 1) * 168) " y80 w168 h30 +0x200 +0x100 Center", this.TabNames[i])
            b.SetFont("s9 bold c" this.MUTED, "Consolas")
            b.OnEvent("Click", this._TabHandler(i))
            this.TabBtns.Push(b)
        }

        this.BuildControlTab()
        this.BuildSettingsTab()
        this.BuildWebhookTab()
        this.BuildCalibrationTab()

        foot := g.AddText("x24 y610 w672", "MIT License  |  Macros may violate game rules. Use at your own risk.")
        foot.SetFont("s8 c" this.MUTED, "Consolas")
    }

    static ShowTab(n) {
        this.ActiveTab := n
        for i, list in this.TabCtrls {
            for c in list
                c.Visible := (i = n)
        }
        for i, b in this.TabBtns
            b.SetFont("c" (i = n ? this.FG : this.MUTED))
        this.Underline.Move(24 + (n - 1) * 168)
    }

    ; ---- tab 1: Control -------------------------------------------------------

    static BuildControlTab() {
        y := 132
        this.Section(1, 24, y, 672, "ACTIVE PROFILE")
        this.ActiveLbl := this.Lbl(1, 24, y + 30, 672, "Active Config: Default", "s16 bold", this.FG, "Consolas", 32)
        this.Section(1, 24, y + 84, 672, "STATUS")
        this.StatusLbl := this.Lbl(1, 24, y + 114, 672, "Status: Idle", "s14 bold", this.MUTED, "Consolas", 28)
        this.StatsLbl := this.Lbl(1, 24, y + 150, 672, "", "s9", this.MUTED, "Consolas", 56)

        by := y + 216
        this.Button(1, 24, by, 212, 40, "START MACRO", (*) => FischerApp.Start(), this.ACCENT, "FFFFFF")
        this.Button(1, 254, by, 212, 40, "PAUSE / RESUME", (*) => FischerApp.TogglePause(), this.FIELD, this.FG, this.BORDER)
        this.Button(1, 484, by, 212, 40, "STOP MACRO", (*) => FischerApp.Stop(), this.FIELD, this.DANGER, this.DANGER)

        hy := by + 68
        this.Section(1, 24, hy, 672, "HOTKEYS")
        keys := [
            ["F5", "Start macro"],
            ["F6", "Pause / Resume"],
            ["F7", "Emergency stop (releases every held input)"],
            ["F2", "Capture calibration point"]
        ]
        for i, k in keys {
            this.Lbl(1, 24, hy + 30 + (i - 1) * 26, 60, k[1], "s10 bold", this.ACCENT, "Consolas")
            this.Lbl(1, 90, hy + 30 + (i - 1) * 26, 600, k[2], "s10", this.FG, "Consolas")
        }
    }

    ; ---- tab 2: Settings & Profiles -----------------------------------------------

    static BuildSettingsTab() {
        this.Section(2, 24, 132, 672, "TIMING AND SCANNING")
        for f in this.NumFields {
            lx := (f[6] = 1) ? 24 : 370
            ix := (f[6] = 1) ? 200 : 560
            lw := (f[6] = 1) ? 170 : 185
            this.Lbl(2, lx, f[7] + 4, lw, f[3])
            this.Ctl[f[1] "." f[2]] := this.Input(2, ix, f[7], 110, "", "Number")
        }

        this.Section(2, 24, 372, 672, "SHAKE KEY BINDINGS")
        this.Lbl(2, 24, 406, 330, "Shake button is clicked by color (calibration step 5)", "s8", this.MUTED, "Consolas")
        this.Lbl(2, 24, 440, 170, "Extra keys (optional)")
        this.Ctl["Shake.Keys"] := this.Input(2, 200, 436, 270)
        this.Lbl(2, 490, 440, 206, "empty = click only  |  e.g. enter", "s8", this.MUTED, "Consolas")
        this.Lbl(2, 24, 468, 672, "Fischer finds the shake button on screen by its color and clicks it. Extra keys are tapped each cycle if set.", "s8", this.MUTED, "Consolas")

        this.Section(2, 24, 498, 672, "PROFILES AND CONFIG")
        this.Lbl(2, 24, 532, 170, "Profile")
        ddl := this.G.AddDropDownList("x200 y529 w190 c" this.FG, ["Default"])
        this.DarkCombo(ddl)
        ddl.OnEvent("Change", (*) => FischerApp.OnProfileSelect())
        this.Reg(2, ddl)
        this.Ctl["Profile.List"] := ddl
        this.Lbl(2, 410, 532, 50, "Name")
        this.Ctl["Profile.Name"] := this.Input(2, 460, 528, 236)

        this.Button(2, 24, 564, 212, 30, "SAVE CONFIG", (*) => FischerApp.OnSaveConfig(), this.ACCENT, "FFFFFF")
        this.Button(2, 254, 564, 212, 30, "EXPORT CONFIG", (*) => FischerApp.OnExport(), this.FIELD, this.FG, this.BORDER)
        this.Button(2, 484, 564, 212, 30, "LOAD CONFIG", (*) => FischerApp.OnLoad(), this.FIELD, this.FG, this.BORDER)
    }

    ; ---- tab 3: Webhook & Reports -----------------------------------------------------

    static BuildWebhookTab() {
        y := 132
        this.Check(3, 24, y, 400, "Enable Discord webhook", "Webhook.Enabled")
        this.Lbl(3, 24, y + 38, 300, "Webhook URL")
        this.Ctl["Webhook.Url"] := this.Input(3, 24, y + 62, 540)
        this.Button(3, 580, y + 61, 116, 26, "TEST WEBHOOK", (*) => FischerApp.OnTestWebhook(), this.FIELD, this.FG, this.BORDER)
        this.WebhookLbl := this.Lbl(3, 24, y + 94, 672, "Webhook status: not tested yet", "s8", this.MUTED, "Consolas")

        this.Section(3, 24, y + 124, 672, "REPORTS")
        this.Check(3, 24, y + 154, 300, "Send periodic Fischer Report", "Webhook.ReportEnabled")
        this.Lbl(3, 340, y + 156, 50, "Every")
        ddl := this.G.AddDropDownList("x390 y" (y + 152) " w70 c" this.FG, ["15", "30", "60"])
        this.DarkCombo(ddl)
        this.Reg(3, ddl)
        this.Ctl["Webhook.ReportIntervalMin"] := ddl
        this.Lbl(3, 470, y + 156, 60, "minutes")
        this.Button(3, 560, y + 152, 136, 26, "SEND REPORT NOW", (*) => FischerApp.OnReportNow(), this.FIELD, this.FG, this.BORDER)
        this.Check(3, 24, y + 188, 600, "Attach level screenshot to reports", "Webhook.AttachLevelImage")
        this.Check(3, 24, y + 222, 600, "Post `"fish successfully caught`" on every catch", "Webhook.NotifyCatch")

        this.Section(3, 24, y + 260, 672, "ERROR AND ALERT SETTINGS")
        this.Check(3, 24, y + 290, 300, "Ping me on Error / Disconnect", "Webhook.PingOnError")
        this.Lbl(3, 340, y + 292, 80, "Ping target")
        this.Ctl["Webhook.PingTarget"] := this.Input(3, 430, y + 288, 266)
        this.Check(3, 24, y + 324, 600, "Send In-Memory Screenshot on Failure", "Webhook.ScreenshotOnFailure")

        this.Lbl(3, 24, y + 368, 672, "Fischer never sets a webhook username or avatar. The name and icon configured on the webhook in your Discord server are always used.", "s8", this.MUTED, "Consolas", 34)
    }

    ; ---- tab 4: Calibration -------------------------------------------------------------

    static BuildCalibrationTab() {
        y := 132
        this.Section(4, 24, y, 672, "ULTRA-SIMPLE CALIBRATION")
        this.Lbl(4, 24, y + 28, 672, "1. Pick a step below (it advances by itself).   2. Hover the mouse over the target.   3. Press F2.", "s9", this.FG, "Segoe UI", 22)
        this.Lbl(4, 24, y + 56, 672, "Tip: cast once and leave the reel bar on screen, then press F2 on each point without clicking.", "s8", this.MUTED, "Consolas", 20)

        this.Lbl(4, 24, y + 90, 50, "Step")
        names := []
        for i, s in this.Steps
            names.Push(i ". " s[2])
        ddl := this.G.AddDropDownList("x80 y" (y + 86) " w616 c" this.FG " Choose1", names)
        this.DarkCombo(ddl)
        ddl.OnEvent("Change", (*) => FischerApp.OnStepSelect())
        this.Reg(4, ddl)
        this.Ctl["Calib.Step"] := ddl

        this.StepLbl := this.Lbl(4, 24, y + 124, 672, "", "s11 bold", this.ACCENT, "Consolas", 44)

        this.Button(4, 24, y + 176, 150, 30, "SKIP STEP", (*) => FischerApp.OnSkipStep(), this.FIELD, this.FG, this.BORDER)
        this.Button(4, 190, y + 176, 170, 30, "TEST SCAN (OCR)", (*) => FischerApp.OnTestScan(), this.FIELD, this.FG, this.BORDER)
        this.Button(4, 376, y + 176, 170, 30, "CLEAR ALL", (*) => FischerApp.OnClearCalibration(), this.FIELD, this.DANGER, this.DANGER)

        this.Section(4, 24, y + 222, 672, "SAVED CALIBRATION")
        fr := this.G.AddText("x23 y" (y + 251) " w562 h156 Background" this.BORDER)
        ed := this.G.AddEdit("x24 y" (y + 252) " w560 h154 ReadOnly Multi -E0x200 -VScroll Background" this.FIELD " c" this.FG, "")
        ed.SetFont("s9", "Consolas")
        this.Reg(4, fr)
        this.Reg(4, ed)
        this.Ctl["Calib.Details"] := ed

        this.Lbl(4, 604, y + 252, 92, "Fish color", "s8", this.MUTED, "Consolas")
        this.FishSw := this.G.AddText("x604 y" (y + 270) " w92 h30 Background" this.BORDER)
        this.Reg(4, this.FishSw)
        this.Lbl(4, 604, y + 312, 92, "Slider color", "s8", this.MUTED, "Consolas")
        this.SliderSw := this.G.AddText("x604 y" (y + 330) " w92 h30 Background" this.BORDER)
        this.Reg(4, this.SliderSw)

        this.UpdateStepLabel()
    }

    ; ==========================================================================
    ;  Config <-> UI
    ; ==========================================================================

    static LoadConfigToUi() {
        for f in this.NumFields
            this.Ctl[f[1] "." f[2]].Value := FischerConfig.Get(f[1], f[2])
        this.Ctl["Shake.Keys"].Value := FischerConfig.Get("Shake", "Keys")
        this.Ctl["Webhook.Url"].Value := FischerConfig.Get("Webhook", "Url")
        this.Ctl["Webhook.PingTarget"].Value := FischerConfig.Get("Webhook", "PingTarget")
        for key in ["Enabled", "NotifyCatch", "ReportEnabled", "AttachLevelImage", "PingOnError", "ScreenshotOnFailure"]
            this.Ctl["Webhook." key].Value := FischerConfig.Get("Webhook", key) ? 1 : 0
        idx := 2
        cur := FischerConfig.Int("Webhook", "ReportIntervalMin")
        for i, m in this.Intervals {
            if (m = cur)
                idx := i
        }
        this.Ctl["Webhook.ReportIntervalMin"].Choose(idx)
        name := FischerConfig.Get("General", "ProfileName")
        this.Ctl["Profile.Name"].Value := name
        this.ActiveLbl.Text := "Active Config: " name
        this.RefreshProfiles()
        this.UpdateCalibration()
    }

    ; Validate the inputs and copy them into the config. Returns false on bad input.
    static ApplyUi() {
        for f in this.NumFields {
            ed := this.Ctl[f[1] "." f[2]]
            v := Trim(ed.Value)
            if (!IsInteger(v) || Integer(v) < f[4] || Integer(v) > f[5]) {
                this.ShowTab(2)
                MsgBox(f[3] " must be a whole number from " f[4] " to " f[5] ".", "Fischer", "Icon!")
                ed.Focus()
                return false
            }
            FischerConfig.Set(f[1], f[2], Integer(v))
        }
        FischerConfig.Set("Shake", "Keys", Trim(this.Ctl["Shake.Keys"].Value))
        FischerConfig.Set("Webhook", "Url", Trim(this.Ctl["Webhook.Url"].Value))
        FischerConfig.Set("Webhook", "PingTarget", Trim(this.Ctl["Webhook.PingTarget"].Value))
        for key in ["Enabled", "NotifyCatch", "ReportEnabled", "AttachLevelImage", "PingOnError", "ScreenshotOnFailure"]
            FischerConfig.Set("Webhook", key, this.Ctl["Webhook." key].Value ? 1 : 0)
        sel := this.Ctl["Webhook.ReportIntervalMin"].Value
        FischerConfig.Set("Webhook", "ReportIntervalMin", this.Intervals[sel > 0 ? sel : 2])
        return true
    }

    static HasName(list, name) {
        for n in list {
            if (n = name)
                return true
        }
        return false
    }

    static RefreshProfiles() {
        ddl := this.Ctl["Profile.List"]
        names := FischerConfig.ListProfiles()
        cur := FischerConfig.Get("General", "ProfileName")
        if !this.HasName(names, cur)
            names.Push(cur)
        ddl.Delete()
        ddl.Add(names)
        for i, n in names {
            if (n = cur)
                ddl.Choose(i)
        }
    }

    ; Write the current config to config.json and to its profile file.
    static PersistConfig() {
        name := FischerConfig.Get("General", "ProfileName")
        DirCreate(FischerConfig.ProfileDir)
        FischerConfig.Save(FischerConfig.ProfilePath(name))
        FischerConfig.Save(FischerConfig.Path)
        this.RefreshProfiles()
    }

    ; ==========================================================================
    ;  Settings tab actions
    ; ==========================================================================

    static OnSaveConfig() {
        if !this.ApplyUi()
            return
        name := FischerConfig.SafeName(Trim(this.Ctl["Profile.Name"].Value) != "" ? this.Ctl["Profile.Name"].Value : FischerConfig.Get("General", "ProfileName"))
        FischerConfig.Set("General", "ProfileName", name)
        this.Ctl["Profile.Name"].Value := name
        this.ActiveLbl.Text := "Active Config: " name
        try {
            this.PersistConfig()
        } catch as e {
            MsgBox("Could not save the config:`n" e.Message, "Fischer", "Iconx")
            return
        }
        MsgBox("Saved profile '" name "'.", "Fischer", "Iconi")
    }

    static OnProfileSelect() {
        ddl := this.Ctl["Profile.List"]
        name := ddl.Text
        if FishSolver.Active {
            MsgBox("Stop the macro before switching profiles.", "Fischer", "Icon!")
            this.RefreshProfiles()
            return
        }
        path := FischerConfig.ProfilePath(name)
        if !FileExist(path)
            return
        try {
            FischerConfig.Load(path)
        } catch as e {
            MsgBox("Could not load profile '" name "':`n" e.Message, "Fischer", "Iconx")
            this.RefreshProfiles()
            return
        }
        FischerConfig.Set("General", "ProfileName", name)
        try FischerConfig.Save(FischerConfig.Path)
        this.LoadConfigToUi()
    }

    static OnExport() {
        if !this.ApplyUi()
            return
        withUrl := MsgBox("Include your Discord webhook URL in the exported file?`n`nChoose No when you plan to share the file with other people."
            , "Fischer - Export", "YesNo Icon?")
        name := FischerConfig.SafeName(FischerConfig.Get("General", "ProfileName"))
        path := FileSelect("S16", A_ScriptDir "\" name ".json", "Export Fischer config", "JSON (*.json)")
        if (path = "")
            return
        if !RegExMatch(path, "i)\.json$")
            path .= ".json"
        try {
            copy := FischerConfig.Merge(FischerConfig.Data)
            if (withUrl != "Yes")
                copy["Webhook"]["Url"] := ""
            FischerConfig.Save(path, copy)
        } catch as e {
            MsgBox("Could not export:`n" e.Message, "Fischer", "Iconx")
            return
        }
        MsgBox("Exported to:`n" path, "Fischer", "Iconi")
    }

    static OnLoad() {
        if FishSolver.Active {
            MsgBox("Stop the macro before loading a config.", "Fischer", "Icon!")
            return
        }
        file := FileSelect(3, A_ScriptDir, "Load Fischer config", "JSON (*.json)")
        if (file = "")
            return
        try {
            data := FischerConfig.Merge(FischerJson.Parse(FileRead(file, "UTF-8")))
        } catch as e {
            MsgBox("That file is not a valid Fischer config:`n" e.Message, "Fischer", "Iconx")
            return
        }
        SplitPath(file, , , , &stem)
        name := FischerConfig.SafeName(Trim(data["General"]["ProfileName"]) != "" && data["General"]["ProfileName"] != "Default" ? data["General"]["ProfileName"] : stem)
        data["General"]["ProfileName"] := name
        if (data["Webhook"]["Url"] = "")
            data["Webhook"]["Url"] := FischerConfig.Get("Webhook", "Url")      ; keep the local webhook
        FischerConfig.Data := data
        this.LoadConfigToUi()
        try {
            this.PersistConfig()
        } catch as e {
            MsgBox("Loaded, but could not store the profile:`n" e.Message, "Fischer", "Icon!")
            return
        }
        MsgBox("Loaded config '" name "'.", "Fischer", "Iconi")
    }

    ; ==========================================================================
    ;  Webhook tab actions
    ; ==========================================================================

    static OnTestWebhook() {
        if !this.ApplyUi()
            return
        this.WebhookLbl.SetFont("c" this.MUTED)
        this.WebhookLbl.Text := "Webhook status: sending test..."
        Webhook.Test((s, e) => FischerApp.SetWebhookStatus(s, e))
    }

    static SetWebhookStatus(status, err := "") {
        if (status >= 200 && status < 300) {
            this.WebhookLbl.SetFont("c" this.GOOD)
            this.WebhookLbl.Text := "Webhook status: OK (HTTP " status ")"
        } else {
            this.WebhookLbl.SetFont("c" this.DANGER)
            this.WebhookLbl.Text := "Webhook status: failed" (status ? " (HTTP " status ")" : "") (err != "" ? " - " err : "")
        }
        this.WebhookLbl.Redraw()
    }

    static OnReportNow() {
        if !this.ApplyUi()
            return
        if !Webhook.Enabled() {
            MsgBox("Enable the webhook and enter a valid Discord webhook URL first.", "Fischer", "Icon!")
            return
        }
        if FishSolver.Active {
            FishSolver.ReportDue := true          ; the macro sends it between casts
        } else {
            FishSolver.Coord()
            FishSolver.DoReport()
        }
    }

    ; ==========================================================================
    ;  Calibration
    ; ==========================================================================

    static OnStepSelect() {
        this.StepIdx := Max(1, this.Ctl["Calib.Step"].Value)
        this.UpdateStepLabel()
    }

    static OnSkipStep() {
        this.AdvanceStep()
    }

    static AdvanceStep() {
        this.StepIdx := (this.StepIdx < this.Steps.Length) ? this.StepIdx + 1 : 1
        this.Ctl["Calib.Step"].Choose(this.StepIdx)
        this.UpdateStepLabel()
    }

    static UpdateStepLabel() {
        s := this.Steps[this.StepIdx]
        this.StepLbl.Text := "Step " this.StepIdx "/" this.Steps.Length ": hover over " s[3] ", then press F2."
    }

    ; F2 handler.
    static Calibrate() {
        if FishSolver.Active
            return
        MouseGetPos(&mx, &my)
        id := this.Steps[this.StepIdx][1]
        switch id {
            case "BarTL":
                FischerConfig.Set("Regions", "ReelBarL", mx)
                FischerConfig.Set("Regions", "ReelBarT", my)
            case "BarBR":
                FischerConfig.Set("Regions", "ReelBarR", mx)
                FischerConfig.Set("Regions", "ReelBarB", my)
                this.NormalizeRegion("ReelBar")
            case "Fish":
                FischerConfig.Set("Colors", "FishColor", PixelGetColor(mx, my))
            case "Slider":
                FischerConfig.Set("Colors", "SliderColor", PixelGetColor(mx, my))
            case "Shake":
                FischerConfig.Set("Colors", "ShakeColor", PixelGetColor(mx, my))
            case "Slot1":
                FischerConfig.Set("Regions", "HotbarX", mx)
                FischerConfig.Set("Regions", "HotbarY", my)
            case "InfoTL":
                FischerConfig.Set("Regions", "InfoL", mx)
                FischerConfig.Set("Regions", "InfoT", my)
            case "InfoBR":
                FischerConfig.Set("Regions", "InfoR", mx)
                FischerConfig.Set("Regions", "InfoB", my)
                this.NormalizeRegion("Info")
            case "LevelTL":
                FischerConfig.Set("Regions", "LevelL", mx)
                FischerConfig.Set("Regions", "LevelT", my)
            case "LevelBR":
                FischerConfig.Set("Regions", "LevelR", mx)
                FischerConfig.Set("Regions", "LevelB", my)
                this.NormalizeRegion("Level")
        }
        try this.PersistConfig()
        this.UpdateCalibration()
        this.AdvanceStep()
    }

    ; Make sure the second corner really is bottom-right even if clicked in the other order.
    static NormalizeRegion(prefix) {
        l := FischerConfig.Int("Regions", prefix "L")
        t := FischerConfig.Int("Regions", prefix "T")
        r := FischerConfig.Int("Regions", prefix "R")
        b := FischerConfig.Int("Regions", prefix "B")
        FischerConfig.Set("Regions", prefix "L", Min(l, r))
        FischerConfig.Set("Regions", prefix "R", Max(l, r))
        FischerConfig.Set("Regions", prefix "T", Min(t, b))
        FischerConfig.Set("Regions", prefix "B", Max(t, b))
    }

    static RegionText(prefix) {
        if !FishSolver.RegionValid(prefix)
            return "NOT SET"
        r := FishSolver.Region(prefix)
        return r.L "," r.T "  ->  " r.R "," r.B "   (" (r.R - r.L) " x " (r.B - r.T) ")"
    }

    static UpdateCalibration() {
        hx := FischerConfig.Int("Regions", "HotbarX")
        hy := FischerConfig.Int("Regions", "HotbarY")
        fishC := FischerConfig.Get("Colors", "FishColor")
        shakeC := FischerConfig.Get("Colors", "ShakeColor")
        sliderC := FischerConfig.Get("Colors", "SliderColor")
        lines := "Reel bar region : " this.RegionText("ReelBar")
            . "`r`nFish color      : " fishC
            . "`r`nSlider color    : " sliderC
            . "`r`nShake button    : " shakeC
            . "`r`nHotbar slot 1   : " ((hx > 0 && hy > 0) ? hx "," hy : "NOT SET")
            . "`r`nRod info region : " this.RegionText("Info")
            . "`r`nLevel region    : " this.RegionText("Level")
        this.Ctl["Calib.Details"].Value := lines
        try {
            this.FishSw.Opt("+Background" Format("{:06X}", Integer(fishC)))
            this.FishSw.Redraw()
            this.SliderSw.Opt("+Background" Format("{:06X}", Integer(sliderC)))
            this.SliderSw.Redraw()
        }
    }

    static OnClearCalibration() {
        if FishSolver.Active
            return
        if (MsgBox("Clear every calibrated region and color?", "Fischer", "YesNo Icon?") != "Yes")
            return
        def := FischerConfig.Defaults()
        for k, v in def["Regions"]
            FischerConfig.Set("Regions", k, v)
        FischerConfig.Set("Colors", "FishColor", def["Colors"]["FishColor"])
        FischerConfig.Set("Colors", "SliderColor", def["Colors"]["SliderColor"])
        FischerConfig.Set("Colors", "ShakeColor", def["Colors"]["ShakeColor"])
        this.StepIdx := 1
        this.Ctl["Calib.Step"].Choose(1)
        this.UpdateStepLabel()
        try this.PersistConfig()
        this.UpdateCalibration()
    }

    ; Run the OCR scanners once so the user can verify their regions.
    static OnTestScan() {
        if FishSolver.Active {
            MsgBox("Stop the macro first.", "Fischer", "Icon!")
            return
        }
        if !this.ApplyUi()
            return
        if (!FishSolver.RegionValid("Info") && !FishSolver.RegionValid("Level")) {
            MsgBox("Calibrate the rod info region and/or the level region first (steps 6-10).", "Fischer", "Icon!")
            return
        }
        FishSolver.Coord()
        FishStats.Reset()
        ok1 := FishSolver.ScanEquipment()
        ok2 := FishSolver.ScanLevel()
        msg := "Rod: " FishStats.Rod "`nPrimary enchant: " FishStats.Primary "`nSecondary enchant: " FishStats.Secondary
            . "`nLevel: " (FishStats.Level > 0 ? FishStats.Level : "not read")
            . "`nCurrency: " (FishStats.Currency != "" ? FishStats.Currency : "not read")
            . "`n`nRaw rod text:`n" SubStr(Trim(FishStats.LastInfoText), 1, 300)
            . "`n`nRaw level text:`n" SubStr(Trim(FishStats.LastLevelText), 1, 200)
        if (!ok1 && !ok2)
            msg .= "`n`nNothing could be read. Check the regions, and that a Windows OCR language is installed."
        MsgBox(msg, "Fischer - Test Scan", "Iconi")
    }

    ; ==========================================================================
    ;  Macro control (hotkey and button targets)
    ; ==========================================================================

    static Start() {
        if FishSolver.Active
            return
        if !this.ApplyUi()
            return
        if !FishSolver.RegionValid("ReelBar") {
            this.ShowTab(4)
            MsgBox("The reel bar is not calibrated yet.`n`nOpen the Calibration tab and complete steps 1 and 2.", "Fischer", "Icon!")
            return
        }
        try this.PersistConfig()
        this.StartReportTimer()
        FishSolver.Start()
    }

    static Stop() {
        this.StopReportTimer()
        FishSolver.Stop()
    }

    static TogglePause() {
        FishSolver.TogglePause()
    }

    static StartReportTimer() {
        this.StopReportTimer()
        if (FischerConfig.Get("Webhook", "Enabled") && FischerConfig.Get("Webhook", "ReportEnabled")) {
            this.ReportFn := () => (FishSolver.ReportDue := true)
            SetTimer(this.ReportFn, FischerConfig.Int("Webhook", "ReportIntervalMin") * 60000)
        }
    }

    static StopReportTimer() {
        if this.ReportFn {
            SetTimer(this.ReportFn, 0)
            this.ReportFn := ""
        }
    }

    ; ==========================================================================
    ;  Engine callbacks
    ; ==========================================================================

    static OnStatus(s) {
        c := (s = "Idle") ? this.MUTED : (s = "Error") ? this.DANGER : (s = "Paused") ? this.AMBER : this.ACCENT
        this.StatusLbl.Text := "Status: " s
        this.StatusLbl.SetFont("c" c)
        this.StatusLbl.Redraw()
        if (!FishSolver.Active || s = "Idle")
            this.StopReportTimer()
        this.UpdateStats()
    }

    static OnCatch() {
        this.UpdateStats()
        Webhook.SendCatch()
    }

    static OnError(msg) {
        this.StopReportTimer()
        this.UpdateStats()
        try TrayTip(msg, "Fischer - error", "Iconx")
        if !Webhook.Enabled()
            return
        png := ""
        if FischerConfig.Get("Webhook", "ScreenshotOnFailure")
            png := FishSolver.ScreenshotPng()
        Webhook.SendError(msg, png, FischerConfig.Get("Webhook", "PingOnError"), FischerConfig.Get("Webhook", "PingTarget"))
    }

    static OnReport() {
        if !Webhook.Enabled()
            return
        gained := FishStats.LevelsGained()
        s := Map(
            "Caught", FishStats.Caught,
            "Rate", FishStats.Rate() "%",
            "Rod", FishStats.Rod,
            "Primary", FishStats.Primary,
            "Secondary", FishStats.Secondary,
            "Level", FishStats.Level > 0 ? FishStats.Level : "Unknown",
            "Gained", (FishStats.Level > 0 && FishStats.LevelAtLastReport > 0) ? "+" gained : "N/A",
            "Profile", FischerConfig.Get("General", "ProfileName"),
            "Uptime", this.Uptime(),
            "Currency", FishStats.Currency
        )
        png := ""
        if (FischerConfig.Get("Webhook", "AttachLevelImage") && FishStats.LevelPng is Buffer)
            png := FishStats.LevelPng
        Webhook.SendReport(s, png)
        FishStats.MarkReported()
    }

    ; ==========================================================================
    ;  Live stats on the Control tab
    ; ==========================================================================

    static Uptime() {
        secs := (FishSolver.Active && FishStats.StartTick) ? (A_TickCount - FishStats.StartTick) // 1000 : 0
        return Format("{:02d}:{:02d}:{:02d}", secs // 3600, Mod(secs, 3600) // 60, Mod(secs, 60))
    }

    static UpdateStats() {
        txt := "Caught: " FishStats.Caught "    Minigames: " FishStats.Minigames "    Success: " FishStats.Rate() "%"
            . "`nRod: " FishStats.Rod "    Enchants: " FishStats.Primary " / " FishStats.Secondary
            . "`nLevel: " (FishStats.Level > 0 ? FishStats.Level : "Unknown") "    Session: " this.Uptime()
        if (this.StatsLbl.Text != txt)
            this.StatsLbl.Text := txt
    }
}


; ==============================================================================
;  Go
; ==============================================================================
FischerApp.Init()
