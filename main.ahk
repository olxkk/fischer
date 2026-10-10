; =============================================================================
;  Fisch Fishing Macro  -  AutoHotkey v2
;  Entry point: loads config.json, opens the GUI, wires the global hotkeys.
;
;  Files:
;    main.ahk             this file (start-up, hotkeys, calibration helper)
;    config.json          your settings (created on first run, git-ignored)
;    config.example.json  reference copy of the default settings
;    lib\Json.ahk         small JSON reader
;    lib\Config.ahk       loads / validates / saves config.json
;    lib\Webhook.ahk      Discord webhook sender (async) + test
;    lib\FishSolver.ahk   cast / bite / minigame logic
;    lib\GUI.ahk          the control window
; =============================================================================
#Requires AutoHotkey v2.0
#SingleInstance Force
Persistent()

#Include "%A_ScriptDir%\lib\Json.ahk"
#Include "%A_ScriptDir%\lib\Config.ahk"
#Include "%A_ScriptDir%\lib\Webhook.ahk"
#Include "%A_ScriptDir%\lib\FishSolver.ahk"
#Include "%A_ScriptDir%\lib\GUI.ahk"

SetWorkingDir(A_ScriptDir)
CoordMode("Pixel", "Screen")     ; PixelSearch / PixelGetColor use screen coords
CoordMode("Mouse", "Screen")
DllCall("winmm\timeBeginPeriod", "UInt", 1)   ; finer Sleep() resolution (~1ms)

cfg := Config.Load()
hook := Webhook()
webhookWarning := hook.Configure(cfg["DiscordWebhookURL"], cfg["EnableWebhook"])
solver := FishSolver(cfg, hook)
ui := MacroGui(cfg, solver, hook)

for message in Config.Warnings
    ui.Log(message)
if (webhookWarning != "")
    ui.Log(webhookWarning)

; The hotkeys call the same methods as the buttons in the window.
BindKey(cfg["ToggleKey"], (*) => ui.Toggle(), "F8", "ToggleKey")
BindKey(cfg["ExitKey"], (*) => ExitApp(), "F12", "ExitKey")
BindKey(cfg["CalibrateKey"], CalibrateHelper, "F9", "CalibrateKey")
OnExit(ShutdownMacro)

ui.Log("Ready. Press " cfg["ToggleKey"] " or Start Macro to begin.")
ui.Show()

; ----------------------------------------------------------------------------
ShutdownMacro(exitReason, exitCode) {
    solver.Shutdown()                             ; sends "Stopped" webhook, releases mouse
    DllCall("winmm\timeEndPeriod", "UInt", 1)
}

; Calibration helper: hover the mouse over the reel bar / fish icon and press
; the CalibrateKey. It shows the pixel colour and the position as a ratio of
; the Roblox client area, writes them to the log and copies them to the clipboard.
CalibrateHelper(*) {
    MouseGetPos(&mx, &my)
    color := Format("0x{:06X}", Integer(PixelGetColor(mx, my)))
    text := "Colour: " color "  Screen: " mx ", " my
    hwnd := WinExist(cfg["RobloxWindow"])
    if hwnd {
        WinGetClientPos(&x, &y, &w, &h, "ahk_id " hwnd)
        rx := Round((mx - x) / w, 3)
        ry := Round((my - y) / h, 3)
        text .= "  Ratio: x=" rx " y=" ry
    }
    A_Clipboard := text
    ui.Log("Calibration: " text " (copied to clipboard)")
    CoordMode("ToolTip", "Screen")
    ToolTip(StrReplace(text, "  ", "`n"), mx + 20, my + 20, 2)
    SetTimer(() => ToolTip(, , , 2), -4000)
}

BindKey(key, fn, fallback, name) {
    try {
        Hotkey(key, fn, "On")
        return
    } catch {
    }
    ui.Log("Invalid " name " '" key "'; using '" fallback "' instead.")
    try Hotkey(fallback, fn, "On")
}
