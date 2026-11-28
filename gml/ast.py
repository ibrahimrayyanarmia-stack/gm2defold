"""GML AST.

All nodes are `Node(kind, line, **fields)`. The field order given here is also the order used by
`dump()`. Statement lists are plain Python lists.

Program      body, macros                 macros: {name: Macro}
Block        body
Var          decls                        decls: [VarDecl]
VarDecl      name, value                  value may be None
GlobalVar    names
Static       decls                        [VarDecl]
If           cond, then, else_
While        cond, body
DoUntil      body, cond
DoWhile      body, cond                   `do ... while (c)` (accepted, not standard GML)
For          init, cond, step, body       each part may be None
Repeat       count, body
Switch       expr, cases                  cases: [Case]
Case         test, body                   test None for `default`; body: [stmt], may fall through
With         target, body
Break / Continue / Exit
Return       value                        may be None
Throw        value
Try          body, catch_var, catch_body, finally_body
FunctionDecl name, params, parent, constructor, body
                                          params: [Param]; parent: Call | None (constructor
                                          inheritance `: Parent(args)`)
Param        name, default
Enum         name, members                members: [EnumMember]
EnumMember   name, value                  value may be None
Macro        name, config, source, value  value: parsed expression or None
Delete       target
Assign       op, target, value            op: = += -= *= /= %= &= |= ^= <<= >>= ??=
ExprStmt     expr                         calls, ++/--, new, ...
Unparsed     source, message              statement that failed to parse (error recovery)

Number       value, raw
String       value
Template     parts                        [String | expression]
Literal      value                        True / False / None (undefined)
Ident        name
Unary        op, operand                  ! - + ~
Prefix       op, target                   ++ --
Postfix      op, target                   ++ --
Binary       op, left, right              || ^^ && == != < <= > >= | ^ & << >> + - * / div mod ??
Ternary      cond, then, else_
Call         callee, args
New          callee, args
Member       object, name
Index        object, accessor, indices    accessor: None ([ ] and [@ ]), "|", "?", "#", "$"
Array        items
Struct       fields                       [(key: str, value)]
Function     name, params, parent, constructor, body     (function expression)
"""


class Node:
    __slots__ = ("kind", "line", "col", "_fields", "__dict__")

    def __init__(self, kind, line=0, col=0, **fields):
        self.kind = kind
        self.line = line
        self.col = col
        self._fields = tuple(fields)
        for k, v in fields.items():
            setattr(self, k, v)

    def children(self):
        """Direct child nodes, in field order."""
        for f in self._fields:
            yield from _nodes_in(getattr(self, f))

    def walk(self):
        """This node and all descendants, depth first, pre-order (iterative, so deep trees such
        as long else-if chains are fine)."""
        stack = [self]
        while stack:
            n = stack.pop()
            yield n
            stack.extend(reversed(list(n.children())))

    def __repr__(self):
        return dump(self)

    def __eq__(self, other):
        return (isinstance(other, Node) and self.kind == other.kind and self._fields == other._fields
                and all(getattr(self, f) == getattr(other, f) for f in self._fields))

    __hash__ = object.__hash__


def _nodes_in(v):
    if isinstance(v, Node):
        yield v
    elif isinstance(v, (list, tuple)):
        for x in v:
            yield from _nodes_in(x)
    elif isinstance(v, dict):
        for x in v.values():
            yield from _nodes_in(x)


def _dump(v):
    if isinstance(v, Node):
        if v.kind == "Ident":
            return v.name
        if v.kind == "Number":
            return v.raw if v.raw is not None else repr(v.value)
        if v.kind == "String":
            return _quote(v.value)
        if v.kind == "Literal":
            return {True: "true", False: "false", None: "undefined"}[v.value]
        return "(" + " ".join([v.kind] + [_dump(getattr(v, f)) for f in v._fields]) + ")"
    if isinstance(v, (list, tuple)):
        return "[" + " ".join(_dump(x) for x in v) + "]"
    if isinstance(v, dict):
        return "{" + " ".join(f"{k}={_dump(x)}" for k, x in v.items()) + "}"
    if v is None:
        return "nil"
    if v is True:
        return "#t"
    if v is False:
        return "#f"
    if isinstance(v, str):
        return v
    return repr(v)


def _quote(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n") + '"'


def dump(node):
    """Compact S-expression rendering, used by tests and the CLI.

    Identifiers print bare, strings quoted, numbers as written; other nodes as
    `(Kind field1 field2 ...)` with lists in [ ] and None as nil."""
    return _dump(node)
