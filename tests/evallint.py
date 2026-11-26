"""The strings tests/sandbox.sh hands to eval (run by tests/lint.sh): every chk condition and
diagnostics string, every wait_for condition (at the top level, and inside a chk condition as
an escaped double-quoted string), through bash's own syntax check (bash -n). A string bash
refuses would fail its check every time, for a reason that is not the one tested (on
2026-11-26 a condition whose lines began with "&&" did just that), and hide whether the code
works. Nothing is run: bash -n only reads.

  python3 -I tests/evallint.py tests/sandbox.sh     each refusal: file:line: what, and why
  python3 -I tests/evallint.py --self-test          good and bad samples: exit 0 if it tells them apart
Exit 0 clean, 1 a string refused, 2 usage or a call that cannot be read.
"""
import re
import shlex
import subprocess
import sys

# A wait_for inside an eval'd string: its condition as an escaped double-quoted word.
INNER = re.compile(r'(?<![\w-])wait_for\s+\d+\s+"((?:[^"\\]|\\.)*)"')
# A wait_for of the script itself (anywhere on a line: after a ; too): its condition single-quoted
# (one inside a chk condition is double-quoted, as INNER reads it).
OUTER = re.compile(r"(?<![\w-])wait_for\s+\d+\s+'([^']*)'")


def syntax(s):
    """"" when bash reads s as code, else bash's complaint (first line)."""
    r = subprocess.run(["bash", "-n", "-c", s], capture_output=True, text=True, timeout=10,
                       stdin=subprocess.DEVNULL)
    if r.returncode == 0:
        return ""
    return (r.stderr.strip().splitlines() or [f"bash -n: exit {r.returncode}"])[0]


def unescape(s):
    """A double-quoted word's text as bash gives it: \\", \\\\, \\$ and \\` lose their backslash."""
    return re.sub(r'\\(["\\$`])', r"\1", s)


def calls(text):
    """Each chk call: (line, its words), its lines joined as bash reads
    them (a trailing backslash continues it; a quote left open goes on to the next line)."""
    lines = text.split("\n")
    i = 0
    while i < len(lines):
        if not re.match(r"\s*chk\s", lines[i]):
            i += 1
            continue
        start, buf = i, lines[i]
        while True:
            try:
                words = shlex.split(buf, comments=False, posix=True)
                if buf.endswith("\\") and not buf.endswith("\\\\"):
                    raise ValueError("continued")
                break
            except ValueError:
                i += 1
                if i >= len(lines):
                    raise SystemExit(f"evallint: line {start + 1}: a call that never ends")
                buf = buf[:-1] + lines[i] if buf.endswith("\\") else buf + "\n" + lines[i]
        # a call ends at the first ; & | of its line (shlex keeps them glued to words)
        cut = []
        for w in words:
            if w in (";", "&&", "||", "|", "&") or w.endswith(";"):
                if w.endswith(";") and w != ";":
                    cut.append(w[:-1])
                break
            cut.append(w)
        yield start + 1, cut
        i += 1


def strings(text):
    """(line, what, string) for each eval'd string."""
    for line, w in calls(text):
        if len(w) < 3:
            raise SystemExit(f"evallint: line {line}: chk with no condition")
        name = w[1]
        yield line, f"chk {name!r}: its condition", w[2]
        if len(w) > 3:
            yield line, f"chk {name!r}: its diagnostics", w[3]
        for m in INNER.finditer(w[2]):
            yield line, f"chk {name!r}: a wait_for in its condition", unescape(m.group(1))
    for m in OUTER.finditer(text):
        yield text.count("\n", 0, m.start()) + 1, "wait_for: its condition", m.group(1)


def check(path, text):
    bad = 0
    for line, what, s in strings(text):
        why = syntax(s)
        if why:
            bad += 1
            print(f"{path}:{line}: {what}: bash refuses it: {why}")
    return bad


GOOD = """chk "one line" '[ "$rc" = 0 ] && has "x"' 'echo "rc $rc"'
chk "two lines, && at the end" \\
\t'[ "$rc" = 0 ] && p3=$(cpid) &&
\t ux cat "/proc/$p3/cmdline" | grep -q wrap' \\
\t'echo "rc $rc: $out"'
chk "a wait inside" 'wait_for 15 "ux grep -q \\"^0 \\" /x/$OID" && oux tmux has-session -t "=a"'
wait_for 10 '[ -n "$(spid)" ]'; old=$(spid)
dux tmux kill-server; wait_for 10 '[ -z "$(spid)" ]'
"""
BAD = [
    ("&& at a line's start", """chk "bad" \\\n\t'[ "$rc" = 0 ] && p3=$(cpid)\n\t && grep -q x'"""),
    ("|| at a line's start", """chk "bad" '[ "$rc" = 0 ]\n || true'"""),
    ("an unclosed quote", """chk "bad" 'echo "x'"""),
    ("a bad diagnostics string", """chk "bad" 'true' 'echo $(('"""),
    ("a bad wait_for inside", """chk "bad" 'wait_for 5 "[ -e /x ] &&" && true'"""),
    ("a bad top-level wait_for", """wait_for 5 '[ -e /x ] ||'"""),
    ("a bad wait_for after a ;", """true; wait_for 5 '[ -e /x ]\n && true'"""),
]


def self_test():
    ok = check("good", GOOD) == 0 and len(list(strings(GOOD))) == 8
    for name, text in BAD:
        if check("bad", text) == 0:
            print(f"self-test: not refused: {name}")
            ok = False
    print("evallint self-test:", "ok" if ok else "FAILED")
    return 0 if ok else 1


def main(args):
    if args == ["--self-test"]:
        return self_test()
    if not args:
        print(__doc__.strip().split("\n\n")[1], file=sys.stderr)
        return 2
    bad = 0
    for path in args:
        with open(path, encoding="utf-8") as f:
            bad += check(path, f.read())
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
