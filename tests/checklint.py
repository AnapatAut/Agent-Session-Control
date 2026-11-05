"""Checks and waits in tests/asc.sh and tests/dash.sh, and page.js's check names (run by
tests/lint.sh).

A check has one fixed name: `cond && ok NAME || bad NAME [DETAILS]` (or an if or case with an ok
and a bad), the same NAME both ways, a quoted literal with no value in it ($ or a backquote in
double quotes), used at one place only in its suite, and run once: never in a loop or a function.
`skip NAME WHY` names a check that cannot run here (it may share that check's name). page.js's
`check(NAME, ...)` names are plain string literals, each used once; a suite that relays page.js
(dash.sh) prints them as "page: NAME", so its own names must not clash with those. No suite prints
a check line of its own (`echo "  ok    ..."`): only the helpers do. Names are compared as bash
reads them ('a' and "a" are one name), with spaces at the ends ignored.

A setup step that did not come is `stop NAME [DETAILS]` (printed "setup: NAME"): its NAME as a
check's, and its exit must end the suite, so never inside ( ), $( ), <( ), a pipeline or an &
job, nor a function that holds one called there.

A wait (poll, poll_gone, and every function that holds a poll loop ending in `return` or calls a
wait with `|| return 1`, found until none is added) must have its status used: its failure must
reach a `||` (through `&&` only) that fails a check, calls stop, or returns 1 in a helper; or it
is the condition of an if with a check. Else a failed wait goes on, and a check after it passes
without testing anything. A poll loop of its own (a loop with sleep and break) is refused: its
status is lost (so is a while or until loop with a sleep: its condition is the wait); a function
that is a wait by its poll loop must end with `return 1`; poll and poll_gone take a whole number
of seconds.

The suites are read with tests/bashtree.py: a script it cannot read is a fault.
  python3 -I tests/checklint.py <file>...     prints each fault; exit 1 if any
  python3 -I tests/checklint.py --self-test   each form it must refuse, refused
"""
import os
import re
import sys

sys.dont_write_bytecode = True  # no __pycache__ left in tests/
sys.path.append(os.path.dirname(os.path.abspath(__file__)))  # after the standard library's
import bashtree  # noqa: E402

# The page.js relay in dash.sh passes on names fixed in page.js (checked there), and its case
# patterns hold the check line forms.
RELAY = {'"${line#  ok    }"', '"${line#  FAIL  }"'}
RELAY_TEXT = ('"  ok    "*)', '"  FAIL  "*)', '${line#  ok    }', '${line#  FAIL  }')
PAGE = 'tests/dash/page.js'
CHECKS = ('ok', 'bad', 'skip')
LOOPS = ('for', 'while', 'until')
WAITS = ('poll', 'poll_gone')  # the other waits are found from these and poll loops
DECLARE = ('local', 'declare', 'typeset', 'export', 'readonly')
APART = ('subshell', 'subst', 'procsub')  # where an exit ends only that process
PRINT = re.compile(r'  (ok    |FAIL  |skip  )')
HELPER = re.compile(r'^(ok|bad|skip|stop)\(\)')
HEREDOC = re.compile(r"<<(?!<)-?[ \t]*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1")


def heredoc(line):
    """The terminator of a heredoc this line starts, or None: a `<<` outside quotes only (not
    `<<<`, not one inside a string such as python -c '... x << y ...')."""
    q, j = None, 0
    while j < len(line):
        c = line[j]
        if q:
            if c == '\\' and q == '"':
                j += 2
                continue
            if c == q:
                q = None
        elif c == '\\':
            j += 2
            continue
        elif c in '\'"':
            q = c
        elif c == '#' and (j == 0 or line[j - 1] in ' \t'):
            return None
        elif line.startswith('<<<', j):
            j += 3
            continue
        elif line.startswith('((', j):  # arithmetic, $((...)) too: 1 << n is a shift
            depth, j = 2, j + 2
            while j < len(line) and depth:
                depth += (line[j] == '(') - (line[j] == ')')
                j += 1
            continue
        elif line.startswith('<<', j):
            m = HEREDOC.match(line, j)
            if m:
                return m.group(2)
        j += 1
    return None


