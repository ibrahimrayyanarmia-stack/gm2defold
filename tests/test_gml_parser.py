import os, sys, unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from gml import parse, collect_macros, dump


def P(src, macros=None):
    prog = parse(src, macros=macros)
    if prog.errors:
        raise AssertionError("; ".join(map(str, prog.errors)))
    return " ".join(dump(s) for s in prog.body)


def E(src):
    """Dump of a single expression."""
    out = P("x = " + src)
    assert out.startswith("(Assign = x ") and out.endswith(")"), out
    return out[len("(Assign = x "):-1]


class Expressions(unittest.TestCase):
    def test_precedence_arith(self):
        self.assertEqual(E("1 + 2 * 3 - 4"), "(Binary - (Binary + 1 (Binary * 2 3)) 4)")
        self.assertEqual(E("a div 2 mod 3 % 4"),
                         "(Binary mod (Binary mod (Binary div a 2) 3) 4)")

    def test_precedence_logic(self):
        self.assertEqual(E("a || b && c"), "(Binary || a (Binary && b c))")
        self.assertEqual(E("a == b && c != d"), "(Binary && (Binary == a b) (Binary != c d))")
        self.assertEqual(E("a and not b or c"), "(Binary || (Binary && a (Unary ! b)) c)")

    def test_bitwise_binds_tighter_than_comparison(self):
        self.assertEqual(E("a & 1 == 0"), "(Binary == (Binary & a 1) 0)")
        self.assertEqual(E("a | b << 2"), "(Binary | a (Binary << b 2))")

    def test_equals_inside_expression_is_comparison(self):
        self.assertEqual(E("a = b"), "(Binary == a b)")
        self.assertEqual(P("if (a = 1) b = 2"),
                         "(If (Binary == a 1) (Assign = b 2) nil)")

    def test_ternary_and_nullish(self):
        self.assertEqual(E("a ? b : c ? d : e"), "(Ternary a b (Ternary c d e))")
        self.assertEqual(E("a ?? b ?? c"), "(Binary ?? a (Binary ?? b c))")
        self.assertEqual(E("a || b ? 1 : 2"), "(Ternary (Binary || a b) 1 2)")

    def test_unary(self):
        self.assertEqual(E("-a * !b"), "(Binary * (Unary - a) (Unary ! b))")
        self.assertEqual(E("~-1"), "(Unary ~ (Unary - 1))")

    def test_postfix_chain(self):
        self.assertEqual(E("a.b[1, 2].c(3)(4)"),
                         "(Call (Call (Member (Index (Member a b) nil [1 2]) c) [3]) [4])")

    def test_accessors(self):
        self.assertEqual(E("l[| 0] + m[? \"k\"] + g[# 1, 2] + a[@ 3] + s[$ k]"),
                         '(Binary + (Binary + (Binary + (Binary + (Index l | [0]) '
                         '(Index m ? ["k"])) (Index g # [1 2])) (Index a @ [3])) (Index s $ [k]))')

    def test_literals(self):
        self.assertEqual(E("[1, [2], ]"), "(Array [1 (Array [2])])")
        self.assertEqual(E('{a: 1, "b c": [], d}'), '(Struct [[a 1] [b c (Array [])] [d d]])')
        self.assertEqual(E("{}"), "(Struct [])")
        self.assertEqual(E("true"), "true")
        self.assertEqual(E("undefined"), "undefined")
        self.assertEqual(E("$10 + 0x10 + .5"), "(Binary + (Binary + $10 0x10) .5)")

    def test_template(self):
        self.assertEqual(E('$"hp: {hp + 1}!"'),
                         '(Template ["hp: " (Binary + hp 1) "!"])')

    def test_new(self):
        self.assertEqual(E("new Vec2(1, 2).len()"),
                         "(Call (Member (New Vec2 [1 2]) len) [])")
        self.assertEqual(E("new ns.Thing()"), "(New (Member ns Thing) [])")

    def test_function_expression(self):
        self.assertEqual(E("function(a, b = 2) { return a + b; }"),
                         "(Function nil [(Param a nil) (Param b 2)] nil #f "
                         "(Block [(Return (Binary + a b))]))")


