; ============================================================================
; lib/Webhook.ahk
; Discord webhook module.
;
;   * Requests go through WinHttp.WinHttpRequest.5.1 in ASYNC mode, so the
;     macro never waits on the network. Finished requests are collected by a
;     small timer which then calls your optional callback cb(status, text).
;   * Screenshots are captured with GDI+, encoded to PNG in memory and sent as
;     a multipart attachment. Nothing is ever written to disk.
;
; Requires lib/Json.ahk.
; ============================================================================

class Webhook {
    static Pending := []
    static Timer := 0
    static BLUE := 0x4F8CFF
    static GREEN := 0x4ADE80
    static YELLOW := 0xFBBF24
    static RED := 0xFF5C5C

    ; ---- validation ---------------------------------------------------------

    static IsValidUrl(url) {
        return RegExMatch(Trim(url), "i)^https://(?:[a-z]+\.)?discord(?:app)?\.com/api/webhooks/\d+/[\w-]+")
    }

    static Ready(cfg) {
        return cfg["WebhookEnabled"] && Webhook.IsValidUrl(cfg["WebhookUrl"])
    }

    ; ---- public senders -----------------------------------------------------

    ; Sends a test embed. cb(status, text) is called when the request finishes.
    static Test(url, cb := "") {
        embed := Webhook.Embed("Webhook test", "Fisch Macro can reach this channel.", Webhook.GREEN)
        payload := Map("username", "Fisch Macro", "embeds", [embed])
        return Webhook.Post(Trim(url), Json.Dump(payload, ["inline"]), cb)
    }

    ; Short status message (started / paused / resumed / stopped).
    static SendEvent(cfg, title, desc, color := 0x4F8CFF) {
        if !Webhook.Ready(cfg)
            return false
        embed := Webhook.Embed(title, desc, color)
        payload := Map("username", "Fisch Macro", "embeds", [embed])
        return Webhook.Post(Trim(cfg["WebhookUrl"]), Json.Dump(payload, ["inline"]))
    }

    ; The periodic "Fischer Report".
    ; stats keys: intervalCaught, intervalAttempts, totalCaught, totalAttempts, uptimeSec
    static SendReport(cfg, stats) {
        if !Webhook.Ready(cfg)
            return false
        caught := stats["intervalCaught"]
        attempts := stats["intervalAttempts"]
        rate := attempts > 0 ? Format("{:.1f}%", caught / attempts * 100) : "n/a"
        fields := [
            Webhook.Field("Fish caught", caught),
            Webhook.Field("Casts", attempts),
            Webhook.Field("Success rate", rate),
            Webhook.Field("Rod", cfg["RodName"]),
            Webhook.Field("Session total", stats["totalCaught"] " fish / " stats["totalAttempts"] " casts"),
            Webhook.Field("Uptime", Webhook.Uptime(stats["uptimeSec"]))
        ]
        desc := "Summary of the last " cfg["ReportIntervalMin"] " minutes."
        embed := Webhook.Embed("Fischer Report", desc, Webhook.BLUE, fields)
        payload := Map("username", "Fisch Macro", "embeds", [embed])
        return Webhook.Post(Trim(cfg["WebhookUrl"]), Json.Dump(payload, ["inline"]))
    }

    ; Instant failure alert, with optional ping and in-memory screenshot.
    static SendAlert(cfg, reason, stats, solver) {
        if !Webhook.Ready(cfg)
            return false
        fields := [
            Webhook.Field("Fish caught", stats["totalCaught"]),
            Webhook.Field("Casts", stats["totalAttempts"]),
            Webhook.Field("Uptime", Webhook.Uptime(stats["uptimeSec"]))
        ]
        embed := Webhook.Embed("Fisch Macro - Alert", reason, Webhook.RED, fields)
        png := ""
        if cfg["ScreenshotOnFailure"] {
            try png := Webhook.CaptureRoblox(solver)
        }
        if png
            embed["image"] := Map("url", "attachment://screenshot.png")
        payload := Map("username", "Fisch Macro", "embeds", [embed])
        target := Trim(cfg["PingTarget"])
        if cfg["PingOnError"] && target != "" {
            payload["content"] := target " " reason
            payload["allowed_mentions"] := Map("parse", ["everyone", "users"])
        }
        return Webhook.Post(Trim(cfg["WebhookUrl"]), Json.Dump(payload, ["inline"]), "", png)
    }

