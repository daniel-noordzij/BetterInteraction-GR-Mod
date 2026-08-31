#!/usr/bin/env python3
"""lua_check.py -- structural and house-rule check for this repo's Lua.

There is no Lua interpreter on the build machine, so this is the only thing
standing between a typo and a dead game. It does two jobs:

  1. TOKENISE and check block structure. A real Lua 5.4 tokeniser -- long
     strings, long comments, escapes, numbers -- then a stack walk over
     function / if / for / while / do / repeat. A missing `end` is reported
     against the line that OPENED the block, not the end of the file.

  2. ENFORCE the CLAUDE.md rules that are checkable from source:

       K1  ExecuteWithDelay must not appear at all.        (RE-UE4SS #1180)
       K2  at most one ExecuteInGameThread call site.      (the single pump)
       K3  at most one LoopAsync call site.
       A1  a value that came out of FindFirstOf / FindAllOf / StaticFindObject
           is never tested for existence by truthiness or `~= nil`. A wrapper
           around null is TRUTHY, so those tests wave nothing through and the
           next line dereferences it.
       A2  the same trap on a PROPERTY READ. get(o, "Prop") answers with a
           WRAPPER when the class has no such property, so `~= nil` was true for
           a mallet and a roof hatch and the probe read a counter off the wrong
           actor. Test the TYPE.
       L   a file-scope local named ABOVE its own `local` line. Lua resolves it
           as a global -- nil -- with no syntax error and no failure until that
           line runs. Bit twice: the METHODS table calling helpers declared
           below it, and `restoreFailed` read by resolve() but declared after.

Exit code is the contract: 0 pass, 1 fail. Callers gate the deploy on it --

    py tools/lua_check.py <file> && cp ... || echo REFUSED

-- never on a piped grep, which tests grep's exit code instead.

A deliberate exception is a comment on the offending line:

    -- lua_check: allow A1   because <reason>
"""

import re
import sys

# ---------------------------------------------------------------------------
# Tokeniser
# ---------------------------------------------------------------------------

NAME_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
NUM_RE = re.compile(
    r"0[xX][0-9a-fA-F]*(?:\.[0-9a-fA-F]*)?(?:[pP][+-]?[0-9]+)?"
    r"|[0-9]*\.?[0-9]+(?:[eE][+-]?[0-9]+)?"
)

KEYWORDS = {
    "and", "break", "do", "else", "elseif", "end", "false", "for", "function",
    "goto", "if", "in", "local", "nil", "not", "or", "repeat", "return",
    "then", "true", "until", "while",
}

OPERATORS = ("...", "//", "..", "==", "~=", "<=", ">=", "<<", ">>", "::")


class LuaError(Exception):
    def __init__(self, line, message):
        super().__init__(message)
        self.line = line
        self.message = message


def _long_bracket(src, i):
    """If src[i:] opens a long bracket, return (level, body_start), else None."""
    if i >= len(src) or src[i] != "[":
        return None
    j = i + 1
    level = 0
    while j < len(src) and src[j] == "=":
        level += 1
        j += 1
    if j < len(src) and src[j] == "[":
        return level, j + 1
    return None


def _skip_long(src, i, level, line, what):
    close = "]" + "=" * level + "]"
    end = src.find(close, i)
    if end == -1:
        raise LuaError(line, "unterminated long " + what + " (opened here)")
    return end + len(close)