class Statements(unittest.TestCase):
    def test_assignments(self):
        self.assertEqual(P("a += 1; b.c -= 2\nd[0] ??= 3"),
                         "(Assign += a 1) (Assign -= (Member b c) 2) (Assign ??= (Index d nil [0]) 3)")

    def test_incdec_and_calls(self):
        self.assertEqual(P("i++; --j; f(1)"),
                         "(ExprStmt (Postfix ++ i)) (ExprStmt (Prefix -- j)) (ExprStmt (Call f [1]))")

    def test_optional_semicolons_same_line(self):
        self.assertEqual(P("a = 1 b = 2"), "(Assign = a 1) (Assign = b 2)")

    def test_var_globalvar_static(self):
        self.assertEqual(P("var a = 1, b; globalvar g, h; static s = 0"),
                         "(Var [(VarDecl a 1) (VarDecl b nil)]) (GlobalVar [g h]) "
                         "(Static [(VarDecl s 0)])")

    def test_if_without_parens_and_else(self):
        self.assertEqual(P("if a > 1 then b = 1 else { b = 2 }"),
                         "(If (Binary > a 1) (Assign = b 1) (Block [(Assign = b 2)]))")

    def test_if_body_starting_with_incdec_or_paren(self):
        self.assertEqual(P("if (a) ++n"), "(If a (ExprStmt (Prefix ++ n)) nil)")
        self.assertEqual(P("if (a) (b).c = 1"), "(If a (Assign = (Member b c) 1) nil)")
        self.assertEqual(P("if (a) && (b) c()"),
                         "(If (Binary && a b) (ExprStmt (Call c [])) nil)")

    def test_loops(self):
        self.assertEqual(P("while (i < 3) i++"),
                         "(While (Binary < i 3) (ExprStmt (Postfix ++ i)))")
        self.assertEqual(P("do { i-- } until (i <= 0)"),
                         "(DoUntil (Block [(ExprStmt (Postfix -- i))]) (Binary <= i 0))")
        self.assertEqual(P("repeat (3) f()"), "(Repeat 3 (ExprStmt (Call f [])))")
        self.assertEqual(P("for (var i = 0; i < n; i += 1) { continue; break }"),
                         "(For (Var [(VarDecl i 0)]) (Binary < i n) (Assign += i 1) "
                         "(Block [(Continue) (Break)]))")
        self.assertEqual(P("for (;;) {}"), "(For nil nil nil (Block []))")
        self.assertEqual(P("for (i = 0; i < 2; i++;) {}"),
                         "(For (Assign = i 0) (Binary < i 2) (ExprStmt (Postfix ++ i)) (Block []))")

    def test_switch_fallthrough(self):
        self.assertEqual(P("switch (k) { case 1: case 2: a = 1; break; default: a = 0 }"),
                         "(Switch k [(Case 1 []) (Case 2 [(Assign = a 1) (Break)]) "
                         "(Case nil [(Assign = a 0)])])")

    def test_with_exit_return(self):
        self.assertEqual(P("with (obj_enemy) { if hp <= 0 exit; }"),
                         "(With obj_enemy (Block [(If (Binary <= hp 0) (Exit) nil)]))")
        self.assertEqual(P("function f() { return; }"),
                         "(FunctionDecl f [] nil #f (Block [(Return nil)]))")
        self.assertEqual(P("function f() { return }"),
                         "(FunctionDecl f [] nil #f (Block [(Return nil)]))")

    def test_try_throw(self):
        self.assertEqual(P("try { throw \"x\" } catch (e) { show(e) } finally { done() }"),
                         '(Try (Block [(Throw "x")]) e (Block [(ExprStmt (Call show [e]))]) '
                         '(Block [(ExprStmt (Call done []))]))')

    def test_constructor_inheritance_static(self):
        self.assertEqual(
            P("function B(x) : A(x, 1) constructor { static count = 0; self.x = x }"),
            "(FunctionDecl B [(Param x nil)] (Call A [x 1]) #t "
            "(Block [(Static [(VarDecl count 0)]) (Assign = (Member self x) x)]))")

    def test_enum(self):
        self.assertEqual(P("enum State { idle, run = 5, jump, }"),
                         "(Enum State [(EnumMember idle nil) (EnumMember run 5) (EnumMember jump nil)])")

    def test_delete(self):
        self.assertEqual(P("delete s"), "(Delete s)")

    def test_nested_block_and_empty(self):
        self.assertEqual(P(";; { ; }"), "(Block [])")


