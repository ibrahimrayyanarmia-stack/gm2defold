"""Recursive-descent GML parser.

    prog = parse(source, filename="scr_x.gml", macros=project_macros)
    prog.body      -> [statement Node]       (see gml/ast.py for node kinds)
    prog.macros    -> {name: Macro}          #macro definitions found in this file
    prog.errors    -> [ParseError]           lex errors + statements that failed to parse

Macros are project-global in GameMaker and are substituted token by token, so a macro body does
not have to be a complete expression (`#macro MOVE new MoveAction`). Collect every file's macros
with `collect_macros()` first and pass the merged dict to `parse()`; macros defined in the file
being parsed are always picked up as well.

Error recovery: a statement that fails to parse becomes an `Unparsed` node holding its source
text, and parsing resumes at the next `;`, line break or closing `}` (at bracket depth 0).

Operator precedence, lowest to highest (GameMaker binds bitwise operators tighter than
comparisons, unlike C):

    ?:   ??   ||   ^^   &&   == != < <= > >= (and `=` used as comparison)
    |    ^    &    << >>   + -   * / div mod %   unary (! - + ~ ++ --)   postfix
"""
import sys

from .lexer import Token, tokenize
from .ast import Node

ASSIGN_OPS = {"=", "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=", "<<=", ">>=", "??="}

BINARY_PREC = {
    "??": 1,
    "||": 2,
    "^^": 3,
    "&&": 4,
    "==": 5, "!=": 5, "<": 5, "<=": 5, ">": 5, ">=": 5, "=": 5,
    "|": 6,
    "^": 7,
    "&": 8,
    "<<": 9, ">>": 9,
    "+": 10, "-": 10,
    "*": 11, "/": 11, "div": 11, "mod": 11, "%": 11,
}
RIGHT_ASSOC = {"??"}
OP_CANON = {"=": "==", "%": "mod"}

ACCESSOR_OF = {"[": None, "[@": "@", "[|": "|", "[?": "?", "[#": "#", "[$": "$"}

# Statements that can't be the value of a `return` with no expression after it.
STMT_KEYWORDS = {"case", "default", "else", "var", "globalvar", "if", "while", "do", "for",
                 "repeat", "switch", "with", "break", "continue", "exit", "return", "try",
                 "throw", "enum", "static", "until", "catch", "finally"}


class ParseError(Exception):
    def __init__(self, msg, line=0, col=0, filename=None):
        self.msg, self.line, self.col, self.filename = msg, line, col, filename
        super().__init__(str(self))

    def __str__(self):
        where = f"{self.filename}:" if self.filename else ""
        return f"{where}{self.line}:{self.col}: {self.msg}"


# ---------------------------------------------------------------------------------------------
# Macros

def _macro_node(tok, errors=None):
    name, config, body, bline, bcol = tok.value
    toks, lex_errors = tokenize(body, bline, bcol)
    if errors is not None:
        errors.extend(ParseError(e.msg, e.line, e.col) for e in lex_errors)
    value = None
    if len(toks) > 1:
        try:
            p = Parser(toks, body, expand=False)
            value = p.expression()
            if p.peek().type != "eof":
                value = None
        except ParseError:
            value = None
    node = Node("Macro", tok.line, tok.col, name=name, config=config, source=body, value=value)
    node.tokens = toks[:-1]
    return node


def collect_macros(src):
    """All `#macro` definitions in a source file, as {name: Macro}."""
    toks, _ = tokenize(src)
    return {t.value[0]: _macro_node(t) for t in toks if t.type == "macro" and t.value[0]}


def _expand(tokens, macros, active=()):
    out = []
    for tok in tokens:
        m = macros.get(tok.value) if tok.type == "ident" else None
        if m is None or tok.value in active:
            out.append(tok)
            continue
        body = []
        for i, bt in enumerate(m.tokens):
            c = Token(bt.type, bt.value, tok.line, tok.col, tok.pos, tok.end,
                      tok.nl if i == 0 else False, bt.raw)
            c.macro = tok.value
            body.append(c)
        out.extend(_expand(body, macros, active + (tok.value,)))
    return out


# ---------------------------------------------------------------------------------------------