def tokenise(src):
    """Return a list of (kind, text, line). kind: name/keyword/number/string/op."""
    tokens = []
    i = 0
    line = 1
    n = len(src)
    while i < n:
        c = src[i]

        if c == "\n":
            line += 1
            i += 1
            continue
        if c in " \t\r\f\v":
            i += 1
            continue

        # comment -- long or to end of line
        if src.startswith("--", i):
            opened = line
            bracket = _long_bracket(src, i + 2)
            if bracket is not None:
                level, body = bracket
                start = i
                i = _skip_long(src, body, level, opened, "comment")
                line += src.count("\n", start, i)
            else:
                newline = src.find("\n", i)
                i = n if newline == -1 else newline
            continue

        # long string
        bracket = _long_bracket(src, i)
        if bracket is not None:
            level, body = bracket
            opened = line
            start = i
            i = _skip_long(src, body, level, opened, "string")
            line += src.count("\n", start, i)
            tokens.append(("string", "", opened))
            continue

        # quoted string
        if c == "'" or c == '"':
            opened = line
            quote = c
            i += 1
            while True:
                if i >= n:
                    raise LuaError(opened, "unterminated string")
                if src[i] == "\\":
                    if i + 1 < n and src[i + 1] == "\n":
                        line += 1
                    i += 2
                    continue
                if src[i] == "\n":
                    raise LuaError(opened, "unterminated string (newline inside)")
                if src[i] == quote:
                    i += 1
                    break
                i += 1
            tokens.append(("string", "", opened))
            continue

        if c.isdigit() or (c == "." and i + 1 < n and src[i + 1].isdigit()):
            match = NUM_RE.match(src, i)
            tokens.append(("number", match.group(0), line))
            i = match.end()
            continue

        match = NAME_RE.match(src, i)
        if match:
            word = match.group(0)
            tokens.append(("keyword" if word in KEYWORDS else "name", word, line))
            i = match.end()
            continue

        for operator in OPERATORS:
            if src.startswith(operator, i):
                tokens.append(("op", operator, line))
                i += len(operator)
                break
        else:
            tokens.append(("op", c, line))
            i += 1
    return tokens


# ---------------------------------------------------------------------------
# Block structure
# ---------------------------------------------------------------------------

CLOSERS = {")": "(", "]": "[", "}": "{"}
OPENERS = "([{"


def check_structure(tokens):
    problems = []
    blocks = []      # [keyword, line, awaiting_do]
    brackets = []    # (char, line)

    for kind, text, line in tokens:
        if kind == "op":
            if text in OPENERS:
                brackets.append((text, line))
            elif text in CLOSERS:
                if not brackets:
                    problems.append((line, "stray '" + text + "'"))
                elif brackets[-1][0] != CLOSERS[text]:
                    open_char, open_line = brackets.pop()
                    problems.append((line, "'%s' closes '%s' opened on line %d"
                                     % (text, open_char, open_line)))
                else:
                    brackets.pop()
            continue

        if kind != "keyword":
            continue

        if text == "if" or text == "function":
            blocks.append([text, line, False])
        elif text == "for" or text == "while":
            # the block really opens at the matching `do`
            blocks.append([text, line, True])
        elif text == "repeat":
            blocks.append([text, line, False])
        elif text == "do":
            if blocks and blocks[-1][2]:
                blocks[-1][2] = False       # this `do` belongs to a for/while
            else:
                blocks.append(["do", line, False])
        elif text == "else" or text == "elseif":
            if not blocks or blocks[-1][0] != "if":
                problems.append((line, "'" + text + "' with no open 'if'"))
        elif text == "end":
            if not blocks:
                problems.append((line, "stray 'end'"))
            elif blocks[-1][0] == "repeat":
                problems.append((line, "'end' would close the 'repeat' opened on "
                                       "line %d -- a repeat block ends with 'until'"
                                 % blocks[-1][1]))
                blocks.pop()
            else:
                blocks.pop()
        elif text == "until":
            if not blocks or blocks[-1][0] != "repeat":
                problems.append((line, "'until' with no open 'repeat'"))
            else:
                blocks.pop()

    for keyword, line, _awaiting in blocks:
        closer = "until" if keyword == "repeat" else "end"
        problems.append((line, "'%s' opened here is never closed by '%s'"
                         % (keyword, closer)))
    for char, line in brackets:
        problems.append((line, "'" + char + "' opened here is never closed"))
    return problems


# ---------------------------------------------------------------------------
# House rules
# ---------------------------------------------------------------------------

FINDERS = {"FindFirstOf", "FindAllOf", "StaticFindObject"}

# A2: the same null-wrapper trap as A1, but on a PROPERTY READ rather than a
# Find*. `get(object, "SomeProp")` answers with a WRAPPER when the class has no
# such property, and a wrapper is not nil -- so `get(o, "CoinsLeftToPay") ~= nil`
# was true for a mallet and a roof hatch, and the probe picked the wrong object
# to read a counter from. Cost a whole test run. The type is the test.
READERS = {"get"}
ALLOW_RE = re.compile(r"--\s*lua_check:\s*allow\s+([A-Za-z0-9_,\s]+)")


def allowances(src):
    """line number -> set of rule ids deliberately waived on that line."""
    waived = {}
    for number, text in enumerate(src.splitlines(), start=1):
        match = ALLOW_RE.search(text)
        if match:
            waived[number] = set(match.group(1).replace(",", " ").split())
    return waived