class Macros(unittest.TestCase):
    def test_constant_macro(self):
        prog = parse("#macro SPEED 4\nx += SPEED")
        self.assertFalse(prog.errors)
        self.assertEqual(dump(prog.body[0]), "(Assign += x 4)")
        self.assertEqual(dump(prog.macros["SPEED"].value), "4")

    def test_partial_macros_expand_by_token(self):
        macros = collect_macros("#macro SPAWN new Spawn\n#macro SEC * room_speed")
        self.assertIsNone(macros["SEC"].value)     # not an expression on its own
        self.assertEqual(P("a = SPAWN(2 SEC)", macros), "(Assign = a (New Spawn [(Binary * 2 room_speed)]))")

    def test_nested_and_recursive_macros(self):
        self.assertEqual(P("#macro A B + 1\n#macro B A\nx = A"),
                         "(Assign = x (Binary + A 1))")


class Recovery(unittest.TestCase):
    def test_bad_statement_becomes_unparsed(self):
        prog = parse("a = 1;\nb = (2 + ;\nc = 3")
        self.assertEqual(len(prog.errors), 1)
        self.assertEqual(prog.errors[0].line, 2)
        kinds = [s.kind for s in prog.body]
        self.assertEqual(kinds, ["Assign", "Unparsed", "Assign"])
        self.assertEqual(prog.body[1].source, "b = (2 + ;")

    def test_error_inside_block_keeps_rest_of_block(self):
        prog = parse("if (x) {\n  a = ;\n  b = 2\n}\nc = 3")
        self.assertEqual(len(prog.errors), 1)
        self.assertEqual(dump(prog.body[0]),
                         '(If x (Block [(Unparsed a = ; expected an expression, got \';\') '
                         '(Assign = b 2)]) nil)')
        self.assertEqual(dump(prog.body[1]), "(Assign = c 3)")

    def test_multiline_broken_call(self):
        prog = parse("f(1,\n  2 3)\ng()")
        self.assertEqual([s.kind for s in prog.body], ["Unparsed", "ExprStmt"])

    def test_stray_close_brace(self):
        prog = parse("}\na = 1")
        self.assertEqual(len(prog.errors), 1)
        self.assertEqual(prog.body[-1].kind, "Assign")

    def test_long_else_if_chain(self):
        src = "if a == 0 x = 0\n" + "".join(f"else if a == {i} x = {i}\n" for i in range(1, 3000))
        prog = parse(src + "else x = -1")
        self.assertFalse(prog.errors)
        self.assertEqual(sum(1 for n in prog.walk() if n.kind == "If"), 3000)

    def test_absurd_nesting_is_reported_not_raised(self):
        prog = parse("x = " + "(" * 50000 + "1")
        self.assertTrue(prog.errors)

    def test_never_raises(self):
        for src in ["(", "if", "function", "{", "switch (a) { a }", "$\"{", "#macro", "a.", "[|"]:
            prog = parse(src)
            self.assertTrue(prog.errors, src)


class Positions(unittest.TestCase):
    def test_lines(self):
        prog = parse("a = 1\n\nif (b) {\n  c()\n}")
        self.assertEqual([s.line for s in prog.body], [1, 3])
        self.assertEqual(prog.body[1].then.body[0].line, 4)


if __name__ == "__main__":
    unittest.main()