    ; ---- embed helpers ------------------------------------------------------

    static Embed(title, desc, color, fields := "") {
        e := Map(
            "title", title,
            "description", desc,
            "color", color,
            "timestamp", FormatTime(A_NowUTC, "yyyy-MM-dd'T'HH:mm:ss'Z'"),
            "footer", Map("text", "Fisch Macro")
        )
        if fields
            e["fields"] := fields
        return e
    }

    static Field(name, value, inline := true) {
        return Map("name", name, "value", String(value), "inline", inline ? 1 : 0)
    }

    static Uptime(sec) {
        sec := Integer(sec)
        return Format("{:02}:{:02}:{:02}", sec // 3600, Mod(sec, 3600) // 60, Mod(sec, 60))
    }

    ; ---- async HTTP ---------------------------------------------------------

    ; POSTs jsonText to url. If png (a Buffer) is given, sends multipart with
    ; the image attached as screenshot.png. Returns true if the request was
    ; started. cb(status, text) is called later, when the request completes.
    static Post(url, jsonText, cb := "", png := "") {
        if png {
            boundary := "----FischBoundary" A_TickCount
            body := Webhook.BuildMultipart(boundary, jsonText, png)
            ctype := "multipart/form-data; boundary=" boundary
        } else {
            body := Webhook.Utf8(jsonText)
            ctype := "application/json"
        }
        try {
            req := ComObject("WinHttp.WinHttpRequest.5.1")
            req.SetTimeouts(5000, 5000, 15000, 30000)
            req.Open("POST", url, true)          ; true = asynchronous
            req.SetRequestHeader("Content-Type", ctype)
            req.Send(Webhook.ToSafeArray(body))
        } catch as e {
            if cb
                cb(0, "Request failed: " e.Message)
            return false
        }
        Webhook.Pending.Push({ req: req, cb: cb, t: A_TickCount })
        if !Webhook.Timer {
            Webhook.Timer := Webhook.Reap.Bind(Webhook)
            SetTimer(Webhook.Timer, 1000)
        }
        return true
    }

    ; Collects finished requests and fires their callbacks.
    static Reap() {
        i := Webhook.Pending.Length
        while i >= 1 {
            item := Webhook.Pending[i]
            done := false
            status := 0
            text := ""
            try {
                if item.req.WaitForResponse(0) {
                    done := true
                    status := item.req.Status
                    text := (status >= 200 && status < 300) ? "OK" : SubStr(item.req.ResponseText, 1, 200)
                }
            } catch as e {
                done := true
                text := e.Message
            }
            if !done && A_TickCount - item.t > 60000 {
                done := true
                text := "Timed out"
            }
            if done {
                Webhook.Pending.RemoveAt(i)
                if item.cb {
                    try item.cb(status, text)
                }
            }
            i--
        }
        if Webhook.Pending.Length = 0 && Webhook.Timer {
            SetTimer(Webhook.Timer, 0)
            Webhook.Timer := 0
        }
    }

    ; ---- byte helpers -------------------------------------------------------

    static Utf8(s) {
        n := StrPut(s, "UTF-8")
        b := Buffer(n)
        StrPut(s, b, "UTF-8")
        b.Size := n - 1          ; drop the trailing NUL
        return b
    }

    static Concat(parts*) {
        total := 0
        for p in parts
            total += p.Size
        out := Buffer(total)
        off := 0
        for p in parts {
            if p.Size
                DllCall("RtlMoveMemory", "Ptr", out.Ptr + off, "Ptr", p.Ptr, "UPtr", p.Size)
            off += p.Size
        }
        return out
    }

    static BuildMultipart(boundary, jsonText, png) {
        head := "--" boundary "`r`n"
            . "Content-Disposition: form-data; name=`"payload_json`"`r`n"
            . "Content-Type: application/json`r`n`r`n"
            . jsonText "`r`n"
            . "--" boundary "`r`n"
            . "Content-Disposition: form-data; name=`"files[0]`"; filename=`"screenshot.png`"`r`n"
            . "Content-Type: image/png`r`n`r`n"
        tail := "`r`n--" boundary "--`r`n"
        return Webhook.Concat(Webhook.Utf8(head), png, Webhook.Utf8(tail))
    }

    ; Copies a Buffer into a COM byte array (what WinHttp.Send expects).
    static ToSafeArray(buf) {
        arr := ComObjArray(0x11, buf.Size)       ; VT_UI1
        pData := NumGet(ComObjValue(arr), 8 + A_PtrSize, "Ptr")
        if buf.Size
            DllCall("RtlMoveMemory", "Ptr", pData, "Ptr", buf.Ptr, "UPtr", buf.Size)
        return arr
    }

    ; ---- in-memory screenshot -----------------------------------------------

    static CaptureRoblox(solver) {
        w := solver.GetWindow()
        if w
            return Webhook.Capture(w.x, w.y, w.w, w.h)
        return Webhook.Capture(0, 0, A_ScreenWidth, A_ScreenHeight)
    }

    ; Captures a screen rectangle and returns PNG bytes as a Buffer ("" on
    ; failure). Uses GDI+ and an in-memory IStream: no files are created.
    static Capture(x, y, w, h) {
        if w < 1 || h < 1
            return ""
        si := Buffer(A_PtrSize = 8 ? 24 : 16, 0)
        NumPut("UInt", 1, si)                    ; GdiplusVersion = 1
        token := 0
        if DllCall("gdiplus\GdiplusStartup", "Ptr*", &token, "Ptr", si, "Ptr", 0)
            return ""

        png := ""
        pBitmap := 0
        pStream := 0
        hdcScreen := DllCall("GetDC", "Ptr", 0, "Ptr")
        hdcMem := DllCall("CreateCompatibleDC", "Ptr", hdcScreen, "Ptr")
        hbm := DllCall("CreateCompatibleBitmap", "Ptr", hdcScreen, "Int", w, "Int", h, "Ptr")
        old := DllCall("SelectObject", "Ptr", hdcMem, "Ptr", hbm, "Ptr")
        ; SRCCOPY | CAPTUREBLT
        DllCall("BitBlt", "Ptr", hdcMem, "Int", 0, "Int", 0, "Int", w, "Int", h
            , "Ptr", hdcScreen, "Int", x, "Int", y, "UInt", 0x00CC0020 | 0x40000000)
        DllCall("SelectObject", "Ptr", hdcMem, "Ptr", old)

        try {
            DllCall("gdiplus\GdipCreateBitmapFromHBITMAP", "Ptr", hbm, "Ptr", 0, "Ptr*", &pBitmap)
            if pBitmap {
                clsid := Buffer(16)              ; PNG encoder CLSID
                DllCall("ole32\CLSIDFromString", "WStr", "{557CF406-1A04-11D3-9A73-0000F81EF32E}", "Ptr", clsid)
                DllCall("ole32\CreateStreamOnHGlobal", "Ptr", 0, "Int", true, "Ptr*", &pStream)
                DllCall("gdiplus\GdipSaveImageToStream", "Ptr", pBitmap, "Ptr", pStream, "Ptr", clsid, "Ptr", 0)
                size := 0
                ComCall(5, pStream, "Int64", 0, "UInt", 1, "Int64*", &size)   ; IStream::Seek(0, CUR) = bytes written
                hGlobal := 0
                DllCall("ole32\GetHGlobalFromStream", "Ptr", pStream, "Ptr*", &hGlobal)
                pData := DllCall("GlobalLock", "Ptr", hGlobal, "Ptr")
                if pData && size > 0 {
                    png := Buffer(size)
                    DllCall("RtlMoveMemory", "Ptr", png.Ptr, "Ptr", pData, "UPtr", size)
                }
                DllCall("GlobalUnlock", "Ptr", hGlobal)
            }
        }

        if pStream
            ObjRelease(pStream)
        if pBitmap
            DllCall("gdiplus\GdipDisposeImage", "Ptr", pBitmap)
        DllCall("DeleteObject", "Ptr", hbm)
        DllCall("DeleteDC", "Ptr", hdcMem)
        DllCall("ReleaseDC", "Ptr", 0, "Ptr", hdcScreen)
        DllCall("gdiplus\GdiplusShutdown", "Ptr", token)
        return png
    }
}
