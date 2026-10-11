; ==============================================================================
;  Fischer - lib/Webhook.ahk
;  Asynchronous Discord webhook handler, "Fischer Report" embed builder,
;  in-memory screenshot poster, and the small JSON helper used across the project.
;
;  Contents
;    FischerJsonBool : marker class so booleans serialize as true / false
;    FischerJson     : minimal JSON parser + serializer (AHK v2 has no native JSON)
;    FischerBytes    : growable byte buffer for building HTTP bodies
;    Webhook         : static class that builds and posts webhook payloads
;
;  Design rules
;    * Requests use WinHttp.WinHttpRequest.5.1 in asynchronous mode.
;    * Payloads NEVER contain "username" or "avatar_url", so the name and icon
;      configured on the Discord webhook itself are always used.
;    * Screenshots are PNG-encoded in memory and uploaded as a multipart
;      attachment. Nothing is written to the user's disk.
; ==============================================================================
#Requires AutoHotkey v2.0


; ------------------------------------------------------------------------------
;  Boolean marker
; ------------------------------------------------------------------------------
class FischerJsonBool {
    __New(value) {
        this.Value := value ? true : false
    }
}


; ------------------------------------------------------------------------------
;  JSON helper
;    Parse     : text -> Map / Array / String / Number   (objects become Maps)
;    Stringify : Map / Array / String / Number / FischerJsonBool -> text
; ------------------------------------------------------------------------------
class FischerJson {

    static Parse(src) {
        i := 1
        v := FischerJson._Val(src, &i)
        FischerJson._Ws(src, &i)
        if (i <= StrLen(src))
            throw Error("Unexpected trailing data at character " i)
        return v
    }

    static _Ws(s, &i) {
        n := StrLen(s)
        while (i <= n && InStr(" `t`r`n", SubStr(s, i, 1)))
            i++
    }

    static _Val(s, &i) {
        FischerJson._Ws(s, &i)
        c := SubStr(s, i, 1)
        if (c = "{")
            return FischerJson._Obj(s, &i)
        if (c = "[")
            return FischerJson._Arr(s, &i)
        if (c = '"')
            return FischerJson._Str(s, &i)
        if (SubStr(s, i, 4) = "true") {
            i += 4
            return true
        }
        if (SubStr(s, i, 5) = "false") {
            i += 5
            return false
        }
        if (SubStr(s, i, 4) = "null") {
            i += 4
            return ""
        }
        if RegExMatch(s, "A)-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?", &m, i) {
            i += m.Len
            return Number(m[0])
        }
        throw Error("Invalid JSON value at character " i)
    }

    static _Obj(s, &i) {
        m := Map()
        i++
        FischerJson._Ws(s, &i)
        if (SubStr(s, i, 1) = "}") {
            i++
            return m
        }
        loop {
            FischerJson._Ws(s, &i)
            if (SubStr(s, i, 1) != '"')
                throw Error("Expected a string key at character " i)
            k := FischerJson._Str(s, &i)
            FischerJson._Ws(s, &i)
            if (SubStr(s, i, 1) != ":")
                throw Error("Expected ':' at character " i)
            i++
            m[k] := FischerJson._Val(s, &i)
            FischerJson._Ws(s, &i)
            c := SubStr(s, i, 1)
            i++
            if (c = "}")
                return m
            if (c != ",")
                throw Error("Expected ',' or '}' at character " (i - 1))
        }
    }

    static _Arr(s, &i) {
        a := []
        i++
        FischerJson._Ws(s, &i)
        if (SubStr(s, i, 1) = "]") {
            i++
            return a
        }
        loop {
            a.Push(FischerJson._Val(s, &i))
            FischerJson._Ws(s, &i)
            c := SubStr(s, i, 1)
            i++
            if (c = "]")
                return a
            if (c != ",")
                throw Error("Expected ',' or ']' at character " (i - 1))
        }
    }

