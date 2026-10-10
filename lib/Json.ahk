; =============================================================================
;  Json.ahk  -  Minimal JSON reader and string escaper (AutoHotkey v2)
;
;  Json.Parse(text)   -> Map (objects, case-insensitive keys), Array, String,
;                        Integer, Float, true/false (as 1/0), null (as "").
;                        Throws an Error with the character position on bad JSON.
;  Json.Escape(text)  -> text escaped for use inside a JSON string. Non-ASCII
;                        characters are written as \uXXXX.
;
;  Writing JSON is done by the caller (see Config.Save) because AutoHotkey has
;  no separate boolean type, so only the caller knows what should be written
;  as true/false.
; =============================================================================
#Requires AutoHotkey v2.0

class Json {
    static Parse(text) {
        return JsonParser(text).Run()
    }

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

class JsonParser {
    static Esc := Map('"', '"', "\", "\", "/", "/", "b", "`b", "f", "`f", "n", "`n", "r", "`r", "t", "`t")

    __New(text) {
        this.T := text
        this.P := 1
        this.N := StrLen(text)
    }

    Run() {
        this.Ws()
        v := this.Value()
        this.Ws()
        if (this.P <= this.N)
            this.Fail("unexpected text after the value")
        return v
    }

    Fail(msg) {
        throw Error("JSON error at character " this.P ": " msg)
    }

    Peek() {
        return SubStr(this.T, this.P, 1)
    }

    ; Skip whitespace.
    Ws() {
        while (this.P <= this.N && InStr(" `t`r`n", SubStr(this.T, this.P, 1)))
            this.P += 1
    }

    Value() {
        c := this.Peek()
        if (c = "{")
            return this.Obj()
        if (c = "[")
            return this.Arr()
        if (c = '"')
            return this.Str()
        if (SubStr(this.T, this.P, 4) = "true") {
            this.P += 4
            return true
        }
        if (SubStr(this.T, this.P, 5) = "false") {
            this.P += 5
            return false
        }
        if (SubStr(this.T, this.P, 4) = "null") {
            this.P += 4
            return ""
        }
        return this.Num()
    }

    Obj() {
        m := Map()
        m.CaseSense := false              ; "castholdtimems" works like "CastHoldTimeMs"
        this.P += 1                       ; {
        this.Ws()
        if (this.Peek() = "}") {
            this.P += 1
            return m
        }
        Loop {
            this.Ws()
            if (this.Peek() != '"')
                this.Fail("expected a quoted key")
            k := this.Str()
            this.Ws()
            if (this.Peek() != ":")
                this.Fail("expected ':'")
            this.P += 1
            this.Ws()
            m[k] := this.Value()
            this.Ws()
            c := this.Peek()
            this.P += 1
            if (c = "}")
                return m
            if (c != ",")
                this.Fail("expected ',' or '}'")
        }
    }

    Arr() {
        a := []
        this.P += 1                       ; [
        this.Ws()
        if (this.Peek() = "]") {
            this.P += 1
            return a
        }
        Loop {
            this.Ws()
            a.Push(this.Value())
            this.Ws()
            c := this.Peek()
            this.P += 1
            if (c = "]")
                return a
            if (c != ",")
                this.Fail("expected ',' or ']'")
        }
    }

    Str() {
        this.P += 1                       ; opening quote
        out := ""
        Loop {
            if (this.P > this.N)
                this.Fail("unterminated string")
            c := SubStr(this.T, this.P, 1)
            this.P += 1
            if (c = '"')
                return out
            if (c != "\") {
                out .= c
                continue
            }
            e := SubStr(this.T, this.P, 1)
            this.P += 1
            if JsonParser.Esc.Has(e) {
                out .= JsonParser.Esc[e]
            } else if (e == "u") {
                hex := SubStr(this.T, this.P, 4)
                if !RegExMatch(hex, "^[0-9A-Fa-f]{4}$")
                    this.Fail("bad \u escape")
                out .= Chr(Integer("0x" hex))
                this.P += 4
            } else {
                this.Fail("bad escape sequence")
            }
        }
    }

    Num() {
        if !RegExMatch(this.T, "A)-?\d+(\.\d+)?([eE][+-]?\d+)?", &m, this.P)
            this.Fail("unexpected character '" this.Peek() "'")
        this.P += m.Len
        s := m[0]
        return (InStr(s, ".") || InStr(s, "e") || InStr(s, "E")) ? Float(s) : Integer(s)
    }
}
