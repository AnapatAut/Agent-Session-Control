"""Check names in tests/asc.sh, tests/dash.sh and tests/dash/page.js (run by tests/lint.sh).

A check has one fixed name: `cond && ok NAME || bad NAME [DETAILS]` (or an if or case with an ok
and a bad), the same NAME both ways, a quoted literal with no value in it ($ or a backquote in
double quotes), used at one place only in its suite, and run once: never in a loop or a function.
`skip NAME WHY` names a check that cannot run here (it may share that check's name). page.js's
`check(NAME, ...)` names are plain string literals, each used once; a suite that relays page.js
(dash.sh) prints them as "page: NAME", so its own names must not clash with those. No suite prints
a check line of its own (`echo "  ok    ..."`): only the helpers do. Names are compared as bash
reads them ('a' and "a" are one name), with spaces at the ends ignored. The suites are read with
tests/bashtree.py: a script it cannot read is a fault.
  python3 -I tests/checknames.py <file>...     prints each fault; exit 1 if any
  python3 -I tests/checknames.py --self-test   each form it must refuse, refused
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
PRINT = re.compile(r'  (ok    |FAIL  |skip  )')
HELPER = re.compile(r'^(ok|bad|skip)\(\)')
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
        if kind not in CHECKS:
            continue
        n = tree.line(cmd.pos)
        word = args[0] if args else ''
        if word in RELAY:
            continue
        if any(a.t in LOOPS or a.t == 'func' for a in cmd.ancestors()):
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
        if kind != 'skip':
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