def unquote(word):
    """The name as bash reads a single quoted word, ends stripped; None if it is not one."""
    if len(word) >= 2 and word[0] == word[-1] == "'" and "'" not in word[1:-1]:
        return word[1:-1].strip()
    if len(word) >= 2 and word[0] == word[-1] == '"':
        inner = word[1:-1]
        if re.search(r'(?<!\\)"', inner):
            return None
        return re.sub(r'\\([\\"$`])', r'\1', inner).strip()
    return None


def logical_lines(text):
    """(first line number, joined text) per logical line: heredoc bodies and comments left out,
    a trailing backslash joining the next line. ValueError if a heredoc never ends (a `<<` read
    wrongly as one would hide the rest of the file)."""
    out, cur, start, until = [], [], 0, None
    for n, line in enumerate(text.split('\n'), 1):
        if until is not None:
            if line.strip() == until:
                until = None
            continue
        if not cur:
            start = n
        cur.append(line)
        if line.endswith('\\'):
            continue
        joined = ' '.join(l[:-1] if l.endswith('\\') else l for l in cur)
        cur = []
        if joined.lstrip().startswith('#'):
            continue
        until = heredoc(joined)
        out.append((start, joined))
    if until is not None:
        raise ValueError(f'a heredoc that never ends: {until}')
    return out


def command_name(cmd):
    """The command a simple command runs (past assignments and `command`), and its words."""
    words = [w for w, _ in cmd.words]
    while words and re.match(r'[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?\+?=', words[0]):
        words = words[1:]
    if words[:1] == ['command']:
        words = words[1:]
    return (words[0] if words else None), words[1:]


def unit(cmd):
    """Where a check's ok and bad must meet: the && || list it is in, or the list of the { },
    ( ), if or case that holds it; else its own list."""
    last, n = None, cmd
    while n.up is not None:
        p = n.up
        if p.t == 'andor':
            last = p
            if len(p.kids) >= 2:
                return p
        elif p.t == 'seq' and p.up is not None and p.up.t not in ('brace', 'subshell', 'if', 'case'):
            return last
        n = p
    return last


def check_suite(path, text, page=()):
    """page: the names of the page.js checks this suite relays (as "page: NAME")."""
    faults, sites = [], {}
    if PAGE in text:
        sites = {'page: ' + p: f'{PAGE} ({p})' for p in page}
    try:
        lines = logical_lines(text)
        tree = bashtree.parse(text)
    except (ValueError, bashtree.ParseError) as e:
        return [f'{path}: {e}']
    for n, line in lines:
        if HELPER.match(line.lstrip()):
            if not line.rstrip().endswith('}'):
                faults.append(f'{path}:{n}: a helper definition must be a line of its own')
            continue
        bare = line
        for t in RELAY_TEXT:
            bare = bare.replace(t, '')
        if PRINT.search(bare):
            faults.append(f'{path}:{n}: prints a check line itself; use ok, bad or skip')
    units = {}
    for cmd in tree.walk():
        if cmd.t != 'simple' or not cmd.words:
            continue
        kind, args = command_name(cmd)
        if kind not in CHECKS + ('stop',):
            continue
        n = tree.line(cmd.pos)
        word = args[0] if args else ''
        if word in RELAY:
            continue
        if kind != 'stop' and any(a.t in LOOPS or a.t == 'func' for a in cmd.ancestors()):
            faults.append(f'{path}:{n}: {kind} in a loop or a function: its name would print more than once')
        if not word or word[0] not in '"\'':
            faults.append(f'{path}:{n}: {kind} with no quoted name: {word or "(none)"}')
            continue
        if word[0] == '"' and ('$' in word or '`' in word):
            faults.append(f'{path}:{n}: {kind}: a value in the name: {word}')
            continue
        name = unquote(word)
        if not name:
            faults.append(f'{path}:{n}: {kind}: the name is not one quoted string: {word}')
            continue
        if kind == 'stop':
            if 'setup: ' + name in sites:
                faults.append(f'{path}:{n}: name used before, at line {sites["setup: " + name]}: setup: {name}')
            sites['setup: ' + name] = n
        elif kind != 'skip':
            units.setdefault(id(unit(cmd)), []).append((n, kind, name))
    for calls in sorted(units.values()):
        n = calls[0][0]
        names = {}
        for _, kind, name in calls:
            names.setdefault(kind, []).append(name)
        checks = names.get('ok', []) + names.get('bad', [])
        if len(set(checks)) > 1:
            faults.append(f'{path}:{n}: ok and bad with different names: {" / ".join(sorted(set(checks)))}')
        if names.get('bad') and not names.get('ok'):
            faults.append(f'{path}:{n}: bad with no ok: a check must say ok too ({names["bad"][0]})')
        if names.get('ok') and not names.get('bad'):
            faults.append(f'{path}:{n}: ok with no bad: a check must be able to fail ({names["ok"][0]})')
        for name in set(checks):
            if name in sites:
                faults.append(f'{path}:{n}: name used before, at line {sites[name]}: {name}')
            else:
                sites[name] = n
    return faults + check_waits(path, tree)


