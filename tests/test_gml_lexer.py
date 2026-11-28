import os, sys, unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from gml.lexer import tokenize


def toks(src):
    t, errors = tokenize(src)
    assert t[-1].type == "eof"
    return t[:-1], errors


def values(src):
    t, errors = toks(src)
    assert not errors, errors
    return [(x.type, x.value) for x in t]


class Numbers(unittest.TestCase):
    def test_forms(self):
        self.assertEqual(values("12 .5 1.25 1_000 $FF 0x1f 0b101 1e3 3."),
                         [("num", 12), ("num", 0.5), ("num", 1.25), ("num", 1000), ("num", 255),
                          ("num", 31), ("num", 5), ("num", 1000.0), ("num", 3.0)])

    def test_colour_literal_is_bgr(self):
        self.assertEqual(values("c = #FF8000"), [("ident", "c"), ("op", "="), ("num", 0x0080FF)])

    def test_member_after_number_not_float(self):
        # `.` followed by a letter is member access, not part of the number
        self.assertEqual(values("a[0].x")[-2:], [("op", "."), ("ident", "x")])


class Strings(unittest.TestCase):
    def test_escapes(self):
        self.assertEqual(values(r'"a\nb\t\"q\" \\ \x41\u00e9"'), [("str", 'a\nb\t"q" \\ A\u00e9')])

    def test_single_quoted(self):
        self.assertEqual(values(r"'it\'s'"), [("str", "it's")])

    def test_verbatim(self):
        self.assertEqual(values('@"C:\\dir\\n\nline2" @\'x"y\''),
                         [("str", "C:\\dir\\n\nline2"), ("str", 'x"y')])

    def test_template(self):
        (t,), errors = toks('$"hp {hp}/{max_hp(1, {a: 2}.a)} \\{ok"')
        self.assertFalse(errors)
        self.assertEqual(t.type, "tmpl")
        self.assertEqual([p[:2] for p in t.value],
                         [("s", "hp "), ("e", "hp"), ("s", "/"), ("e", "max_hp(1, {a: 2}.a)"),
                          ("s", " {ok")])

    def test_unterminated_string_reports_and_continues(self):
        t, errors = toks('a = "abc\nb = 1')
        self.assertEqual(len(errors), 1)
        self.assertEqual([x.value for x in t][-3:], ["b", "=", 1])


class Operators(unittest.TestCase):
    def test_word_operators(self):
        self.assertEqual([v for _, v in values("a and b or not c xor d div e mod f")],
                         ["a", "&&", "b", "||", "!", "c", "^^", "d", "div", "e", "mod", "f"])

    def test_compound_and_nullish(self):
        self.assertEqual([v for _, v in values("a ??= b ?? c; d <<= 1; e++; f--; g != h <> i")],
                         ["a", "??=", "b", "??", "c", ";", "d", "<<=", 1, ";", "e", "++", ";",
                          "f", "--", ";", "g", "!=", "h", "!=", "i"])

    def test_accessors(self):
        self.assertEqual([v for _, v in values("l[|0] m[?k] g[#1,2] a[@0] s[$k]")],
                         ["l", "[|", 0, "]", "m", "[?", "k", "]", "g", "[#", 1, ",", 2, "]",
                          "a", "[@", 0, "]", "s", "[$", "k", "]"])

    def test_bracket_dollar_in_array_literal_is_hex(self):
        self.assertEqual(values("x = [$FF]"),
                         [("ident", "x"), ("op", "="), ("op", "["), ("num", 255), ("op", "]")])


class Trivia(unittest.TestCase):
    def test_comments_and_newline_flag(self):
        t, _ = toks("a // c\n/* x\ny */ b /* z */ c")
        self.assertEqual([(x.value, x.nl) for x in t], [("a", True), ("b", True), ("c", False)])
        self.assertEqual(t[1].line, 3)

    def test_region(self):
        self.assertEqual(values("#region Stuff here\na\n#endregion"), [("ident", "a")])

    def test_macro(self):
        t, errors = toks("#macro A 10\n#macro cfg:B new Foo \\\n  (1)\nA")
        self.assertFalse(errors)
        self.assertEqual(t[0].type, "macro")
        self.assertEqual(t[0].value[:3], ("A", None, "10"))
        self.assertEqual(t[1].value[:3], ("B", "cfg", "new Foo \n  (1)"))
        self.assertEqual((t[2].type, t[2].value, t[2].line), ("ident", "A", 4))

    def test_keywords(self):
        self.assertEqual(values("var x = undefined"),
                         [("kw", "var"), ("ident", "x"), ("op", "="), ("kw", "undefined")])

    def test_bad_character(self):
        t, errors = toks("a ` b")
        self.assertEqual(len(errors), 1)
        self.assertEqual([x.value for x in t], ["a", "b"])


if __name__ == "__main__":
    unittest.main()
