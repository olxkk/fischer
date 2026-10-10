; =============================================================================
;  Config.ahk  -  Loads and saves config.json
;
;  - Every setting is listed once in Config.Schema() with its default and type.
;  - Missing keys, wrong types and out-of-range values fall back to the default
;    and add a message to Config.Warnings (the GUI shows them in its log).
;  - A missing config.json is created from the defaults.
;  - A config.json that is not valid JSON is kept as config.json.bad and
;    replaced by the defaults, so the macro always starts.
;
;  Types: int, ratio (0.0-1.0), bool, str, color (0xRRGGBB, stored as text)
; =============================================================================
#Requires AutoHotkey v2.0

class Config {
    static Path := A_ScriptDir "\config.json"
    static Warnings := []

    ; Each row: [key, default, type]. Order here is the order in config.json.
    static Schema() {
        return [
            ["CastHoldTimeMs", 1000, "int"],
            ["ScanIntervalMs", 10, "int"],
            ["CastKey", "LButton", "str"],
            ["RobloxWindow", "ahk_exe RobloxPlayerBeta.exe", "str"],

            ["EnableWebhook", false, "bool"],
            ["DiscordWebhookURL", "", "str"],
            ["WebhookOnCast", true, "bool"],
            ["WebhookOnHook", true, "bool"],

            ["ToggleKey", "F8", "str"],
            ["ExitKey", "F12", "str"],
            ["CalibrateKey", "F9", "str"],

            ["ShakeEnabled", true, "bool"],
            ["NavKey", "\", "str"],
            ["ShakeNavKeyEveryCast", true, "bool"],
            ["ShakeStartDelayMs", 1200, "int"],
            ["BiteTimeoutMs", 30000, "int"],

            ["ReelLeft", 0.28, "ratio"],
            ["ReelTop", 0.76, "ratio"],
            ["ReelRight", 0.72, "ratio"],
            ["ReelBottom", 0.88, "ratio"],
            ["FishColor", 0x5B4B43, "color"],
            ["BarColor", 0xFFFFFF, "color"],
            ["FishTolerance", 12, "int"],
            ["BarTolerance", 12, "int"],
            ["BarScanStepPx", 4, "int"],
            ["BarMaxGapSteps", 3, "int"],

            ["DeadzonePx", 12, "int"],
            ["CatchEndMisses", 25, "int"],
            ["MinigameTimeoutMs", 90000, "int"],
            ["PostCatchDelayMs", 1500, "int"]
        ]
    }

    static Defaults() {
        m := Map()
        m.CaseSense := false
        for d in Config.Schema()
            m[d[1]] := d[2]
        return m
    }

    ; Returns a Map with every key of the schema. Never throws.
    static Load(path := "") {
        if (path = "")
            path := Config.Path
        Config.Warnings := []
        cfg := Config.Defaults()

        if !FileExist(path) {
            Config.Warnings.Push("config.json not found; created it with default values.")
            Config.Save(cfg, path)
            return cfg
        }

        try {
            data := Json.Parse(FileRead(path, "UTF-8"))
            if !(data is Map)
                throw Error("the top level must be a JSON object")
        } catch as e {
            try FileMove(path, path ".bad", true)
            Config.Warnings.Push("config.json could not be read (" e.Message "). Defaults are in use; "
                . "the broken file was kept as config.json.bad.")
            Config.Save(cfg, path)
            return cfg
        }

        for d in Config.Schema() {
            key := d[1]
            if data.Has(key)
                cfg[key] := Config.Coerce(data[key], d[3], d[2], key)
        }

        ; Sanity clamps
        cfg["ScanIntervalMs"] := Max(1, cfg["ScanIntervalMs"])
        cfg["BarScanStepPx"] := Max(1, cfg["BarScanStepPx"])
        cfg["CatchEndMisses"] := Max(1, cfg["CatchEndMisses"])
        cfg["FishTolerance"] := Min(255, cfg["FishTolerance"])
        cfg["BarTolerance"] := Min(255, cfg["BarTolerance"])
        return cfg
    }

    ; Convert a parsed JSON value to the schema type, or return the default.
    static Coerce(raw, type, default, key) {
        switch type {
            case "int":
                if (IsInteger(raw) && Integer(raw) >= 0)
                    return Integer(raw)
            case "ratio":
                if (IsNumber(raw) && raw >= 0 && raw <= 1)
                    return Float(raw)
            case "bool":
                if (raw is Integer && (raw = 0 || raw = 1))
                    return raw ? true : false
                if (raw is String) {
                    low := StrLower(Trim(raw))
                    if (low = "true" || low = "yes" || low = "on" || low = "1")
                        return true
                    if (low = "false" || low = "no" || low = "off" || low = "0")
                        return false
                }
            case "str":
                if (raw is String)
                    return Trim(raw)
            case "color":
                if (IsInteger(raw) && Integer(raw) >= 0 && Integer(raw) <= 0xFFFFFF)
                    return Integer(raw)
                if (raw is String && RegExMatch(Trim(raw), "^#([0-9A-Fa-f]{6})$", &m))
                    return Integer("0x" m[1])
        }
        Config.Warnings.Push("Invalid value for " key "; using the default (" String(default) ").")
        return default
    }

    ; Write every schema key to config.json. Returns true on success.
    static Save(cfg, path := "") {
        if (path = "")
            path := Config.Path
        schema := Config.Schema()
        out := "{`n"
        for i, d in schema {
            key := d[1]
            value := cfg.Has(key) ? cfg[key] : d[2]
            out .= '  "' key '": ' Config.Encode(value, d[3]) (i < schema.Length ? "," : "") "`n"
        }
        out .= "}`n"
        try {
            tmp := path ".tmp"
            try FileDelete(tmp)
            FileAppend(out, tmp, "UTF-8-RAW")
            FileMove(tmp, path, true)       ; replace in one step so a crash cannot leave half a file
            return true
        } catch {
            return false
        }
    }

    static Encode(value, type) {
        switch type {
            case "int":
                return String(Integer(value))
            case "ratio":
                return RTrim(RTrim(Format("{:.4f}", value), "0"), ".")
            case "bool":
                return value ? "true" : "false"
            case "color":
                return '"' Format("0x{:06X}", value) '"'
            default:
                return '"' Json.Escape(value) '"'
        }
    }
}