def _scheduling_sites(tokens):
    sites = {"ExecuteWithDelay": [], "ExecuteInGameThread": [], "LoopAsync": []}
    for index, (kind, text, line) in enumerate(tokens):
        if kind == "name" and text in sites:
            following = tokens[index + 1] if index + 1 < len(tokens) else None
            if following and following[0] == "op" and following[1] == "(":
                sites[text].append(line)
    return sites


def _enclosing_block_end(tokens, start):
    """Index of the `end`/`until` that closes the block enclosing `start`."""
    depth = 0
    awaiting_do = []
    index = start
    while index < len(tokens):
        kind, text, _line = tokens[index]
        if kind == "keyword":
            if text in ("if", "function", "repeat"):
                depth += 1
                awaiting_do.append(False)
            elif text in ("for", "while"):
                depth += 1
                awaiting_do.append(True)
            elif text == "do":
                if awaiting_do and awaiting_do[-1]:
                    awaiting_do[-1] = False
                else:
                    depth += 1
                    awaiting_do.append(False)
            elif text in ("end", "until"):
                if depth == 0:
                    return index
                depth -= 1
                if awaiting_do:
                    awaiting_do.pop()
        index += 1
    return len(tokens)


def _declaration_of(tokens, name, before):
    """Index of the nearest `local <name>` at or before `before`, else None."""
    index = before
    while index >= 0:
        kind, text, _line = tokens[index]
        if kind == "keyword" and text == "local":
            # `local a, b, c` -- the name list runs to the `=` or the statement end
            scan = index + 1
            while scan < len(tokens):
                kind_s, text_s, _ = tokens[scan]
                if kind_s == "name":
                    if text_s == name:
                        return index
                elif kind_s == "op" and text_s == ",":
                    pass
                else:
                    break
                scan += 1
        index -= 1
    return None


def _taints(tokens):
    """Every `x = <something involving a Find*>`, with the scope x lives in.

    Scoped, because an unscoped version blames a local in one function for an
    identically named local in another -- which it did, in this mod, and
    a checker that cries wolf is a checker people stop gating on.
    """
    found = []
    for index, (kind, text, _line) in enumerate(tokens):
        if kind != "name" or text not in FINDERS:
            continue
        # Walk back to the nearest `=` at bracket depth zero and take the name
        # in front of it. Covers `local x = FindFirstOf(...)` and the
        # `pcall(function() x = FindFirstOf(...) end)` form both.
        back = index - 1
        depth = 0
        while back >= 0:
            kind_b, text_b, line_b = tokens[back]
            if kind_b == "op":
                if text_b in CLOSERS:
                    depth += 1
                elif text_b in OPENERS:
                    if depth == 0:
                        break
                    depth -= 1
                elif text_b == "=" and depth == 0:
                    previous = tokens[back - 1] if back > 0 else None
                    if previous and previous[0] == "name":
                        name = previous[1]
                        declaration = _declaration_of(tokens, name, back - 1)
                        if declaration is None:
                            end = len(tokens)      # global, or a parameter
                        else:
                            end = _enclosing_block_end(tokens, declaration)
                        found.append((name, index, end, line_b))
                    break
            elif kind_b == "keyword" and text_b != "local":
                break
            back -= 1
    return found