def own(node):
    """The nodes in node, not those of a function defined in it."""
    for k in node.kids:
        if k.t != 'func':
            yield k
            yield from own(k)


def poll_loop(loop):
    """'return' if loop is a poll loop with a return in it (a function's wait), 'break' if it is
    one without (its status is lost: a break of its own, not one of a loop inside it, or a while
    or until, whose condition is the wait), else None. A poll loop has a sleep in it; a for loop
    with a sleep and no break or return (a deliberate load) is none."""
    sleep = brk = ret = False

    def visit(n, inner):
        nonlocal sleep, brk, ret
        for k in n.kids:
            if k.t == 'func':
                continue
            if k.t == 'simple' and k.words:
                name, _ = command_name(k)
                sleep |= name == 'sleep'
                brk |= name == 'break' and not inner
                ret |= name == 'return'
            visit(k, inner or k.t in LOOPS)
    visit(loop, False)
    if not sleep:
        return None
    return 'return' if ret else 'break' if brk or loop.t != 'for' else None


def status_use(cmd):
    """What the status of a command (a wait) reaches: ('check' | 'stop' | 'return' | 'other' |
    'true', the and-or list), or (None, why) if nothing does."""
    n = cmd
    while True:
        pl = n.up
        if pl is None or pl.t != 'pipeline':
            return None, 'not a command of its own'
        if pl.kids[-1] is not n:
            return None, 'not the last command of a pipeline'
        andor = pl.up
        k = andor.kids.index(pl)
        if andor.term == '&':
            return None, 'run as an & job'
        sq = andor.up
        if len(andor.kids) == 1 and sq.t == 'seq' and sq.up is not None and sq.up.t == 'subst':
            if len(sq.kids) != 1:
                return None, 'in a $( ) with other commands'
            outer = sq.up.up
            if outer.t != 'simple':
                return None, 'in a $( ) of something other than a command'
            words = [w for w, _ in outer.words]
            if words[:1] and words[0] in DECLARE:
                return None, f'in {words[0]} x=$(...): the status would be {words[0]}\'s'
            name, _ = command_name(outer)
            if name not in (None, '[', 'test'):
                return None, f'its output given to {name}, its status lost'
            if name is None and outer.kids[-1] is not sq.up:
                return None, 'a $( ) after it in the same assignments: the status is the last one\'s'
            n = outer
            continue
        break
    for j in range(k + 1, len(andor.kids)):
        if andor.ops[j - 1] == '||':  # the first one after it: only && before it
            then = andor.kids[j].kids[0]
            name, args = command_name(then) if then.t == 'simple' and then.words else (None, [])
            if name in ('ok', 'bad') and has_check(andor):
                return 'check', andor
            if name == 'stop':
                return 'stop', andor
            if name == 'return' and (not args or args[0].isdigit() and args[0] != '0'):
                return 'return', andor  # a bare return keeps the wait's failure
            if name in ('true', ':'):
                return 'true', andor
            return 'other', andor
    sq = andor.up
    if sq.t == 'seq' and sq.kids[-1] is andor and sq.up is not None and sq.up.t == 'if' \
            and sq.up.kids.index(sq) % 2 == 0 and sq is not sq.up.kids[-1] and has_check(sq.up):
        return 'check', sq.up  # the condition of an if (or elif) whose branches hold a check
    return None, 'its failure reaches no ||'


