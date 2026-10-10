; =============================================================================
;  Webhook.ahk  -  Non-blocking Discord webhook sender
;
;  Requests are opened with the async flag (Open(..., true)), so Send() returns
;  immediately and the fishing loop never waits on the network. In-flight
;  request objects are kept in this.Pending (otherwise AHK would free them and
;  abort the request) and are pruned by a small timer.
; =============================================================================
#Requires AutoHotkey v2.0

class Webhook {
    static COLOR_GREEN := 0x57F287
    static COLOR_RED := 0xED4245
    static COLOR_BLUE := 0x5865F2
    static COLOR_YELLOW := 0xFEE75C
    static COLOR_GREY := 0x99AAB5

    Username := "Fisch Macro"

    __New(url := "", enabled := false) {
        this.Url := ""
        this.Enabled := false
        this.Pending := []
        this.CleanupFn := ObjBindMethod(this, "Cleanup")
        SetTimer(this.CleanupFn, 3000)
        this.Configure(url, enabled)
    }

    ; Apply a new URL / enabled flag (the GUI calls this whenever settings change).
    ; Returns "" when fine, or a warning message when it was asked to be enabled
    ; but the URL is missing or not a Discord webhook URL (then it stays off).
    Configure(url, enabled) {
        this.Url := Trim(url)
        valid := Webhook.IsValidUrl(this.Url)
        this.Enabled := enabled && valid
        if (enabled && !valid) {
            if (this.Url = "")
                return "Webhook is enabled but no URL is set; webhook messages are off."
            return "That does not look like a Discord webhook URL; webhook messages are off."
        }
        return ""
    }

    static IsValidUrl(url) {
        return RegExMatch(url, "i)^https://([a-z]+\.)?discord(app)?\.com/api/webhooks/\S+$") ? true : false
    }

    ; Blocking test used by the "Test Webhook" button (it needs the HTTP result).
    ; Works with any URL, even when the webhook is switched off.
    ; Returns Map("ok", true/false, "message", text).
    Test(url) {
        url := Trim(url)
        if !Webhook.IsValidUrl(url)
            return Map("ok", false
                , "message", "That does not look like a Discord webhook URL (https://discord.com/api/webhooks/...).")
        payload := this.BuildPayload("Webhook Test", "If you can read this, the webhook works.", Webhook.COLOR_GREEN, "")
        try {
            whr := ComObject("WinHttp.WinHttpRequest.5.1")
            whr.SetTimeouts(5000, 5000, 10000, 10000)
            whr.Open("POST", url, false)                   ; false = wait for the answer
            whr.SetRequestHeader("Content-Type", "application/json; charset=utf-8")
            whr.Send(payload)
            code := whr.Status
            if (code >= 200 && code < 300)
                return Map("ok", true, "message", "test message sent (HTTP " code ").")
            return Map("ok", false, "message", "Discord answered HTTP " code ". Check that the webhook still exists.")
        } catch as e {
            return Map("ok", false, "message", "request failed: " e.Message)
        }
    }

    ; fields: optional array of Map("name", .., "value", .., "inline", true/false)
    Send(title, description := "", color := Webhook.COLOR_BLUE, fields := "") {
        if !this.Enabled
            return false
        payload := this.BuildPayload(title, description, color, fields)
        try {
            whr := ComObject("WinHttp.WinHttpRequest.5.1")
            whr.SetTimeouts(5000, 5000, 10000, 10000)
            whr.Open("POST", this.Url, true)               ; true = asynchronous
            whr.SetRequestHeader("Content-Type", "application/json; charset=utf-8")
            whr.Send(payload)
            this.Pending.Push(whr)                         ; keep alive until finished
            return true
        } catch {
            return false                                   ; never let a webhook error stop fishing
        }
    }

    BuildPayload(title, description, color, fields) {
        embed := '{"title":"' Webhook.Escape(title) '"'
        if (description != "")
            embed .= ',"description":"' Webhook.Escape(description) '"'
        embed .= ',"color":' color
        embed .= ',"timestamp":"' FormatTime(A_NowUTC, "yyyy-MM-dd'T'HH:mm:ss'Z'") '"'
        if IsObject(fields) && fields.Length {
            embed .= ',"fields":['
            for i, f in fields {
                if (i > 1)
                    embed .= ","
                inline := (f.Has("inline") && f["inline"]) ? "true" : "false"
                embed .= '{"name":"' Webhook.Escape(f["name"]) '","value":"' Webhook.Escape(f["value"])
                    . '","inline":' inline '}'
            }
            embed .= "]"
        }
        embed .= ',"footer":{"text":"Fisch Macro"}}'
        return '{"username":"' Webhook.Escape(this.Username) '","embeds":[' embed ']}'
    }

    ; Drop finished requests from the pending list.
    Cleanup() {
        i := this.Pending.Length
        while (i >= 1) {
            done := true
            try done := this.Pending[i].WaitForResponse(0)   ; 0 = poll, don't block
            if done
                this.Pending.RemoveAt(i)
            i--
        }
    }

    ; Give in-flight requests a moment to finish (used on exit only).
    Flush(timeoutSec := 2) {
        for whr in this.Pending
            try whr.WaitForResponse(timeoutSec)
        this.Pending := []
    }

    ; JSON string escaping. Non-ASCII is written as \uXXXX so the payload is
    ; pure ASCII and cannot be mangled by code-page conversion.
    static Escape(s) {
        out := ""
        Loop Parse, String(s) {
            c := A_LoopField
            code := Ord(c)
            if (c == "\")
                out .= "\\"
            else if (code = 34)
                out .= '\"'
            else if (code = 10)
                out .= "\n"
            else if (code = 13)
                out .= "\r"
            else if (code = 9)
                out .= "\t"
            else if (code < 32 || code > 126)
                out .= Format("\u{:04x}", code)
            else
                out .= c
        }
        return out
    }
}