class Parser:
    def __init__(self, tokens, src="", filename=None, macros=None, expand=True, errors=None):
        self.src = src
        self.filename = filename
        self.errors = errors if errors is not None else []
        self.macros = {}
        body = []
        for t in tokens:
            if t.type == "macro":
                if t.value[0]:
                    self.macros[t.value[0]] = _macro_node(t, self.errors)
            else:
                body.append(t)
        self.all_macros = dict(macros or {})
        self.all_macros.update(self.macros)
        if expand and self.all_macros:
            body = _expand(body, self.all_macros)
        self.toks = body
        self.i = 0

    # -- token helpers ---------------------------------------------------------------------
    def peek(self, k=0):
        j = self.i + k
        return self.toks[j] if j < len(self.toks) else self.toks[-1]

    def next(self):
        t = self.toks[self.i]
        if t.type != "eof":
            self.i += 1
        return t

    def at_op(self, *ops):
        return self.peek().is_op(*ops)

    def at_kw(self, *kws):
        return self.peek().is_kw(*kws)

    def accept_op(self, op):
        if self.at_op(op):
            return self.next()
        return None

    def expect_op(self, op):
        if not self.at_op(op):
            self.fail(f"expected '{op}'")
        return self.next()

    def expect_ident(self, what="identifier"):
        t = self.peek()
        if t.type != "ident":
            self.fail(f"expected {what}")
        return self.next()

    def fail(self, msg, tok=None):
        tok = tok or self.peek()
        got = "end of file" if tok.type == "eof" else repr(tok.raw if tok.raw else tok.value)
        raise ParseError(f"{msg}, got {got}", tok.line, tok.col, self.filename)

    def node(self, kind, tok, **fields):
        return Node(kind, tok.line, tok.col, **fields)

    # -- program / blocks ------------------------------------------------------------------
    def program(self):
        first = self.peek()
        body = self.statements(top=True)
        prog = Node("Program", first.line, first.col, body=body, macros=self.macros)
        prog.errors = self.errors
        return prog

    def statements(self, top=False):
        """Statements until `}` (not consumed) or end of file."""
        out = []
        while True:
            t = self.peek()
            if t.type == "eof":
                break
            if t.is_op("}") and not top:
                break
            if not top and t.is_kw("case", "default"):
                break
            s = self.statement_recover()
            if s is not None:
                out.append(s)
        return out

    def statement_recover(self):
        start = self.i
        try:
            return self.statement()
        except ParseError as e:
            fail_at = self.i
            self.i = start
            self.sync(fail_at)
            self.errors.append(e)
            if self.i == start:
                self.next()
            a = self.toks[start]
            b = self.toks[max(self.i - 1, start)]
            source = self.src[a.pos:b.end] if self.src else ""
            return Node("Unparsed", a.line, a.col, source=source, message=e.msg)

    def sync(self, fail_at):
        """Skip the broken statement starting at self.i. Stop after a `;` (at depth 0, or at any
        depth once past the failure point unless inside a `for (...)` header), before an
        unmatched `}`, or before a line break at depth 0 once past the failure point."""
        depth = 0
        in_for = self.peek().is_kw("for")
        while True:
            t = self.peek()
            if t.type == "eof":
                return
            if depth == 0 and self.i > fail_at and t.nl:
                return
            if t.type == "op":
                v = t.value
                if v in ("(", "[", "{") or v in ACCESSOR_OF:
                    depth += 1
                elif v in (")", "]", "}"):
                    if depth == 0:
                        if v == "}":
                            return
                    else:
                        depth -= 1
                        if depth == 0 and v == "}" and self.i >= fail_at:
                            self.next()
                            return
                elif v == ";" and (depth == 0 or (self.i >= fail_at and not in_for)):
                    self.next()
                    return
            self.next()

    def block(self):
        t = self.expect_op("{")
        body = self.statements()
        self.expect_op("}")
        return self.node("Block", t, body=body)

    # -- statements ------------------------------------------------------------------------
    def statement(self):
        s = self.statement_inner()
        while self.accept_op(";"):
            pass
        return s

    def statement_inner(self):
        t = self.peek()
        if t.is_op(";"):
            self.next()
            return None
        if t.is_op("{"):
            return self.block()
        if t.type == "kw":
            k = t.value
            if k == "var":
                self.next()
                return self.node("Var", t, decls=self.var_decls())
            if k == "static":
                self.next()
                return self.node("Static", t, decls=self.var_decls())
            if k == "globalvar":
                self.next()
                names = [self.expect_ident().value]
                while self.accept_op(","):
                    names.append(self.expect_ident().value)
                return self.node("GlobalVar", t, names=names)
            if k == "if":
                return self.if_statement()
            if k == "while":
                self.next()
                cond = self.condition()
                return self.node("While", t, cond=cond, body=self.body_statement())
            if k == "repeat":
                self.next()
                cond = self.condition()
                return self.node("Repeat", t, count=cond, body=self.body_statement())
            if k == "with":
                self.next()
                cond = self.condition()
                return self.node("With", t, target=cond, body=self.body_statement())
            if k == "do":
                self.next()
                body = self.body_statement()
                if self.at_kw("until"):
                    self.next()
                    return self.node("DoUntil", t, body=body, cond=self.expression())
                if self.at_kw("while"):
                    self.next()
                    return self.node("DoWhile", t, body=body, cond=self.expression())
                self.fail("expected 'until' after do-body")
            if k == "for":
                return self.for_statement()
            if k == "switch":
                return self.switch_statement()
            if k == "break":
                self.next()
                return self.node("Break", t)
            if k == "continue":
                self.next()
                return self.node("Continue", t)
            if k == "exit":
                self.next()
                return self.node("Exit", t)
            if k == "return":
                self.next()
                n = self.peek()
                if n.type == "eof" or n.is_op(";", "}") or (n.type == "kw" and n.value in STMT_KEYWORDS):
                    return self.node("Return", t, value=None)
                return self.node("Return", t, value=self.expression())
            if k == "throw":
                self.next()
                return self.node("Throw", t, value=self.expression())
            if k == "try":
                return self.try_statement()
            if k == "enum":
                return self.enum_statement()
            if k == "delete":
                self.next()
                return self.node("Delete", t, target=self.expression())
            if k == "function" and self.peek(1).type == "ident":
                f = self.function(decl=True)
                return f
            if k in ("else", "case", "default", "until", "catch", "finally", "constructor"):
                self.fail(f"unexpected '{k}'")
        return self.simple_statement()

    def if_statement(self):
        # `else if` chains are built iteratively: long chains must not exhaust the stack.
        root = parent = None
        while True:
            t = self.next()  # 'if'
            cond = self.condition()
            if self.peek().type == "ident" and self.peek().value == "then":
                self.next()
            node = self.node("If", t, cond=cond, then=self.body_statement(), else_=None)
            if parent is None:
                root = node
            else:
                parent.else_ = node
            parent = node
            if not self.at_kw("else"):
                return root
            self.next()
            if not self.at_kw("if"):
                node.else_ = self.body_statement()
                return root

    def body_statement(self):
        """The body of if/while/for/...: one statement (possibly a block)."""
        t = self.peek()
        if t.type == "eof" or t.is_op("}"):
            self.fail("expected a statement")
        s = self.statement()
        if s is None:   # `if (x) ;`
            s = self.node("Block", t, body=[])
        return s

    def simple_statement(self):
        """Assignment or expression statement (no trailing `;`)."""
        t = self.peek()
        lhs = self.unary()
        if self.peek().type == "op" and self.peek().value in ASSIGN_OPS:
            op = self.next().value
            if lhs.kind not in ("Ident", "Member", "Index"):
                self.fail(f"cannot assign to {lhs.kind}", t)
            value = self.expression()
            return self.node("Assign", t, op=op, target=lhs, value=value)
        e = self.ternary(self.binary(0, lhs))
        return self.node("ExprStmt", t, expr=e)

    def var_decls(self):
        decls = []
        while True:
            n = self.expect_ident("variable name")
            value = None
            if self.accept_op("="):
                value = self.expression()
            decls.append(self.node("VarDecl", n, name=n.value, value=value))
            if not self.accept_op(","):
                return decls

    def condition(self):
        """Condition of if/while/repeat/with/switch. Parens are optional in GML. When the
        condition starts with `(`, a following `(`, `++` or `--` begins the body, not the
        condition: `if (a) (b).x = 1`, `if (a) ++n`."""
        if self.at_op("("):
            t = self.next()
            e = self.expression()
            self.expect_op(")")
            e = self.postfix(e, calls=False)
            return self.ternary(self.binary(0, e))
        return self.expression()

    def for_statement(self):
        t = self.next()
        self.expect_op("(")
        init = cond = step = None
        if not self.at_op(";"):
            if self.at_kw("var"):
                vt = self.next()
                init = self.node("Var", vt, decls=self.var_decls())
            else:
                init = self.simple_statement()
        self.expect_op(";")
        if not self.at_op(";"):
            cond = self.expression()
        self.expect_op(";")
        if not self.at_op(")"):
            step = self.simple_statement()
        self.accept_op(";")     # GameMaker accepts `for (...; i++;)`
        self.expect_op(")")
        return self.node("For", t, init=init, cond=cond, step=step, body=self.body_statement())

    def switch_statement(self):
        t = self.next()
        expr = self.condition()
        self.expect_op("{")
        cases = []
        while not self.at_op("}"):
            c = self.peek()
            if c.type == "eof":
                self.fail("unterminated switch")
            if c.is_kw("case"):
                self.next()
                test = self.expression()
                self.expect_op(":")
            elif c.is_kw("default"):
                self.next()
                test = None
                self.expect_op(":")
            else:
                self.fail("expected 'case' or 'default'")
            cases.append(self.node("Case", c, test=test, body=self.statements()))
        self.expect_op("}")
        return self.node("Switch", t, expr=expr, cases=cases)

    def try_statement(self):
        t = self.next()
        body = self.block()
        catch_var = catch_body = finally_body = None
        if self.at_kw("catch"):
            self.next()
            if self.accept_op("("):
                catch_var = self.expect_ident().value
                self.expect_op(")")
            catch_body = self.block()
        if self.at_kw("finally"):
            self.next()
            finally_body = self.block()
        if catch_body is None and finally_body is None:
            self.fail("expected 'catch' or 'finally' after try block")
        return self.node("Try", t, body=body, catch_var=catch_var, catch_body=catch_body,
                         finally_body=finally_body)

    def enum_statement(self):
        t = self.next()
        name = self.expect_ident("enum name").value
        self.expect_op("{")
        members = []
        while not self.at_op("}"):
            m = self.expect_ident("enum member")
            value = None
            if self.accept_op("="):
                value = self.expression()
            members.append(self.node("EnumMember", m, name=m.value, value=value))
            if not self.accept_op(","):
                break
        self.expect_op("}")
        return self.node("Enum", t, name=name, members=members)

    def function(self, decl):
        t = self.next()  # 'function'
        name = None
        if self.peek().type == "ident":
            name = self.next().value
        self.expect_op("(")
        params = []
        while not self.at_op(")"):
            p = self.expect_ident("parameter name")
            default = None
            if self.accept_op("="):
                default = self.expression()
            params.append(self.node("Param", p, name=p.value, default=default))
            if not self.accept_op(","):
                break
        self.expect_op(")")
        parent = None
        if self.accept_op(":"):
            pt = self.expect_ident("parent constructor")
            args = self.call_args() if self.at_op("(") else []
            parent = self.node("Call", pt, callee=self.node("Ident", pt, name=pt.value), args=args)
        constructor = False
        if self.at_kw("constructor"):
            self.next()
            constructor = True
        body = self.block()
        return self.node("FunctionDecl" if decl else "Function", t, name=name, params=params,
                         parent=parent, constructor=constructor, body=body)

    # -- expressions -----------------------------------------------------------------------
    def expression(self):
        return self.ternary(self.binary(0))

    def ternary(self, cond):
        if not self.at_op("?"):
            return cond
        t = self.next()
        then = self.expression()
        self.expect_op(":")
        else_ = self.expression()
        return Node("Ternary", cond.line, cond.col, cond=cond, then=then, else_=else_)

    def binary(self, min_prec, left=None):
        if left is None:
            left = self.unary()
        while True:
            t = self.peek()
            if t.type != "op":
                return left
            prec = BINARY_PREC.get(t.value)
            if prec is None or prec < min_prec:
                return left
            self.next()
            right = self.binary(prec if t.value in RIGHT_ASSOC else prec + 1)
            left = Node("Binary", left.line, left.col, op=OP_CANON.get(t.value, t.value),
                        left=left, right=right)

    def unary(self):
        t = self.peek()
        if t.type == "op":
            if t.value in ("!", "-", "+", "~"):
                self.next()
                return self.node("Unary", t, op=t.value, operand=self.unary())
            if t.value in ("++", "--"):
                self.next()
                return self.node("Prefix", t, op=t.value, target=self.unary())
        return self.postfix(self.primary())

    def call_args(self):
        self.expect_op("(")
        args = []
        while not self.at_op(")"):
            args.append(self.expression())
            if not self.accept_op(","):
                break
        self.expect_op(")")
        return args

    def postfix(self, e, calls=True):
        while True:
            t = self.peek()
            if t.type != "op":
                return e
            v = t.value
            if v == "(" and calls:
                e = Node("Call", e.line, e.col, callee=e, args=self.call_args())
            elif v == ".":
                self.next()
                n = self.peek()
                if n.type not in ("ident", "kw"):
                    self.fail("expected field name after '.'")
                self.next()
                e = Node("Member", e.line, e.col, object=e, name=n.value)
            elif v in ACCESSOR_OF:
                self.next()
                indices = [self.expression()]
                while self.accept_op(","):
                    indices.append(self.expression())
                self.expect_op("]")
                e = Node("Index", e.line, e.col, object=e, accessor=ACCESSOR_OF[v], indices=indices)
            elif v in ("++", "--") and calls and not t.nl:
                self.next()
                e = Node("Postfix", e.line, e.col, op=v, target=e)
            else:
                return e

    def primary(self):
        t = self.peek()
        ty = t.type
        if ty == "num":
            self.next()
            return self.node("Number", t, value=t.value, raw=t.raw)
        if ty == "str":
            self.next()
            return self.node("String", t, value=t.value)
        if ty == "tmpl":
            self.next()
            return self.template(t)
        if ty == "ident":
            self.next()
            return self.node("Ident", t, name=t.value)
        if ty == "kw":
            v = t.value
            if v in ("true", "false"):
                self.next()
                return self.node("Literal", t, value=(v == "true"))
            if v == "undefined":
                self.next()
                return self.node("Literal", t, value=None)
            if v == "function":
                return self.function(decl=False)
            if v == "new":
                self.next()
                n = self.expect_ident("constructor name")
                callee = self.node("Ident", n, name=n.value)
                while self.at_op("."):
                    self.next()
                    m = self.expect_ident("field name")
                    callee = self.node("Member", n, object=callee, name=m.value)
                args = self.call_args() if self.at_op("(") else []
                return self.node("New", t, callee=callee, args=args)
        if ty == "op":
            v = t.value
            if v == "(":
                self.next()
                e = self.expression()
                self.expect_op(")")
                return e
            if v == "[":
                self.next()
                items = []
                while not self.at_op("]"):
                    items.append(self.expression())
                    if not self.accept_op(","):
                        break
                self.expect_op("]")
                return self.node("Array", t, items=items)
            if v == "{":
                return self.struct_literal()
        self.fail("expected an expression", t)

    def struct_literal(self):
        t = self.next()
        fields = []
        while not self.at_op("}"):
            k = self.peek()
            if k.type in ("ident", "kw"):
                key = k.value
            elif k.type == "str":
                key = k.value
            elif k.type == "num":
                key = k.raw
            else:
                self.fail("expected struct key")
            self.next()
            if self.accept_op(":"):
                value = self.expression()
            elif k.type == "ident":
                value = self.node("Ident", k, name=key)    # shorthand {x} == {x: x}
            else:
                self.fail("expected ':'")
            fields.append((key, value))
            if not self.accept_op(","):
                break
        self.expect_op("}")
        return self.node("Struct", t, fields=fields)

    def template(self, t):
        parts = []
        for part in t.value:
            if part[0] == "s":
                parts.append(Node("String", t.line, t.col, value=part[1]))
                continue
            _, source, line, col = part
            toks, lex_errors = tokenize(source, line, col)
            for e in lex_errors:
                raise ParseError(f"in template string: {e.msg}", e.line, e.col, self.filename)
            sub = Parser(toks, source, self.filename, self.all_macros, errors=self.errors)
            if sub.peek().type == "eof":
                raise ParseError("empty {} in template string", line, col, self.filename)
            e = sub.expression()
            if sub.peek().type != "eof":
                sub.fail("unexpected token in template string expression")
            parts.append(e)
        return self.node("Template", t, parts=parts)


def parse(src, filename=None, macros=None):
    """Parse GML source into a Program node. Never raises on bad input; see Program.errors."""
    toks, lex_errors = tokenize(src)
    errors = [ParseError(e.msg, e.line, e.col, filename) for e in lex_errors]
    p = Parser(toks, src, filename, macros, errors=errors)
    limit = sys.getrecursionlimit()
    sys.setrecursionlimit(max(limit, 20000))
    try:
        return p.program()
    except RecursionError:
        errors.append(ParseError("nesting too deep to parse", 1, 1, filename))
        prog = Node("Program", 1, 1, body=[Node("Unparsed", 1, 1, source=src,
                                                message="nesting too deep to parse")], macros={})
        prog.errors = errors
        return prog
    finally:
        sys.setrecursionlimit(limit)