def check_rules(tokens, waived):
    problems = []

    def allowed(line, rule):
        return rule in waived.get(line, set())

    sites = _scheduling_sites(tokens)

    for line in sites["ExecuteWithDelay"]:
        if not allowed(line, "K1"):
            problems.append((line, "K1", "ExecuteWithDelay is never safe on this "
                                         "build (RE-UE4SS #1180) -- every delay "
                                         "goes through the one pump"))

    for name, rule in (("ExecuteInGameThread", "K2"), ("LoopAsync", "K3")):
        found = sites[name]
        for position, line in enumerate(found[1:], start=2):
            if not allowed(line, rule):
                problems.append((line, rule,
                                 "%s call site #%d -- there is exactly one pump, "
                                 "and it is on line %d"
                                 % (name, position, found[0])))

    taints = _taints(tokens)
    by_name = {}
    for name, start, end, line in taints:
        by_name.setdefault(name, []).append((start, end, line))

    for index, (kind, text, line) in enumerate(tokens):
        if kind != "name" or text not in by_name:
            continue
        # The nearest tainting assignment whose scope still covers this use.
        blamed = None
        for start, end, taint_line in by_name[text]:
            if start < index <= end and (blamed is None or start > blamed[0]):
                blamed = (start, taint_line)
        if blamed is None:
            continue

        before = tokens[index - 1] if index > 0 else None
        after = tokens[index + 1] if index + 1 < len(tokens) else None

        fault = None
        if after and after[0] == "op" and after[1] in ("~=", "=="):
            following = tokens[index + 2] if index + 2 < len(tokens) else None
            if following and following[0] == "keyword" and following[1] == "nil":
                fault = "compared against nil"
        if before and before[0] == "keyword" and before[1] == "not":
            fault = "tested with 'not'"
        if (before and before[0] == "keyword"
                and before[1] in ("if", "while", "and", "or")
                and after and after[0] == "keyword"
                and after[1] in ("then", "do", "and", "or")):
            fault = "tested for truth"

        if fault and not allowed(line, "A1"):
            problems.append((line, "A1",
                             "'%s' came out of a Find* on line %d and is %s -- a "
                             "wrapper around null is TRUTHY. Test it with "
                             "fullName(x) ~= \"\" instead"
                             % (text, blamed[1], fault)))

    problems.extend(_check_property_reads(tokens, allowed))
    problems.extend(_check_use_before_declaration(tokens, allowed))
    problems.extend(_check_undefined_calls(tokens, allowed))
    problems.extend(_check_undeclared_in_scope(tokens, allowed))
    problems.extend(_check_struct_marshalling(tokens, allowed))
    problems.extend(_check_never_assigned(tokens, allowed))
    return problems


# Everything a mod in this project may legitimately call without declaring it:
# the Lua 5.4 stdlib, plus the UE4SS globals proven on this build.
KNOWN_GLOBALS = {
    # Lua
    "print", "pcall", "xpcall", "type", "tostring", "tonumber", "ipairs", "pairs",
    "next", "select", "error", "assert", "require", "setmetatable", "getmetatable",
    "rawget", "rawset", "rawequal", "rawlen", "unpack", "collectgarbage", "load",
    "loadstring", "dofile", "string", "table", "math", "os", "io", "coroutine",
    "debug", "utf8", "package", "arg", "_G", "_VERSION",
    # UE4SS
    "FindFirstOf", "FindAllOf", "StaticFindObject", "RegisterKeyBind",
    "RegisterHook", "UnregisterHook", "LoopAsync", "ExecuteAsync",
    "ExecuteInGameThread", "ExecuteWithDelay", "NotifyOnNewObject",
    "RegisterConsoleCommandHandler", "RegisterCustomEvent", "Key", "ModifierKey",
    "FText", "FName", "FString", "FVector", "FRotator", "UEHelpers", "CreateInvalidObject",
    "StaticConstructObject", "RegisterCustomProperty", "IterateGameDirectories",
    # Added after rule U flagged nine legitimate call sites in the shipped
    # A checker that cries wolf is one people stop gating on, so
    # every addition here is a real UE4SS global confirmed in working code --
    # never a way to silence an inconvenient finding.
    "LoadAsset", "FindObject", "FindObjects", "ForEachUObject", "ModRef",
    "RegisterLoadMapPreHook", "RegisterLoadMapPostHook",
    "RegisterInitGameStatePreHook", "RegisterInitGameStatePostHook",
    "RegisterBeginPlayPreHook", "RegisterBeginPlayPostHook",
    "RegisterEndPlayPreHook", "RegisterEndPlayPostHook",
    "RegisterProcessConsoleExecPreHook", "RegisterProcessConsoleExecPostHook",
    "RegisterConsoleCommandGlobalHandler", "CreateLogicModsDirectory",
    "GetKismetSystemLibrary", "GetKismetMathLibrary", "GetGameplayStatics",
}


