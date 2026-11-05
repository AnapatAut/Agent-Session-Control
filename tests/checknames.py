"""Check names in tests/asc.sh, tests/dash.sh and tests/dash/page.js (run by tests/lint.sh).

A check has one fixed name: `cond && ok NAME || bad NAME [DETAILS]`, the same NAME both ways, a
quoted literal with no value in it ($, a backquote), used at one place only in its suite.
`skip NAME WHY` names a check that cannot run here (it may share that check's name). page.js's
`check(NAME, ...)` names are plain string literals, each used once; a suite that relays page.js
(dash.sh) prints them as "page: NAME", so its own names must not clash with those. No suite prints
a check line of its own (`echo "  ok    ..."`): only the helpers do. Names are compared as bash
reads them ('a' and "a" are one name), with spaces at the ends ignored.
  python3 -I tests/checknames.py <file>...     prints each fault; exit 1 if any
  python3 -I tests/checknames.py --self-test   each form it must refuse, refused
"""
import re
import sys

# The page.js relay in dash.sh passes on names fixed in page.js (checked there), and its case
# patterns hold the check line forms.
RELAY = {'"${line#  ok    }"', '"${line#  FAIL  }"'}
RELAY_TEXT = ('"  ok    "*)', '"  FAIL  "*)', '${line#  ok    }', '${line#  FAIL  }')
PAGE = 'tests/dash/page.js'
# A call at a command position: at the start, or after &&, ||, ;, |, then, else, do, time,
# command, {, (, ) (a case arm) or !.
CALL = re.compile(r'(?:^|&&|\|\||[;|{()!]|\bthen|\belse|\bdo|\btime|\bcommand)[ \t]*(ok|bad|skip)(?=[ \t]|$)')
PRINT = re.compile(r'  (ok    |FAIL  |skip  )')
HELPER = re.compile(r'^(ok|bad|skip)\(\)')
HEREDOC = re.compile(r"<<(?!<)-?[ \t]*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1")


def word_end(s, j):
    """End (exclusive) of the bash word starting at s[j]; ValueError if it does not end."""
    n = len(s)
    while j < n and s[j] not in ' \t;&|)<>':
        c = s[j]
        if c == '\\':
            j += 2
        elif c == "'":
            j = s.index("'", j + 1) + 1
        elif c == '"':
            j = dq_end(s, j + 1)
        elif s.startswith('$(', j):
            j = nest_end(s, j + 2, '(', ')')
        elif s.startswith('${', j):
            j = nest_end(s, j + 2, '{', '}')
        elif c == '`':
            j = s.index('`', j + 1) + 1
        else:
            j += 1
    return j


def dq_end(s, j):
    while j < len(s):
        c = s[j]
        if c == '\\':
            j += 2
        elif c == '"':
            return j + 1
        elif s.startswith('$(', j):
            j = nest_end(s, j + 2, '(', ')')
        elif s.startswith('${', j):
            j = nest_end(s, j + 2, '{', '}')
        elif c == '`':
            j = s.index('`', j + 1) + 1
        else:
            j += 1
    raise ValueError('unterminated "')


def nest_end(s, j, op, cl):
    depth = 1
    while j < len(s):
        c = s[j]
        if c == '\\':
            j += 2
            continue
        if c == '"':
            j = dq_end(s, j + 1)
            continue
        if c == "'":
            j = s.index("'", j + 1) + 1
            continue
        if s.startswith('$(', j):
            j = nest_end(s, j + 2, '(', ')')
            continue
        if c == op:
            depth += 1
        elif c == cl:
            depth -= 1
            if depth == 0:
                return j + 1
        j += 1
    raise ValueError('unterminated ' + op)


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


def check_suite(path, text, page=()):
    """page: the names of the page.js checks this suite relays (as "page: NAME")."""
    faults, sites = [], {}
    if PAGE in text:
        sites = {'page: ' + p: f'{PAGE} ({p})' for p in page}
    try:
        lines = logical_lines(text)
    except ValueError as e:
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
        names = {}
        for m in CALL.finditer(line):
            kind, j = m.group(1), m.end()
            while j < len(line) and line[j] in ' \t':
                j += 1
            try:
                word = line[j:word_end(line, j)]
            except ValueError:
                faults.append(f'{path}:{n}: {kind}: its name cannot be read')
                continue
            if word in RELAY:
                continue
            if not word or word[0] not in '"\'':
                faults.append(f'{path}:{n}: {kind} with no quoted name: {word or "(none)"}')
                continue
            if '$' in word or '`' in word:
                faults.append(f'{path}:{n}: {kind}: a value in the name: {word}')
                continue
            name = unquote(word)
            if not name:
                faults.append(f'{path}:{n}: {kind}: the name is not one quoted string: {word}')
                continue
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
]
PASSED = [
    'x && ok "a" || bad "a" "got: $v"\n',
    'x && bad "a" "$(date)" || ok "a"\n',
    'x && ok "a" \\\n\t|| bad "a" "d $v"\n',
    'skip "a" "no $thing here"\nx && ok "a" || bad "a"\n',
    "python3 - <<'EOF'\nok \"$v\"\nEOF\nx && ok 'b' || bad 'b'\n",
    '# ok "$v" in a comment\n',
    'printf "%s" "# <<< x <<<" > f\nx && ok "a" || bad "a"\ny <<<"$v" && ok "b" || bad "b"\n',
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
