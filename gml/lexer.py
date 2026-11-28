"""GML 2.3+ lexer.

tokenize(source) -> (tokens, errors)

Token types:
  num    value = int | float           (decimal, .5, 1_000, $FF, 0xFF, 0b101, #RRGGBB)
  str    value = decoded str           ("..." with escapes, '...', @"..." / @'...' verbatim)
  tmpl   value = [("s", text) | ("e", source, line, col)]   ($"a {b} c")
  ident  value = name
  kw     value = keyword               (see KEYWORDS)
  op     value = canonical operator    (word operators are mapped: and -> &&, or -> ||,
                                        xor -> ^^, not -> !, <> -> !=, := -> =)
  macro  value = (name, config, body_source, body_line, body_col)
  eof

Every token records line/col (1-based), the source span [pos, end) and `nl`, which is true when
a line break separates it from the previous token. The lexer never raises: problems are collected
in the error list and the lexer carries on with a best-effort token.
"""

KEYWORDS = {
    "var", "globalvar", "if", "else", "while", "do", "until", "for", "repeat", "switch", "case",
    "default", "with", "break", "continue", "exit", "return", "try", "catch", "finally", "throw",
    "function", "constructor", "static", "enum", "new", "delete", "true", "false", "undefined",
}

WORD_OPS = {"and": "&&", "or": "||", "xor": "^^", "not": "!", "div": "div", "mod": "mod"}

# Longest first.
OPERATORS = [
    "??=", "<<=", ">>=",
    "[|", "[?", "[#", "[@", "[$",
    "==", "!=", "<>", "<=", ">=", "&&", "||", "^^", "<<", ">>", "++", "--",
    "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=", "??", ":=",
    "+", "-", "*", "/", "%", "=", "<", ">", "!", "~", "&", "|", "^", "?", ":",
    "(", ")", "[", "]", "{", "}", ",", ";", ".",
]
OP_ALIASES = {"<>": "!=", ":=": "="}
ACCESSORS = {"[|", "[?", "[#", "[@", "[$"}

ESCAPES = {"n": "\n", "r": "\r", "t": "\t", "b": "\b", "f": "\f", "v": "\v", "a": "\a",
           "0": "\0", "\\": "\\", '"': '"', "'": "'", "\n": ""}

HEX = "0123456789abcdefABCDEF"


class LexError(Exception):
    def __init__(self, msg, line, col):
        super().__init__(f"{line}:{col}: {msg}")
        self.msg, self.line, self.col = msg, line, col


class Token:
    __slots__ = ("type", "value", "line", "col", "pos", "end", "nl", "raw", "macro")

    def __init__(self, type, value, line, col, pos, end, nl=False, raw=None):
        self.type, self.value = type, value
        self.line, self.col, self.pos, self.end = line, col, pos, end
        self.nl = nl
        self.raw = raw          # source text of the token
        self.macro = None       # name of the macro this token was expanded from, if any

    def is_op(self, *ops):
        return self.type == "op" and self.value in ops

    def is_kw(self, *kws):
        return self.type == "kw" and self.value in kws

    def __repr__(self):
        return f"Token({self.type}, {self.value!r}, {self.line}:{self.col})"


def _ends_expression(tok):
    """Could `tok` be the last token of an operand? Decides whether `[$` is an accessor or a
    `[` followed by a `$FF` literal / template string."""
    if tok is None:
        return False
    if tok.type in ("ident", "num", "str", "tmpl"):
        return True
    if tok.type == "kw":
        return tok.value in ("true", "false", "undefined")
    return tok.type == "op" and tok.value in (")", "]")