def _check_undefined_calls(tokens, allowed):
    """U -- calling a name that is never declared anywhere and is not a known global.

    Rule L catches a local named ABOVE its own declaration. It cannot catch a
    name that has NO declaration at all -- and that is what shipped in 0.3.2:
    `className(owner)` was carried over from a probe, existed nowhere in the mod,
    resolved as a nil global, raised inside a pcall-wrapped walk, and the whole
    feature silently did nothing for a full test round.
    """
    declared = set()
    for index, (kind, text, _line) in enumerate(tokens):
        if kind == "keyword" and text == "local":
            scan = index + 1
            if (scan < len(tokens) and tokens[scan][0] == "keyword"
                    and tokens[scan][1] == "function"):
                scan += 1
            while scan < len(tokens):
                kind_s, text_s, _ = tokens[scan]
                if kind_s == "name":
                    declared.add(text_s)
                elif not (kind_s == "op" and text_s == ","):
                    break
                scan += 1
        elif kind == "keyword" and text == "function":
            # parameters of `function(a, b)` and `function name(a, b)`
            scan = index + 1
            while scan < len(tokens) and not (tokens[scan][0] == "op"
                                              and tokens[scan][1] == "("):
                if tokens[scan][0] == "name":
                    declared.add(tokens[scan][1])
                scan += 1
            depth = 0
            while scan < len(tokens):
                kind_s, text_s, _ = tokens[scan]
                if kind_s == "op" and text_s == "(":
                    depth += 1
                elif kind_s == "op" and text_s == ")":
                    depth -= 1
                    if depth == 0:
                        break
                elif kind_s == "name":
                    declared.add(text_s)
                scan += 1
        elif kind == "keyword" and text == "for":
            scan = index + 1
            while scan < len(tokens):
                kind_s, text_s, _ = tokens[scan]
                if kind_s == "name":
                    declared.add(text_s)
                elif kind_s == "keyword" and text_s in ("in", "do"):
                    break
                elif not (kind_s == "op" and text_s in (",", "=")):
                    break
                scan += 1

    problems = []
    for index, (kind, text, line) in enumerate(tokens):
        if kind != "name" or text in declared or text in KNOWN_GLOBALS:
            continue
        after = tokens[index + 1] if index + 1 < len(tokens) else None
        if not (after and after[0] == "op" and after[1] == "("):
            continue                      # only flag CALLS, not field reads
        before = tokens[index - 1] if index > 0 else None
        if before and before[0] == "op" and before[1] in (".", ":"):
            continue                      # a method or field call, not a global
        if not allowed(line, "U"):
            problems.append((line, "U",
                             "'%s' is called here but is declared nowhere in this "
                             "file and is not a known global. Lua resolves it as "
                             "nil and the call raises -- which, inside a pcall, "
                             "is silent" % text))
    return problems


# M: a Lua table handed to a game function whose struct parameter carries
# INTERNAL STATE a table cannot supply.
#
# 0.15.0 called controller:GetInputKeyTimeDown({KeyName = "SpaceBar"}) and the
# first conversation of the session killed the process:
#
#   EXCEPTION_ACCESS_VIOLATION reading address 0x0000000000000070
#
# The distinction that matters is NOT "table into struct" -- that is fine and is
# used in production for FVector, FRotator, FMargin and FVector2D, which are
# plain floats and nothing else. An FKey is not: it carries an internal cached
# pointer to its key details. A table supplies the name and leaves that pointer
# as garbage, and the engine dereferences it. pcall cannot catch that.
#
# So this is a list of the functions whose parameter is known to be that kind of
# struct, not a ban on the shape. Add to it when another is found -- FText is
# the obvious suspect, since it holds a shared reference, but nothing here has
# proven it yet and a checker that guesses is a checker people stop trusting.
#
# The memory-safety rule already covered this and was argued past in a comment:
# "the FKey goes IN as a parameter, which is not the by-value RETURN the rule
# forbids". That reasoning was mine and it was wrong.
MARSHAL_BANNED = {
    "GetInputKeyTimeDown", "IsInputKeyDown", "WasInputKeyJustPressed",
    "WasInputKeyJustReleased", "InvertAxisKey",
}


def _check_struct_marshalling(tokens, allowed):
    """M -- building a state-carrying struct out of a Lua table."""
    problems = []
    for index in range(len(tokens) - 3):
        colon, name, paren, brace = tokens[index:index + 4]
        if not (colon[0] == "op" and colon[1] == ":"):
            continue
        if name[0] != "name" or name[1] not in MARSHAL_BANNED:
            continue
        if not (paren[0] == "op" and paren[1] == "("):
            continue
        if not (brace[0] == "op" and brace[1] == "{"):
            continue
        if allowed(name[2], "M"):
            continue
        problems.append((name[2], "M",
                         "'%s' takes an FKey, which carries an internal pointer "
                         "a Lua table cannot supply. Building one from a table "
                         "crashed the process with an access violation, and "
                         "pcall cannot catch that" % name[1]))
    return problems


