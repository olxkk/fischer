; ============================================================================
; lib/Json.ahk
; Minimal JSON reader/writer for AutoHotkey v2 (no external dependencies).
;
;   Json.Parse(text)            -> Map / Array / String / Number
;                                  (true -> 1, false -> 0, null -> "")
;   Json.Dump(value, boolKeys)  -> pretty-printed JSON string
;
; AutoHotkey has no real boolean type, so Dump() takes a list of key names
; whose numeric values should be written as true / false.
; ============================================================================

class Json {
    static Parse(text) {
        if SubStr(text, 1, 1) = Chr(0xFEFF)
            text := SubStr(text, 2)
        p := JsonParser(text)
        v := p.Value()
        p.Ws()
        if p.i <= p.n
            throw Error("Unexpected data after JSON value at position " p.i)
        return v
    }

    static Dump(v, boolKeys := "", key := "", lvl := 0) {
        if v is Map {
            if v.Count = 0
                return "{}"
            s := "{`n"
            first := true
            for k, val in v {
                if !first
                    s .= ",`n"
                first := false
                s .= Json.Pad(lvl + 1) '"' Json.Esc(k) '": ' Json.Dump(val, boolKeys, k, lvl + 1)
            }
            return s "`n" Json.Pad(lvl) "}"
        }
        if v is Array {
            if v.Length = 0
                return "[]"
            s := "[`n"
            for i, val in v {
                if i > 1
                    s .= ",`n"
                s .= Json.Pad(lvl + 1) Json.Dump(val, boolKeys, "", lvl + 1)
            }
            return s "`n" Json.Pad(lvl) "]"
        }
        if v is Number {
            if boolKeys is Array {
                for b in boolKeys {
                    if b = key
                        return v ? "true" : "false"
                }
            }
            if v is Float {
                s := Format("{:.4f}", v)
                return RTrim(RTrim(s, "0"), ".")
            }
            return v
        }
        return '"' Json.Esc(String(v)) '"'
    }

    static Pad(n) {
        s := ""
        loop n
            s .= "  "
        return s
    }

    static Esc(s) {
        s := StrReplace(s, "\", "\\")
        s := StrReplace(s, '"', '\"')
        s := StrReplace(s, "`n", "\n")
        s := StrReplace(s, "`r", "\r")
        s := StrReplace(s, "`t", "\t")
        return s
    }
}

class JsonParser {
    __New(text) {
        this.t := text
        this.i := 1
        this.n := StrLen(text)
    }

    Ws() {
        while this.i <= this.n && InStr(" `t`r`n", SubStr(this.t, this.i, 1))
            this.i++
    }

    Value() {
        this.Ws()
        c := SubStr(this.t, this.i, 1)
        if c = "{"
            return this.Obj()
        if c = "["
            return this.Arr()
        if c = '"'
            return this.Str()
        if SubStr(this.t, this.i, 4) = "true" {
            this.i += 4
            return 1
        }
        if SubStr(this.t, this.i, 5) = "false" {
            this.i += 5
            return 0
        }
        if SubStr(this.t, this.i, 4) = "null" {
            this.i += 4
            return ""
        }
        return this.Num()
    }

    Obj() {
        m := Map()
        this.i++
        this.Ws()
        if SubStr(this.t, this.i, 1) = "}" {
            this.i++
            return m
        }
        loop {
            this.Ws()
            k := this.Str()
            this.Ws()
            if SubStr(this.t, this.i, 1) != ":"
                throw Error("Expected : at position " this.i)
            this.i++
            m[k] := this.Value()
            this.Ws()
            c := SubStr(this.t, this.i, 1)
            this.i++
            if c = "}"
                break
            if c != ","
                throw Error("Expected , or } at position " (this.i - 1))
        }
        return m
    }

    Arr() {
        a := []
        this.i++
        this.Ws()
        if SubStr(this.t, this.i, 1) = "]" {
            this.i++
            return a
        }
        loop {
            a.Push(this.Value())
            this.Ws()
            c := SubStr(this.t, this.i, 1)
            this.i++
            if c = "]"
                break
            if c != ","
                throw Error("Expected , or ] at position " (this.i - 1))
        }
        return a
    }

    Str() {
        if SubStr(this.t, this.i, 1) != '"'
            throw Error("Expected string at position " this.i)
        this.i++
        out := ""
        loop {
            if this.i > this.n
                throw Error("Unterminated string")
            c := SubStr(this.t, this.i, 1)
            this.i++
            if c = '"'
                break
            if c = "\" {
                e := SubStr(this.t, this.i, 1)
                this.i++
                switch e {
                    case "n": out .= "`n"
                    case "t": out .= "`t"
                    case "r": out .= "`r"
                    case "b": out .= "`b"
                    case "f": out .= "`f"
                    case "u":
                        out .= Chr("0x" SubStr(this.t, this.i, 4))
                        this.i += 4
                    default: out .= e
                }
            } else {
                out .= c
            }
        }
        return out
    }

    Num() {
        if !RegExMatch(this.t, "S)-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?", &m, this.i) || m.Pos != this.i
            throw Error("Invalid JSON value at position " this.i)
        this.i += m.Len
        return m[0] + 0
    }
}