def has_check(node):
    names = set()
    for k in node.walk():
        if k.t == 'simple' and k.words:
            names.add(command_name(k)[0])
    return 'ok' in names and 'bad' in names


def calls(tree):
    for n in tree.walk():
        if n.t == 'simple' and n.words:
            name, args = command_name(n)
            if name:
                yield n, name, args


def check_waits(path, tree):
    faults = []
    funcs = [f for f in tree.walk() if f.t == 'func']
    waits = set(WAITS)
    while True:  # the wait helpers: each function that holds a poll loop, or returns a wait's failure
        more = {f.name for f in funcs if f.name not in waits and (
            any(k.t in LOOPS and poll_loop(k) == 'return' for k in own(f))
            or any(k.t == 'simple' and k.words and command_name(k)[0] in waits and status_use(k)[0] == 'return'
                   for k in own(f)))}
        if not more:
            break
        waits |= more
    stoppers = {'stop'}
    while True:  # the functions that call stop (whose exit must end the suite too)
        more = {f.name for f in funcs if f.name not in stoppers
                and any(k.t == 'simple' and k.words and command_name(k)[0] in stoppers for k in own(f))}
        if not more:
            break
        stoppers |= more
    for f in funcs:
        if f.name in waits and f.name not in WAITS and any(k.t in LOOPS and poll_loop(k) == 'return' for k in own(f)):
            body = f.kids[0]
            last = body.kids[0].kids[-1] if body.t == 'brace' and body.kids[0].kids else None
            name, args = command_name(last.kids[-1].kids[-1]) if last and last.kids[-1].kids[-1].t == 'simple' \
                and last.kids[-1].kids[-1].words else (None, [])
            if not (name == 'return' and args[:1] and args[0].isdigit() and args[0] != '0'):
                faults.append(f'{path}:{tree.line(f.pos)}: {f.name}: a wait by its poll loop must end with return 1 '
                              '(else its loop running out returns 0)')
    for loop in tree.walk():
        if loop.t not in LOOPS:
            continue
        kind = poll_loop(loop)
        n = tree.line(loop.pos)
        if kind == 'break':
            faults.append(f'{path}:{n}: a poll loop (a sleep, and a break or a while or until): its status is lost; '
                          'use poll or poll_gone')
        elif kind == 'return' and not any(a.t == 'func' for a in loop.ancestors()):
            faults.append(f'{path}:{n}: a poll loop with return outside a function')
    for cmd, name, args in calls(tree):
        n = tree.line(cmd.pos)
        if name in WAITS and not (args[:1] and args[0].isdigit() and len(args) > 1 and args[1] != '!'):
            faults.append(f'{path}:{n}: {name} takes a whole number of seconds, then a command')
        if name in waits and not any(a.t == 'func' and a.name == name for a in cmd.ancestors()):
            use, where = status_use(cmd)
            if use is None:
                faults.append(f'{path}:{n}: {name}: its status is not used ({where}): a check, || stop or || return 1')
            elif use == 'true':
                faults.append(f'{path}:{n}: {name}: || true hides its failure')
            elif use == 'other':
                faults.append(f'{path}:{n}: {name}: its failure must fail a check, stop the suite or return 1')
            elif use == 'return' and not any(a.t == 'func' for a in cmd.ancestors()):
                faults.append(f'{path}:{n}: {name}: || return outside a function')
        if name in stoppers:
            why = None
            for a in [cmd] + list(cmd.ancestors()):
                if a.t in APART:
                    why = 'inside ( ), $( ) or <( )'
                elif a.t == 'pipeline' and len(a.kids) > 1:
                    why = 'in a pipeline'
                elif a.t == 'andor' and a.term == '&':
                    why = 'in an & job'
                if why:
                    faults.append(f'{path}:{n}: {name} {why}: its exit would not end the suite')
                    break
    return faults