def _check_undeclared_in_scope(tokens, allowed):
    """S -- a name used inside a function that is declared in no enclosing scope.

    Rule U is file-wide and flat: it asks only "is this name declared ANYWHERE
    in the file", and it only inspects CALLS. Both gaps let 0.9.0 ship a dead
    feature. An edit removed

        local component = byPath(hold.target)

    from the top of holdFast, leaving `component` a nil global. U did not flag
    it, because `component` is a local in several OTHER functions and because
    the surviving use was `numberProp(component, ...)` -- an argument, not a
    call. holdFast then returned on its first line every pass: the ring was
    never drawn and the 200ms fallback quietly finished every hold. A whole test
    round to find, and the symptom -- "the animation is fully gone but it still
    works" -- read as a game problem rather than a missing line.

    This walks a scope STACK. A name is visible if it is a parameter or local of
    this function or of any function enclosing it, a file-scope local, or a
    known global. Blocks inside a function are deliberately NOT scopes of their
    own: that is permissive, and permissive is what keeps a deploy gate
    trustworthy. Block nesting is tracked with the same awaiting_do bookkeeping
    check_structure uses, so `end` only pops a scope when it closes a function.
    """
    problems = []
    blocks = []             # [keyword, awaiting_do, opens_a_scope]
    scopes = [set()]        # scopes[0] is the file
    index, total = 0, len(tokens)

    def visible(name):
        if name in KNOWN_GLOBALS:
            return True
        return any(name in scope for scope in scopes)

    def declare_list(start_at):
        """`local a, b, c` -- names up to the first non-comma."""
        scan = start_at
        while scan < total:
            kind_s, text_s, _ = tokens[scan]
            if kind_s == "name":
                scopes[-1].add(text_s)
            elif not (kind_s == "op" and text_s == ","):
                break
            scan += 1
        return scan

    while index < total:
        kind, text, line = tokens[index]

        if kind == "keyword":
            if text == "local":
                after = tokens[index + 1] if index + 1 < total else None
                if after and after[0] == "keyword" and after[1] == "function":
                    if index + 2 < total and tokens[index + 2][0] == "name":
                        scopes[-1].add(tokens[index + 2][1])
                    index += 1          # land on `function`; it collects params
                    continue
                index = declare_list(index + 1)
                continue

            if text == "function":
                scan, target = index + 1, []
                while scan < total and not (tokens[scan][0] == "op"
                                            and tokens[scan][1] == "("):
                    if tokens[scan][0] == "name":
                        target.append(tokens[scan][1])
                    scan += 1
                # `function f()` declares f; `function a.b()` USES a.
                if len(target) == 1:
                    scopes[-1].add(target[0])
                params, depth = set(), 0
                while scan < total:
                    kind_s, text_s, _ = tokens[scan]
                    if kind_s == "op" and text_s == "(":
                        depth += 1
                    elif kind_s == "op" and text_s == ")":
                        depth -= 1
                        if depth == 0:
                            scan += 1
                            break
                    elif kind_s == "name":
                        params.add(text_s)
                    scan += 1
                blocks.append(["function", False, True])
                scopes.append(params)
                index = scan
                continue

            if text == "for":
                declare_list(index + 1)
                blocks.append([text, True, False])
                index += 1
                continue

            if text == "while":
                blocks.append([text, True, False])
                index += 1
                continue

            if text in ("if", "repeat"):
                blocks.append([text, False, False])
                index += 1
                continue

            if text == "do":
                if blocks and blocks[-1][1]:
                    blocks[-1][1] = False       # belongs to the for/while
                else:
                    blocks.append(["do", False, False])
                index += 1
                continue

            if text in ("end", "until"):
                if blocks:
                    closed = blocks.pop()
                    if closed[2] and len(scopes) > 1:
                        scopes.pop()
                index += 1
                continue

            index += 1
            continue

        if kind == "name":
            before = tokens[index - 1] if index > 0 else None
            after = tokens[index + 1] if index + 1 < total else None
            is_field = (before and before[0] == "op" and before[1] in (".", ":"))
            is_key = (after and after[0] == "op" and after[1] == "="
                      and before and before[0] == "op"
                      and before[1] in ("{", ","))
            if (not is_field and not is_key and not visible(text)
                    and not allowed(line, "S")):
                problems.append((line, "S",
                                 "'%s' is used here but is declared in no "
                                 "enclosing scope and is not a known global. Lua "
                                 "reads it as nil -- inside a pcall that is "
                                 "silent, and the feature just stops working"
                                 % text))
        index += 1

    return problems