class Lexer:
    def __init__(self, src, line=1, col=1):
        self.src = src
        self.i = 0
        self.line, self.col = line, col
        self.tokens = []
        self.errors = []
        self.nl = True          # a line break precedes the next token

    # -- helpers ---------------------------------------------------------------------------
    def peek(self, k=0):
        j = self.i + k
        return self.src[j] if j < len(self.src) else ""

    def advance(self, n=1):
        for _ in range(n):
            if self.i >= len(self.src):
                return
            if self.src[self.i] == "\n":
                self.line += 1
                self.col = 1
            else:
                self.col += 1
            self.i += 1

    def error(self, msg, line=None, col=None):
        self.errors.append(LexError(msg, line or self.line, col or self.col))

    def emit(self, type, value, start, line, col):
        tok = Token(type, value, line, col, start, self.i, self.nl, self.src[start:self.i])
        self.tokens.append(tok)
        self.nl = False
        return tok

    # -- main loop -------------------------------------------------------------------------
    def run(self):
        src = self.src
        while self.i < len(src):
            c = src[self.i]
            if c == "\n":
                self.nl = True
                self.advance()
            elif c in " \t\r\f\v﻿":
                self.advance()
            elif c == "/" and self.peek(1) == "/":
                while self.i < len(src) and src[self.i] != "\n":
                    self.advance()
            elif c == "/" and self.peek(1) == "*":
                line, col = self.line, self.col
                j = src.find("*/", self.i + 2)
                if j < 0:
                    self.error("unterminated /* comment", line, col)
                    j = len(src) - 2
                while self.i < j + 2:
                    if src[self.i] == "\n":
                        self.nl = True
                    self.advance()
            elif c == "#" and self.nl_at_line_start() and not self._is_colour():
                self.directive()
            elif c == "#" and self._is_colour():
                self.colour()
            elif c.isdigit() or (c == "." and self.peek(1).isdigit()):
                self.number()
            elif c == "$" and self.peek(1) in HEX and self.peek(1) != "":
                self.number()
            elif c == "$" and self.peek(1) == '"':
                self.template()
            elif c == "@" and self.peek(1) in "\"'" and self.peek(1) != "":
                self.verbatim()
            elif c in "\"'":
                self.string()
            elif c.isalpha() or c == "_":
                self.word()
            else:
                self.operator()
        self.tokens.append(Token("eof", None, self.line, self.col, self.i, self.i, True, ""))
        return self.tokens, self.errors

    def nl_at_line_start(self):
        j = self.i - 1
        while j >= 0 and self.src[j] in " \t":
            j -= 1
        return j < 0 or self.src[j] == "\n"

    def _is_colour(self):
        s = self.src[self.i + 1:self.i + 7]
        if len(s) == 6 and all(ch in HEX for ch in s):
            nxt = self.peek(7)
            return not (nxt.isalnum() or nxt == "_")
        return False

    # -- token kinds -----------------------------------------------------------------------
    def directive(self):
        start, line, col = self.i, self.line, self.col
        self.advance()
        j = self.i
        while self.i < len(self.src) and (self.src[self.i].isalnum() or self.src[self.i] == "_"):
            self.advance()
        name = self.src[j:self.i]
        if name == "macro":
            while self.peek() and self.peek() in " \t":
                self.advance()
            n0 = self.i
            while self.peek() and (self.peek().isalnum() or self.peek() in "_:"):
                self.advance()
            mname = self.src[n0:self.i]
            config = None
            if ":" in mname:
                config, mname = mname.split(":", 1)
            while self.peek() and self.peek() in " \t":
                self.advance()
            body_line, body_col, b0 = self.line, self.col, self.i
            # body runs to end of line; a trailing backslash continues it
            parts = []
            seg = self.i
            while self.i < len(self.src):
                ch = self.src[self.i]
                if ch == "\n":
                    k = self.i - 1
                    if k >= seg and self.src[k] == "\r":
                        k -= 1
                    if k >= seg and self.src[k] == "\\":
                        parts.append(self.src[seg:k])
                        parts.append("\n")
                        self.advance()
                        seg = self.i
                        continue
                    break
                if ch == "/" and self.peek(1) == "/":
                    break
                self.advance()
            parts.append(self.src[seg:self.i])
            body = "".join(parts).strip()
            if not mname:
                self.error("#macro without a name", line, col)
            self.emit("macro", (mname, config, body, body_line, body_col), start, line, col)
            self.nl = False
        elif name in ("region", "endregion"):
            while self.i < len(self.src) and self.src[self.i] != "\n":
                self.advance()
        else:
            # #define (GM8 script separator) and unknown directives: skip the line, but report it.
            self.error(f"unknown directive #{name}", line, col)
            while self.i < len(self.src) and self.src[self.i] != "\n":
                self.advance()

    def colour(self):
        start, line, col = self.i, self.line, self.col
        s = self.src[self.i + 1:self.i + 7]
        r, g, b = int(s[0:2], 16), int(s[2:4], 16), int(s[4:6], 16)
        self.advance(7)
        self.emit("num", (b << 16) | (g << 8) | r, start, line, col)

    def number(self):
        start, line, col = self.i, self.line, self.col
        src = self.src
        c = src[self.i]

        def run(chars):
            j = self.i
            while self.i < len(src) and (src[self.i] in chars or src[self.i] == "_"):
                self.advance()
            return src[j:self.i].replace("_", "")

        if c == "$":
            self.advance()
            digits = run(HEX)
            value = int(digits, 16)
        elif c == "0" and self.peek(1) in ("x", "X") and self.peek(2) in HEX and self.peek(2):
            self.advance(2)
            value = int(run(HEX), 16)
        elif c == "0" and self.peek(1) in ("b", "B") and self.peek(2) in "01" and self.peek(2):
            self.advance(2)
            value = int(run("01"), 2)
        else:
            text = run("0123456789")
            is_float = False
            if self.peek() == "." and self.peek(1).isdigit():
                self.advance()
                text += "." + run("0123456789")
                is_float = True
            elif self.peek() == "." and not (self.peek(1).isalpha() or self.peek(1) == "_"):
                # `1.` is a valid number; `1.foo` is not (and does not happen in practice)
                self.advance()
                is_float = True
            if self.peek() in ("e", "E") and (self.peek(1).isdigit() or
                                              (self.peek(1) in "+-" and self.peek(2).isdigit())):
                self.advance()
                text += "e"
                if self.peek() in "+-":
                    text += self.peek()
                    self.advance()
                text += run("0123456789")
                is_float = True
            text = text or "0"
            value = float(text) if is_float else int(text)
        if self.peek().isalpha() or self.peek() == "_":
            self.error(f"bad number suffix {self.peek()!r}")
        self.emit("num", value, start, line, col)

    def _escape(self, out):
        """At a backslash inside a normal string: decode one escape into `out`."""
        self.advance()
        e = self.peek()
        if e == "":
            return
        if e in ESCAPES:
            out.append(ESCAPES[e])
            self.advance()
        elif e == "\r" and self.peek(1) == "\n":
            self.advance(2)
        elif e == "x":
            self.advance()
            h = ""
            while len(h) < 2 and self.peek() in HEX and self.peek():
                h += self.peek()
                self.advance()
            out.append(chr(int(h, 16)) if h else "x")
        elif e == "u":
            self.advance()
            h = ""
            if self.peek() == "{":
                self.advance()
                while self.peek() in HEX and self.peek():
                    h += self.peek()
                    self.advance()
                if self.peek() == "}":
                    self.advance()
            else:
                while len(h) < 4 and self.peek() in HEX and self.peek():
                    h += self.peek()
                    self.advance()
            out.append(chr(int(h, 16)) if h else "u")
        else:
            # Unknown escape: GameMaker keeps the character.
            out.append(e)
            self.advance()

    def string(self):
        start, line, col = self.i, self.line, self.col
        q = self.src[self.i]
        self.advance()
        out = []
        while True:
            c = self.peek()
            if c == "" or c == "\n":
                self.error("unterminated string", line, col)
                break
            if c == q:
                self.advance()
                break
            if c == "\\":
                self._escape(out)
            else:
                out.append(c)
                self.advance()
        self.emit("str", "".join(out), start, line, col)

    def verbatim(self):
        start, line, col = self.i, self.line, self.col
        self.advance()
        q = self.src[self.i]
        self.advance()
        j = self.src.find(q, self.i)
        if j < 0:
            self.error("unterminated verbatim string", line, col)
            j = len(self.src)
        text = self.src[self.i:j]
        while self.i < j:
            self.advance()
        self.advance()  # closing quote
        self.emit("str", text.replace("\r\n", "\n"), start, line, col)

    def template(self):
        start, line, col = self.i, self.line, self.col
        self.advance(2)
        parts, buf = [], []
        while True:
            c = self.peek()
            if c == "" or c == "\n":
                self.error("unterminated template string", line, col)
                break
            if c == '"':
                self.advance()
                break
            if c == "\\":
                self._escape(buf)
            elif c == "{":
                if buf:
                    parts.append(("s", "".join(buf)))
                    buf = []
                self.advance()
                eline, ecol, e0 = self.line, self.col, self.i
                depth = 0
                while True:
                    ch = self.peek()
                    if ch == "" or ch == "\n":
                        self.error("unterminated {expression} in template string", eline, ecol)
                        break
                    if ch == "}" and depth == 0:
                        break
                    if ch == "{":
                        depth += 1
                    elif ch == "}":
                        depth -= 1
                    elif ch in "\"'":
                        self.advance()
                        while self.peek() not in (ch, "", "\n"):
                            if self.peek() == "\\":
                                self.advance()
                            self.advance()
                    self.advance()
                parts.append(("e", self.src[e0:self.i], eline, ecol))
                if self.peek() == "}":
                    self.advance()
            else:
                buf.append(c)
                self.advance()
        if buf or not parts:
            parts.append(("s", "".join(buf)))
        self.emit("tmpl", parts, start, line, col)

    def word(self):
        start, line, col = self.i, self.line, self.col
        while self.i < len(self.src) and (self.src[self.i].isalnum() or self.src[self.i] == "_"):
            self.advance()
        w = self.src[start:self.i]
        if w in WORD_OPS:
            self.emit("op", WORD_OPS[w], start, line, col)
        elif w in KEYWORDS:
            self.emit("kw", w, start, line, col)
        else:
            self.emit("ident", w, start, line, col)

    def operator(self):
        start, line, col = self.i, self.line, self.col
        prev = self.tokens[-1] if self.tokens else None
        for op in OPERATORS:
            if self.src.startswith(op, self.i):
                if op in ACCESSORS and not _ends_expression(prev):
                    continue   # `[` starting an array literal, e.g. [$FF, ...] or [#FF0000]
                self.advance(len(op))
                self.emit("op", OP_ALIASES.get(op, op), start, line, col)
                return
        self.error(f"unexpected character {self.src[self.i]!r}")
        self.advance()


def tokenize(src, line=1, col=1):
    """Tokenize GML source. Returns (tokens, errors); tokens always ends with an eof token."""
    return Lexer(src, line, col).run()