def page_names(text):
    return [m.group(1) for m in re.finditer(r'\bcheck\(\s*"((?:[^"\\\n]|\\.)*)"\s*,', text)]


def check_page(path, text):
    faults, seen = [], {}
    for m in re.finditer(r'\bcheck\(\s*', text):
        n = text.count('\n', 0, m.start()) + 1
        rest = text[m.end():]
        q = re.match(r'"((?:[^"\\\n]|\\.)*)"\s*,', rest)
        if not q:
            faults.append(f'{path}:{n}: check(): its name is not a plain "string"')
            continue
        name = q.group(1)
        if name in seen:
            faults.append(f'{path}:{n}: name used before, at line {seen[name]}: {name}')
        seen[name] = n
    return faults




# Each must be refused (suite text, then the start of the fault it must give).
REFUSED = [
    ('x && ok "a $v" || bad "a $v"\n', 'a value in the name'),
    ('x && ok "a $(date)" || bad "a"\n', 'a value in the name'),
    ('x && ok "a `date`" || bad "a"\n', 'a value in the name'),
    ('x && ok "a" || bad "b"\n', 'ok and bad with different names'),
    ('x && ok "a" \\\n\t|| bad "b" "d"\n', 'ok and bad with different names'),
    ('x || bad "a"\n', 'bad with no ok'),
    ('ok "a"\n', 'ok with no bad'),
    ('x && ok "a" || bad "a"\ny && ok "a" || bad "a"\n', 'name used before'),
    ('x && ok $name || bad $name\n', 'ok with no quoted name'),
    ('echo "  ok    a"\n', 'prints a check line itself'),
    ('skip "a $why"\n', 'a value in the name'),
    ('x && { ok "a"; } || bad "b"\n', 'ok and bad with different names'),
    ('if x; then ok "a"; else bad "b"; fi\n', 'ok and bad with different names'),
    ("cat <<'EOF'\nok \"a\"\n", 'a heredoc that never ends'),
    ('case $v in a) ok "a" ;; *) bad "b" ;; esac\n', 'ok and bad with different names'),
    ('case $v in\na) ok "n $v" ;;\nesac\n', 'a value in the name'),
    ('time ok "a"\n', 'ok with no bad'),
    ('x && command ok "a" || bad "b"\n', 'ok and bad with different names'),
    ('x && ok "a" || bad "a"\ny && ok \'a\' || bad \'a\'\n', 'name used before'),
    ('x && ok "a" || bad "a"\ny && ok "a " || bad "a "\n', 'name used before'),
    ("echo '  FAIL  x'\n", 'prints a check line itself'),
    ("printf '  ok    %s\\n' x\n", 'prints a check line itself'),
    ('echo "$p  skip  x"\n', 'prints a check line itself'),
    ('ok() { :; }; x && ok "a" || bad "b"\n', 'a helper definition must be a line of its own'),
    ('echo "x <<EOF"\nx && ok "a" || bad "b"\n', 'ok and bad with different names'),
    ("python3 -c 'print(1 << y)'\nx && ok \"a\" || bad \"b\"\n", 'ok and bad with different names'),
    ('x && ok "a"\'b\' || bad "a"\'b\'\n', 'the name is not one quoted string'),
    ('# relays tests/dash/page.js\nx && ok "page: n" || bad "page: n"\n', 'name used before'),
    ('for k in a b; do x "$k" && ok "a" || bad "a"; done\n', 'in a loop or a function'),
    ('while x; do\n\ty && ok "a" || bad "a"\ndone\n', 'in a loop or a function'),
    ('f() { x && ok "a" || bad "a"; }\nf\nf\n', 'in a loop or a function'),
    ('if x; then\n\tok "a"\nelse\n\tbad "b" "d"\nfi\n', 'ok and bad with different names'),
    ('x && ok "a" || bad "a"\nif x; then\n', 'line'),
    # waits and stop
    ('w() { for i in 1 2; do x && return 0; sleep 1; done; return 1; }\nw\n', 'w: its status is not used'),
    ('w() { for i in 1 2; do x && return 0; sleep 1; done; return 1; }\nv() { w || return 1; }\nv\n', 'v: its status is not used'),
    ('f() { poll 1 x; }\nf || stop "a"\n', 'poll: its status is not used'),
    ('for i in 1 2; do x && break; sleep 1; done\n', 'a poll loop'),
    ('while :; do\n\tx && break\n\tsleep 0.2\ndone\n', 'a poll loop'),
    ('for i in 1 2; do x && return 0; sleep 1; done\n', 'a poll loop with return outside a function'),
    ('poll 5 x\n', 'poll: its status is not used'),
    ('poll 5 x && echo y\n', 'its failure reaches no ||'),
    ('poll 5 x || true\n', '|| true hides its failure'),
    ('poll 5 x || echo no\n', 'must fail a check, stop the suite or return 1'),
    ('poll 5 x || return 1\n', '|| return outside a function'),
    ('poll x y || stop "a"\n', 'takes a whole number of seconds'),
    ('poll 2 ! x || stop "a"\n', 'takes a whole number of seconds'),
    ('poll 2\n', 'takes a whole number of seconds'),
    ('f() { local p=$(poll 1 x) || stop "a"; }\n', "the status would be local's"),
    ('echo "$(poll 1 x)" && ok "a" || bad "a"\n', 'its output given to echo'),
    ('x=$(poll 1 x; y) || stop "a"\n', 'in a $( ) with other commands'),
    ('poll 1 x | cat && ok "a" || bad "a"\n', 'not the last command of a pipeline'),
    ('poll 1 x || stop "a" &\n', 'run as an & job'),
    ('( poll 1 x || stop "a" )\n', 'stop inside ( ), $( ) or <( )'),
    ('x=$(stop "a")\n', 'stop inside ( ), $( ) or <( )'),
    ('poll 1 x || stop "a" | cat\n', 'stop in a pipeline'),
    ('{ poll 1 x || stop "a"; } &\n', 'stop in an & job'),
    ('s() { stop "a"; }\nx=$(s)\n', 's inside ( ), $( ) or <( )'),
    ('poll 1 x || stop "a $v"\n', 'a value in the name'),
    ('poll 1 x || stop "a"\npoll 1 y || stop "a"\n', 'name used before'),
    ('poll 1 x || stop "a"\ny && ok "setup: a" || bad "setup: a"\n', 'name used before'),
    ('poll 1 x && y && z || bad "a"\n', 'bad with no ok'),
    ('poll 1 x || y && ok "a" || bad "a"\n', 'must fail a check, stop the suite or return 1'),
    ('poll 1 x || : && ok "a" || bad "a"\n', '|| true hides its failure'),
    ('p=$(poll 1 a) q=$(echo hi) || stop "a"\n', 'the status is the last one'),
    ('until x; do sleep 0.1; done\n', 'a poll loop'),
    ('i=0; while ! x && [ $i -lt 50 ]; do sleep 0.1; i=$((i+1)); done\n', 'a poll loop'),
    ('w() { for i in 1 2; do x && return 0; sleep 1; done; }\nw || stop "a"\n', 'must end with return 1'),
]
PASSED = [
    'x && ok "a" || bad "a" "got: $v"\n',
    'x && bad "a" "$(date)" || ok "a"\n',
    'x && ok "a" \\\n\t|| bad "a" "d $v"\n',
    'skip "a" "no $thing here"\nx && ok "a" || bad "a"\n',
    "python3 - <<'EOF'\nok \"$v\"\nEOF\nx && ok 'b' || bad 'b'\n",
    '# ok "$v" in a comment\n',
    'printf "%s" "# <<< x <<<" > f\nx && ok "a" || bad "a"\ny <<<"$v" && ok "b" || bad "b"\n',
    'if x; then\n\tok "a"\nelse\n\tbad "a" "d $v"\nfi\n',
    'case $v in a) ok "a" ;; *) bad "a" "d" ;; esac\n',
    'y=$((1 << n)); (( z = 2 << 1 ))\nx && ok "a" || bad "a"\n',
    "x && ok 'cost $5' || bad 'cost $5'\n",
    'x && { ok "a"; } || bad "a"\n',
    'while IFS= read -r line; do case $line in "  ok    "*) ok "${line#  ok    }" ;; esac; done < <(x)\n',
    'w() { for i in 1 2; do x && return 0; sleep 1; done; return 1; }\np=$(w a) || stop "a"\nw b && ok "b" || bad "b"\n',
    'w() { for i in 1 2; do x && return 0; sleep 1; done; return 1; }\nv() { w || return 1; y; }\nv && ok "a" || bad "a"\n',
    '! poll 1 x && ok "a" || bad "a"\n',
    'poll 1 x && bad "a" "d" || ok "a"\n',
    '[ "$(poll 1 x)" = y ] && ok "a" || bad "a"\n',
    'poll 1 x && y \\\n\t&& ok "a" || bad "a" "d"\n',
    'if poll 1 x; then ok "a"; else bad "a"; fi\n',
    'poll_gone 3 [ -S "$s" ] || stop "a"\nx=$(poll 2 y) && ok "b" || bad "b"\n',
    's() { poll 1 x || stop "a"; }\ns\n',
    'for i in 1 2; do x || break; done\nfor i in 1; do sleep 1; done\n',
    "python3 -c 'while True:\n    sleep(1)\n    break'\n",
    'for k in a b; do for j in c; do x && break; done; sleep 1; done\n',
    'f() { poll 1 x || return; }\nf && ok "a" || bad "a"\n',
    'q=$(echo hi) p=$(poll 1 a) || stop "a"\n',
    'while read -r l; do echo "$l"; done < f\n',
]
PAGE_REFUSED = [('check(`a ${x}`, `1`);\n', 'its name is not'), ('check("a", `1`);\ncheck("a", `2`);\n', 'name used before')]


def self_test():
    bad = 0
    for text, fault in REFUSED:
        got = check_suite('t', text, page=['n'])
        if not any(fault in f for f in got):
            print(f'not refused ({fault}): {text!r} gave {got}')
            bad += 1
    for text in PASSED:
        got = check_suite('t', text)
        if got:
            print(f'refused, but fine: {text!r} gave {got}')
            bad += 1
    for text, fault in PAGE_REFUSED:
        if not any(fault in f for f in check_page('t.js', text)):
            print(f'not refused ({fault}): {text!r}')
            bad += 1
    return bad


def main(args):
    if args == ['--self-test']:
        return 1 if self_test() else 0
    faults, texts = [], {}
    for path in args:
        with open(path, encoding='utf-8') as f:
            texts[path] = f.read()
    page = [n for p, t in texts.items() if p.endswith(PAGE) for n in page_names(t)]
    for path, text in texts.items():
        faults += check_page(path, text) if path.endswith('.js') else check_suite(path, text, page)
    for f in faults:
        print(f)
    return 1 if faults else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