def _check_use_before_declaration(tokens, allowed):
    """L -- a FILE-SCOPE local named before its `local` line.

    Lua resolves a name that has no visible local declaration as a GLOBAL, so a
    closure defined above `local x` gets nil rather than x, with no syntax error
    and no runtime error until the line actually runs. This has now bitten twice
    in this project: the METHODS table calling helpers declared below it, and
    `restoreFailed` read by resolve() but declared after it.

    Only file-scope declarations are considered -- a `local` at column 0. Locals
    inside functions are indented, so common names (`ok`, `err`, `value`) that
    are legitimately redeclared per function do not produce noise.
    """
    problems = []

    # Where is each file-scope local declared? Column is not in the token
    # stream, so use the block depth: depth 0 is file scope.
    depth = 0
    awaiting_do = []
    declared = {}
    anywhere = {}   # name -> first declaration index at ANY depth
    for index, (kind, text, line) in enumerate(tokens):
        if kind == "keyword":
            if text in ("if", "function", "repeat"):
                depth += 1
                awaiting_do.append(False)
            elif text in ("for", "while"):
                depth += 1
                awaiting_do.append(True)
            elif text == "do":
                if awaiting_do and awaiting_do[-1]:
                    awaiting_do[-1] = False
                else:
                    depth += 1
                    awaiting_do.append(False)
            elif text in ("end", "until"):
                depth = max(0, depth - 1)
                if awaiting_do:
                    awaiting_do.pop()
            elif text == "local":
                scan = index + 1
                # `local function NAME` and `local a, b, c`
                if (scan < len(tokens) and tokens[scan][0] == "keyword"
                        and tokens[scan][1] == "function"):
                    scan += 1
                while scan < len(tokens):
                    kind_s, text_s, _ = tokens[scan]
                    if kind_s == "name":
                        # Every declaration is recorded, at any depth, so a
                        # function-local can shadow a file-scope name without
                        # being blamed for it -- an earlier version flagged a
                        # function's own `local handle` against an unrelated
                        # file-scope `handle` 5000 lines further down.
                        anywhere.setdefault(text_s, index)
                        if depth == 0:
                            declared.setdefault(text_s, (index, line))
                    elif not (kind_s == "op" and text_s == ","):
                        break
                    scan += 1

    for index, (kind, text, line) in enumerate(tokens):
        if kind != "name" or text not in declared:
            continue
        decl_index, decl_line = declared[text]
        if index >= decl_index:
            continue
        # If ANY declaration of this name -- at any depth -- precedes the use,
        # the use binds to that one and this is not the bug.
        first = anywhere.get(text)
        if first is not None and first < index:
            continue
        # A field access (`t.name`, `t:name`) is not a use of the local.
        before = tokens[index - 1] if index > 0 else None
        if before and before[0] == "op" and before[1] in (".", ":"):
            continue
        # A table key (`name = value` inside `{}`) is not a use either; that is
        # hard to tell apart cheaply, so require the next token not to be `=`.
        after = tokens[index + 1] if index + 1 < len(tokens) else None
        if after and after[0] == "op" and after[1] == "=":
            continue
        if not allowed(line, "L"):
            problems.append((line, "L",
                             "'%s' is used here but its file-scope `local` is on "
                             "line %d. Lua resolves it as a GLOBAL (nil) at this "
                             "point -- move the declaration above this use"
                             % (text, decl_line)))
    return problems