    static _Str(s, &i) {
        i++
        out := ""
        n := StrLen(s)
        while (i <= n) {
            c := SubStr(s, i, 1)
            if (c = '"') {
                i++
                return out
            }
            if (c = "\") {
                i++
                e := SubStr(s, i, 1)
                switch e {
                    case "n":
                        out .= "`n"
                    case "r":
                        out .= "`r"
                    case "t":
                        out .= "`t"
                    case "b":
                        out .= "`b"
                    case "f":
                        out .= "`f"
                    case "u":
                        out .= Chr(Integer("0x" SubStr(s, i + 1, 4)))
                        i += 4
                    default:
                        out .= e
                }
            } else {
                out .= c
            }
            i++
        }
        throw Error("Unterminated JSON string")
    }

    static Stringify(v, indent := "", step := "  ") {
        if (v is FischerJsonBool)
            return v.Value ? "true" : "false"
        if (v is Map) {
            if (v.Count = 0)
                return "{}"
            out := ""
            for k, val in v
                out .= (out = "" ? "" : ",`n") indent step FischerJson._Quote(String(k)) ": " FischerJson.Stringify(val, indent step, step)
            return "{`n" out "`n" indent "}"
        }
        if (v is Array) {
            if (v.Length = 0)
                return "[]"
            out := ""
            for val in v
                out .= (out = "" ? "" : ",`n") indent step FischerJson.Stringify(val, indent step, step)
            return "[`n" out "`n" indent "]"
        }
        if (v is Integer || v is Float)
            return String(v)
        if IsObject(v)
            throw TypeError("Cannot serialize object of type " Type(v) " to JSON")
        return FischerJson._Quote(String(v))
    }

    static _Quote(s) {
        s := StrReplace(s, "\", "\\")
        s := StrReplace(s, '"', '\"')
        s := StrReplace(s, "`n", "\n")
        s := StrReplace(s, "`r", "\r")
        s := StrReplace(s, "`t", "\t")
        if RegExMatch(s, "[\x00-\x1F]") {
            loop 31 {
                ch := Chr(A_Index)
                if InStr(s, ch)
                    s := StrReplace(s, ch, Format("\u{:04x}", A_Index))
            }
        }
        return '"' s '"'
    }
}


; ------------------------------------------------------------------------------
;  Growable byte buffer (used to build UTF-8 JSON bodies and multipart bodies)
; ------------------------------------------------------------------------------
class FischerBytes {
    __New() {
        this.buf := Buffer(4096)
        this.len := 0
    }

    _Need(n) {
        if (this.len + n > this.buf.Size)
            this.buf.Size := Max(this.buf.Size * 2, this.len + n)
    }

    AddText(str) {
        n := StrPut(str, "UTF-8")
        this._Need(n)
        StrPut(str, this.buf.Ptr + this.len, n, "UTF-8")
        this.len += n - 1
    }

    AddBuf(b) {
        this._Need(b.Size)
        DllCall("RtlMoveMemory", "ptr", this.buf.Ptr + this.len, "ptr", b.Ptr, "uptr", b.Size)
        this.len += b.Size
    }

    ToBuffer() {
        out := Buffer(this.len)
        DllCall("RtlMoveMemory", "ptr", out.Ptr, "ptr", this.buf.Ptr, "uptr", this.len)
        return out
    }
}


; ------------------------------------------------------------------------------
;  Discord webhook client
; ------------------------------------------------------------------------------
class Webhook {
    static Pending := []          ; in-flight async requests
    static ReapFn := ""           ; timer callback that finishes requests
    static LastCatchTick := 0
    static MinCatchGapMs := 1500  ; protects the webhook from Discord rate limits

    ; ---- state helpers -------------------------------------------------------

    static UrlLooksValid(url) {
        return RegExMatch(Trim(url), "i)^https://(?:(?:ptb|canary)\.)?discord(?:app)?\.com/api/webhooks/\d+/[\w\-]+")
    }