def _check_never_assigned(tokens, allowed):
    """N -- a bare `local x` forward declaration that is never assigned.

    WRITTEN IN BLOOD, 31 Aug 2026. Removing the hold feature took out a span of
    the file that happened to contain `cachedRoot = function(...)` -- the body of
    a helper whose forward `local cachedRoot` sat hundreds of lines earlier and
    survived. Every other rule passed: the name IS declared, so rules L, S and U
    were all satisfied, and the mod would have loaded and then died the first
    time any pass called nil.

    That is the exact gap this closes. A forward declaration is a promise that an
    assignment appears later; nothing checked that the promise was kept.

    Only bare declarations are considered -- `local x` with no `=` and no
    `function`. A name is treated as assigned if it is ever followed by `=` (or
    by a comma, which is a multiple-assignment target list), so the check cannot
    fire on a name that is written anywhere at all.
    """
    problems = []
    declared = {}                       # name -> (index, line)

    index = 0
    while index < len(tokens):
        kind, text, line = tokens[index]
        if kind == "keyword" and text == "local":
            scan, names = index + 1, []
            while scan < len(tokens):
                kind_s, text_s, _ = tokens[scan]
                if kind_s == "keyword" and text_s == "function" and not names:
                    names = None            # `local function f` -- an assignment
                    break
                if kind_s == "name":
                    names.append(text_s)
                elif kind_s == "op" and text_s == ",":
                    pass
                else:
                    break
                scan += 1
            # A bare declaration is one whose name list is NOT followed by `=`.
            if names:
                after = tokens[scan] if scan < len(tokens) else ("", "", line)
                if not (after[0] == "op" and after[1] == "="):
                    for name in names:
                        declared.setdefault(name, (index, line))
        index += 1

    if not declared:
        return problems

    assigned, used = set(), {}
    for position, (kind, text, _line) in enumerate(tokens):
        if kind != "name" or text not in declared:
            continue
        if position == declared[text][0] + 1:
            continue                        # the declaration itself
        used[text] = used.get(text, 0) + 1
        nxt = tokens[position + 1] if position + 1 < len(tokens) else ("", "", 0)
        if nxt[0] == "op" and nxt[1] in ("=", ","):
            assigned.add(text)

    for name, (_index, line) in sorted(declared.items(), key=lambda i: i[1][1]):
        if name in assigned or not used.get(name):
            continue
        if allowed(line, "N"):
            continue
        problems.append((line, "N",
                         "`local %s` is declared and used %d time(s) but never "
                         "assigned -- a forward declaration whose body is gone. "
                         "Calling it is a nil call at runtime, and every other "
                         "rule passes because the NAME exists."
                         % (name, used[name])))
    return problems


def _check_property_reads(tokens, allowed):
    """A2 -- a property read tested for existence instead of for type."""
    problems = []
    for index, (kind, text, line) in enumerate(tokens):
        if kind != "name" or text not in READERS:
            continue
        following = tokens[index + 1] if index + 1 < len(tokens) else None
        if not (following and following[0] == "op" and following[1] == "("):
            continue

        # Walk to the matching close paren, then look at what follows it.
        depth = 0
        scan = index + 1
        while scan < len(tokens):
            kind_s, text_s, _ = tokens[scan]
            if kind_s == "op" and text_s in OPENERS:
                depth += 1
            elif kind_s == "op" and text_s in CLOSERS:
                depth -= 1
                if depth == 0:
                    break
            scan += 1
        after = tokens[scan + 1] if scan + 1 < len(tokens) else None
        before = tokens[index - 1] if index > 0 else None

        fault = None
        if after and after[0] == "op" and after[1] in ("~=", "=="):
            nxt = tokens[scan + 2] if scan + 2 < len(tokens) else None
            if nxt and nxt[0] == "keyword" and nxt[1] == "nil":
                fault = "compared against nil"
        if before and before[0] == "keyword" and before[1] == "not":
            fault = "tested with 'not'"
        if (before and before[0] == "keyword"
                and before[1] in ("if", "while", "and", "or", "return")
                and after and after[0] == "keyword"
                and after[1] in ("then", "do", "and", "or")):
            fault = "tested for truth"

        if fault and not allowed(line, "A2"):
            problems.append((line, "A2",
                             "a property read is %s -- get() answers with a "
                             "WRAPPER for a property the class does not have, "
                             "and a wrapper is not nil. Test the TYPE instead "
                             "(numberProp / type(x) == \"number\")" % fault))
    return problems


# ---------------------------------------------------------------------------

def check(path):
    with open(path, "r", encoding="utf-8", errors="replace") as handle:
        src = handle.read()

    try:
        tokens = tokenise(src)
    except LuaError as error:
        print("%s:%d: FAIL  [structure] %s" % (path, error.line, error.message))
        return False

    findings = [(line, "structure", message)
                for line, message in check_structure(tokens)]
    findings.extend(check_rules(tokens, allowances(src)))
    findings.sort(key=lambda finding: (finding[0], finding[1]))

    for line, rule, message in findings:
        print("%s:%d: FAIL  [%s] %s" % (path, line, rule, message))
    if findings:
        return False

    print("%s: ok  (%d tokens)" % (path, len(tokens)))
    return True


def main(argv):
    paths = argv[1:]
    if not paths:
        print("usage: lua_check.py <file.lua> [...]", file=sys.stderr)
        return 2
    results = [check(path) for path in paths]
    return 0 if all(results) else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