    ; True when webhooks are switched on and a valid URL is configured.
    static Enabled() {
        return FischerConfig.Get("Webhook", "Enabled") && this.UrlLooksValid(FischerConfig.Get("Webhook", "Url"))
    }

    ; ---- public senders ------------------------------------------------------

    ; Instant activity message. Text is intentionally plain.
    static SendCatch() {
        if !this.Enabled() || !FischerConfig.Get("Webhook", "NotifyCatch")
            return false
        if (A_TickCount - this.LastCatchTick < this.MinCatchGapMs)
            return false
        this.LastCatchTick := A_TickCount
        payload := Map(
            "content", "fish successfully caught",
            "allowed_mentions", Map("parse", [])
        )
        return this._PostJson(payload)
    }

    ; Connection test. Ignores the Enabled flag but still needs a valid URL.
    ; callback(status, errorText) is called when the request finishes.
    static Test(callback := "") {
        payload := Map(
            "content", "Fischer webhook test: connection OK.",
            "allowed_mentions", Map("parse", [])
        )
        return this._PostJson(payload, callback)
    }

    ; "Fischer Report" embed. stats is a Map of already formatted strings:
    ;   Caught, Rate, Rod, Primary, Secondary, Level, Gained, Profile, Uptime, Currency
    ; png (optional Buffer) is attached as the level screenshot.
    static SendReport(stats, png := "") {
        if !this.Enabled()
            return false
        fields := [
            this._Field("Total Fish Caught", stats["Caught"]),
            this._Field("Success Rate", stats["Rate"]),
            this._Field("Equipped Rod", stats["Rod"]),
            this._Field("Primary Enchant", stats["Primary"]),
            this._Field("Secondary Enchant", stats["Secondary"]),
            this._Field("Current Level", stats["Level"]),
            this._Field("Levels Gained Since Last Report", stats["Gained"]),
            this._Field("Active Config", stats["Profile"]),
            this._Field("Session Time", stats["Uptime"])
        ]
        if (stats["Currency"] != "")
            fields.Push(this._Field("Currency", stats["Currency"]))
        embed := Map(
            "title", "Fischer Report",
            "color", 3900150,
            "fields", fields,
            "timestamp", this._Now(),
            "footer", Map("text", "Fischer v" FischerApp.Version)
        )
        hasImg := (png is Buffer)
        if hasImg
            embed["image"] := Map("url", "attachment://level.png")
        payload := Map("embeds", [embed], "allowed_mentions", Map("parse", []))
        if hasImg
            return this._PostMultipart(payload, "level.png", png)
        return this._PostJson(payload)
    }

    ; Error / disconnect alert with optional ping and optional screenshot (Buffer).
    static SendError(message, png := "", ping := false, pingTarget := "") {
        if !this.Enabled()
            return false
        mentions := Map("parse", [])
        content := ""
        if ping {
            content := Trim(pingTarget) != "" ? Trim(pingTarget) : "@everyone"
            mentions := Map("parse", ["everyone", "users", "roles"])
        }
        embed := Map(
            "title", "Fischer Alert",
            "description", message,
            "color", 15158332,
            "fields", [
                this._Field("Active Config", FischerConfig.Get("General", "ProfileName")),
                this._Field("Fish Caught This Session", String(FishStats.Caught))
            ],
            "timestamp", this._Now(),
            "footer", Map("text", "Fischer v" FischerApp.Version)
        )
        hasImg := (png is Buffer)
        if hasImg
            embed["image"] := Map("url", "attachment://failure.png")
        payload := Map("embeds", [embed], "allowed_mentions", mentions)
        if (content != "")
            payload["content"] := content
        if hasImg
            return this._PostMultipart(payload, "failure.png", png)
        return this._PostJson(payload)
    }

    ; ---- payload helpers -----------------------------------------------------

    static _Field(name, value, inline := true) {
        v := String(value)
        if (v = "")
            v := "-"
        return Map("name", name, "value", v, "inline", FischerJsonBool(inline))
    }

    static _Now() {
        return FormatTime(A_NowUTC, "yyyy-MM-dd'T'HH:mm:ss'Z'")
    }

    ; Override guard: the webhook's own username and avatar must always win.
    static _Sanitize(payload) {
        for key in ["username", "avatar_url", "avatar"]
            if payload.Has(key)
                payload.Delete(key)
    }

    static _PostJson(payload, callback := "") {
        this._Sanitize(payload)
        w := FischerBytes()
        w.AddText(FischerJson.Stringify(payload))
        return this._Dispatch(w.ToBuffer(), "application/json", callback)
    }

    static _PostMultipart(payload, filename, png, callback := "") {
        this._Sanitize(payload)
        boundary := "----FischerBoundary" A_TickCount A_MSec
        w := FischerBytes()
        w.AddText("--" boundary "`r`n")
        w.AddText('Content-Disposition: form-data; name="payload_json"`r`n')
        w.AddText("Content-Type: application/json`r`n`r`n")
        w.AddText(FischerJson.Stringify(payload) "`r`n")
        w.AddText("--" boundary "`r`n")
        w.AddText('Content-Disposition: form-data; name="files[0]"; filename="' filename '"`r`n')
        w.AddText("Content-Type: image/png`r`n`r`n")
        w.AddBuf(png)
        w.AddText("`r`n--" boundary "--`r`n")
        return this._Dispatch(w.ToBuffer(), "multipart/form-data; boundary=" boundary, callback)
    }

    ; ---- async transport -----------------------------------------------------

    static _ToSafeArray(buf) {
        arr := ComObjArray(0x11, buf.Size)          ; VT_UI1 byte array
        pData := NumGet(ComObjValue(arr), 8 + A_PtrSize, "ptr")
        DllCall("RtlMoveMemory", "ptr", pData, "ptr", buf.Ptr, "uptr", buf.Size)
        return arr
    }

    static _Dispatch(body, contentType, callback := "") {
        url := Trim(FischerConfig.Get("Webhook", "Url"))
        cb := callback ? callback : (s, e) => FischerApp.SetWebhookStatus(s, e)
        if !this.UrlLooksValid(url) {
            cb.Call(0, "Webhook URL is missing or not a Discord webhook URL.")
            return false
        }
        try {
            arr := this._ToSafeArray(body)
            req := ComObject("WinHttp.WinHttpRequest.5.1")
            req.Open("POST", url, true)                      ; true = asynchronous
            req.SetTimeouts(10000, 10000, 30000, 30000)
            req.SetRequestHeader("Content-Type", contentType)
            req.SetRequestHeader("User-Agent", "Fischer/" FischerApp.Version " (AutoHotkey v2)")
            req.Send(arr)
        } catch as e {
            cb.Call(0, e.Message)
            return false
        }
        this.Pending.Push({req: req, body: arr, cb: cb, t: A_TickCount})
        if !this.ReapFn {
            this.ReapFn := ObjBindMethod(Webhook, "Reap")
            SetTimer(this.ReapFn, 500)
        }
        return true
    }

    ; Timer: finish completed requests, report their HTTP status, free the objects.
    static Reap() {
        i := this.Pending.Length
        while (i >= 1) {
            item := this.Pending[i]
            done := false
            status := 0
            err := ""
            try {
                done := item.req.WaitForResponse(0)
                if done
                    status := item.req.Status
            } catch as e {
                done := true
                err := e.Message
            }
            if (!done && A_TickCount - item.t > 60000) {
                done := true
                err := "Request timed out"
            }
            if done {
                this.Pending.RemoveAt(i)
                try item.cb.Call(status, err)
            }
            i--
        }
        if (this.Pending.Length = 0 && this.ReapFn) {
            SetTimer(this.ReapFn, 0)
            this.ReapFn := ""
        }
    }
}
