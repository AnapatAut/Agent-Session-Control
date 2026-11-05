"""The mutant lists (run by tests/lint.sh), and the reader tests/mutate.sh uses for them.

tests/mutants-asc.txt and tests/mutants-dash.txt hold the mutants of tests/asc.sh and
tests/dash.sh, one a line: "file %%% old %%% new %%% check %%% case", exactly five fields. check
is the name of the check that must fail with that change, case the case it is in (both read from
the suite's source by tests/checklint.py). The files are read byte for byte: no blank or comment
line, nothing trimmed (an old text may start with indentation), the last byte a newline (a last
line without one would be lost to a line reader), not empty. tests/privacy.sh keeps its own list
in a heredoc ending at MUTANTS, "file %%% old %%% new" (its runner is its own).
A ⏎ in old or new stands for a newline. Refused: a line not in its form, a file that is not a
plain file of the repo in the folders its runner copies (asc/ or bin/; for privacy.sh tools/ or
.githooks/), an empty old text, a new text the same as the old, an old text not found exactly once
in its file (never "the first one"), a line given twice in a list, a change that no longer parses
(Python by compile() in memory, bash by `bash -n`, JS by `node --check` if node is here: a mutant
that breaks the syntax fails every check, so it would be a catch that tests nothing), and a check
or case that is not the suite's. A file's text is taken as the runners take it, without its
trailing newlines; a mutant writes it back with one.
  python3 -I tests/mutantlint.py <list or suite>...   prints each fault; exit 1 if any
  python3 -I tests/mutantlint.py --table <list>       (tests/mutate.sh) each mutant of a sound
      list, NUL-separated: its line number, case, check, name; on a fault exit 2, faults on stderr
  python3 -I tests/mutantlint.py --apply <list> <line number>   (tests/mutate.sh, in a copy of
      the repo) make that change in this repo's file; exit 3 with why when it cannot (BROKEN)
  python3 -I tests/mutantlint.py --self-test          each form it must refuse, refused
"""
import os
import shutil
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
sys.path.append(os.path.dirname(os.path.abspath(__file__)))  # after the standard library's
import checklint  # noqa: E402

SEP = ' %%% '
NL = '⏎'
ROOTS = {'privacy.sh': ('tools/', '.githooks/')}  # else asc/ and bin/: product code only
SUITES = {'mutants-asc.txt': 'asc.sh', 'mutants-dash.txt': 'dash.sh'}
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def lists(text):
    """(line number, line) of each mutant: the lines of every heredoc that ends at MUTANTS."""
    out, inside = [], False
    for n, line in enumerate(text.split('\n'), 1):
        if inside:
            if line == 'MUTANTS':
                inside = False
            elif line:  # the runners skip an empty line
                out.append((n, line))
        elif line.endswith("<<'MUTANTS'"):
            inside = True
    if inside:
        out.append((0, None))
    return out


def fields(line):
    """file, old, new as privacy.sh's runner splits them (the new text keeps any later separator)."""
    if line.count(SEP) < 2:
        return None
    f, rest = line.split(SEP, 1)
    old, new = rest.split(SEP, 1)
    return f, old.replace(NL, '\n'), new.replace(NL, '\n')


def fields5(line):
    """file, old, new, check, case of a list file's line: exactly five fields, else None."""
    if line.count(SEP) != 4:
        return None
    f, old, new, check, case = line.split(SEP)
    return f, old.replace(NL, '\n'), new.replace(NL, '\n'), check, case


def list_lines(path, data):
    """(line number, line) of a list file's bytes, or the fault that makes it unreadable."""
    if not data:
        return f'{path}: empty'
    if not data.endswith(b'\n'):
        return f'{path}: its last line has no newline'
    try:
        text = data.decode('utf-8')
    except UnicodeDecodeError as x:
        return f'{path}: not UTF-8 ({x.reason} at byte {x.start})'
    # a NUL would shift the runner's table (--table), a CR hide in a terminal: only tab is let in
    bad = [c for c in text if (ord(c) < 32 and c not in '\t\n') or ord(c) == 127]
    if bad:
        n = text[:text.index(bad[0])].count('\n') + 1
        return f'{path}:{n}: a control character ({bad[0]!r}); only tab is allowed'
    return list(enumerate(text[:-1].split('\n'), 1))


def name(line):
    """The mutant's check name, as the runner prints it: its file, old and new as written."""
    p = line.split(SEP)
    return f'mutant: {p[0]}: {p[1]} => {p[2]}'


def kind(path, body):
    if path.endswith('.py'):
        return 'python'
    if path.endswith('.js'):
        return 'js'
    if path.endswith('.sh') or body.startswith(('#!/usr/bin/env bash\n', '#!/bin/bash\n')):
        return 'bash'
    return None


def parses(path, body):
    """'' if body parses as path's kind (or the kind has no check here), else why not."""
    k = kind(path, body)
    if k == 'python':
        try:
            compile(body, path, 'exec')
        except SyntaxError as x:
            return f'Python: {x.msg} (line {x.lineno})'
        return ''
    tool = {'bash': ['bash', '-n'], 'js': ['node', '--check', '-']}.get(k)
    if not tool or not shutil.which(tool[0]):
        return ''
    r = subprocess.run(tool, input=body, capture_output=True, text=True, timeout=30)
    return '' if r.returncode == 0 else f'{k}: ' + (r.stderr.strip().splitlines() or ['does not parse'])[0]


def change(f, old, new, read, roots):
    """(the file's text with the change, '') or (None, why not)."""
    body = None if f.startswith('/') or '..' in f.split('/') or not f.startswith(roots) else read(f)
    if body is None:
        return None, f'{f} is not a plain file of the repo under {" or ".join(roots)}'
    body = body.rstrip('\n')
    if not old:
        return None, 'an empty old text'
    if old == new:
        return None, 'the new text is the old one'
    if body.count(old) != 1:
        return None, f'the old text is in {f} {body.count(old)} times, not once'
    why = parses(f, body + '\n')
    if why:
        return None, f'{f} does not parse even unchanged: {why}'
    out = body.replace(old, new) + '\n'
    why = parses(f, out)
    if why:
        return None, f'{f} no longer parses with it: {why}'
    return out, ''


def check_list(path, text, read, roots=('',)):
    """Faults of the heredoc lists in suite text (privacy.sh); read(file) is the file's text, or
    None."""
    faults, had = [], {}
    for n, line in lists(text):
        where = f'{path}:{n}'
        if line is None:
            faults.append(f"{path}: a heredoc <<'MUTANTS' with no MUTANTS line to end it")
            continue
        if line in had:
            faults.append(f'{where}: the same mutant as line {had[line]}')
            continue
        had[line] = n
        got = fields(line)
        if not got:
            faults.append(f'{where}: not "file %%% old %%% new"')
            continue
        _, why = change(*got, read, roots)
        if why:
            faults.append(f'{where}: {why}')
    return faults


def check_file(path, data, read, owners, only=None):
    """(faults, mutants) of a list file's bytes: mutants as (line number, line, file, old, new,
    check, case). owners: each check name of its suite and the case it is in. only: a line
    number, the one line looked at (the form of the whole file is checked all the same)."""
    got = list_lines(path, data)
    if isinstance(got, str):
        return [got], []
    faults, had, out = [], {}, []
    cases = set(owners.values())
    for n, line in got:
        if only is not None and n != only:
            continue
        where = f'{path}:{n}'
        if line in had:
            faults.append(f'{where}: the same mutant as line {had[line]}')
            continue
        had[line] = n
        p = fields5(line)
        if not p:
            faults.append(f'{where}: not "file %%% old %%% new %%% check %%% case"')
            continue
        f, old, new, check, case = p
        if case not in cases or not case:
            faults.append(f'{where}: no case {case!r} in its suite')
            continue
        if owners.get(check) != case:
            faults.append(f'{where}: no check {check!r} in case {case}'
                          + (f' (it is in case {owners[check]})' if check in owners else ''))
            continue
        _, why = change(f, old, new, read, ('asc/', 'bin/'))
        if why:
            faults.append(f'{where}: {why}')
            continue
        out.append((n, line, f, old, new, check, case))
    return faults, out


def repo_file(root):
    def read(f):  # a link, or a path through a linked folder, is not a plain file of the repo
        p = os.path.join(root, f)
        if os.path.realpath(p) != os.path.join(os.path.realpath(root), os.path.normpath(f)) or not os.path.isfile(p):
            return None
        with open(p, encoding='utf-8') as fh:
            return fh.read()
    return read


def suite_owners(root, list_path):
    """The check names of the list's suite and their cases, or a fault (a str)."""
    suite = SUITES.get(os.path.basename(list_path))
    if not suite:
        return f'{list_path}: not a mutant list ({" or ".join(SUITES)})'
    owners = {}
    paths = [os.path.join(root, 'tests', suite), os.path.join(root, checklint.PAGE)]
    texts = {}
    for p in paths:
        with open(p, encoding='utf-8') as fh:
            texts[p] = fh.read()
    faults = checklint.check_suite(paths[0], texts[paths[0]], checklint.page_names(texts[paths[1]]), owners)
    return f'{paths[0]}: {faults[0]}' if faults else owners


def read_file(root, list_path, only=None):
    """(faults, mutants) of a list file of the repo at root (only: one line of it)."""
    owners = suite_owners(root, list_path)
    if isinstance(owners, str):
        return [owners], []
    try:
        with open(list_path, 'rb') as fh:
            data = fh.read()
    except OSError as e:
        return [f'{list_path}: cannot read it ({e.strerror})'], []
    return check_file(list_path, data, repo_file(root), owners, only)


FILES = {'a.py': 'x = 1\nif x:\n    y = 2\nif x:\n    y = 2\n', 'b.sh': 'echo hi\n'}
OK = "run <<'MUTANTS'\n{}\nMUTANTS\n"
REFUSED = [
    ('a.py %%% if x: %%% if False:', 'times, not once'),
    ('a.py %%% if q: %%% if False:', '0 times'),
    ('a.py %%% x = 1\na.py %%% x = 1 %%% x = 2', 'not "file %%% old %%% new"'),
    ('a.py %%%  %%% x', 'an empty old text'),
    ('a.py %%% x = 1 %%% x = 1', 'the new text is the old one'),
    ('a.py %%% x = 1 %%% x = 2\na.py %%% x = 1 %%% x = 2', 'the same mutant as line 2'),
    ('c.py %%% x %%% y', 'not a plain file'),
    ('a.py %%% 2⏎if x:⏎    y = 2⏎ %%% 2⏎if x:⏎    y = 3⏎', '0 times'),  # the runners strip the end
    ('../a.py %%% x = 1 %%% x = 2', 'not a plain file'),
    ('/a.py %%% x = 1 %%% x = 2', 'not a plain file'),
    ('a.py %%% x = 1⏎if x: %%% x = 1⏎if x', 'no longer parses'),
    ('b.sh %%% echo hi %%% if', 'no longer parses'),
]
PASSED = [
    'a.py %%% x = 1 %%% x = 2',
    'a.py %%% x = 1⏎if x: %%% x = 1⏎if False:',
    'a.py %%% 2⏎if x:⏎    y = 2 %%% 2⏎if x:⏎    y = 3',
    'b.sh %%% echo hi %%% ',
    'b.sh %%% echo hi %%% echo 1 %%% 2',
]
OWNERS = {'c1': 'one', 'c2': 'one', 'c3': 'two'}
# list file lines (bytes), and the start of the fault each must give
FILE_REFUSED = [
    (b'', 'empty'),
    (b'asc/a.py %%% x = 1 %%% x = 2 %%% c1 %%% one', 'no newline'),
    (b'asc/a.py %%% x = 1 %%% x = 2 %%% c1 %%% one\n\n', 'not "file'),
    (b'asc/a.py %%% x = 1 %%% x = 2 %%% c1\n', 'not "file'),
    (b'asc/a.py %%% x = 1 %%% x = 2 %%% c1 %%% one %%% x\n', 'not "file'),
    (b' asc/a.py %%% x = 1 %%% x = 2 %%% c1 %%% one\n', 'not a plain file'),
    (b'asc/a.py %%% x = 1 %%% x = 2 %%% c1 %%% three\n', "no case 'three'"),
    (b'asc/a.py %%% x = 1 %%% x = 2 %%% c1 %%% \n', "no case ''"),
    (b'asc/a.py %%% x = 1 %%% x = 2 %%% c9 %%% one\n', "no check 'c9'"),
    (b'asc/a.py %%% x = 1 %%% x = 2 %%% c3 %%% one\n', 'it is in case two'),
    (b'asc/a.py %%% x = 1 %%% x = 2 %%% c1 %%% one\nasc/a.py %%% x = 1 %%% x = 2 %%% c1 %%% one\n', 'the same mutant as line 1'),
    (b'tests/a.py %%% x = 1 %%% x = 2 %%% c1 %%% one\n', 'not a plain file'),
    (b'systemd/a.py %%% x = 1 %%% x = 2 %%% c1 %%% one\n', 'not a plain file'),
    (b'asc/a.py %%% if q: %%% if False: %%% c1 %%% one\n', '0 times'),
    (b'asc/a.py %%% x = 1 %%% x = 2 %%% c1 %%% one\n\xff\n', 'not UTF-8'),
    (b'asc/a.py %%% x = 1 %%% x = 2 %%% c1 %%% one\nasc/a.py %%% x = 1 %%% x\x00 %%% c1 %%% one\n', "l:2: a control character ('\\x00')"),
    (b'asc/a.py %%% x = 1 %%% x = 2\r %%% c1 %%% one\n', "a control character ('\\r')"),
    (b'asc/a.py %%% x = 1 %%% x = 2\x7f %%% c1 %%% one\n', "a control character ('\\x7f')"),
]
FILE_PASSED = (b'asc/a.py %%% x = 1 %%% x = 2 %%% c1 %%% one\n'
               b'asc/a.py %%% x = 1 %%% x = 3 %%% c3 %%% two\n'
               b'bin/b.sh %%% echo hi %%%  %%% c2 %%% one\n')


def self_test():
    bad = 0
    read = lambda f: FILES.get(os.path.basename(f))  # finds a file wherever the path points
    for body, fault in REFUSED:
        got = check_list('t', OK.format(body), read)
        if not any(fault in f for f in got):
            print(f'not refused ({fault}): {body!r} gave {got}')
            bad += 1
    if not check_list('t', "run <<'MUTANTS'\na.py %%% x = 1 %%% x = 2\n", read):
        print('not refused: a list with no MUTANTS line')
        bad += 1
    if not any('not a plain file of the repo under asc/' in f
               for f in check_list('t', OK.format('a.py %%% x = 1 %%% x = 2'), read, ('asc/', 'bin/'))):
        print('not refused: a file outside the folders its runner copies')
        bad += 1
    for body in PASSED:
        got = check_list('t', OK.format(body), read)
        if got:
            print(f'refused, but fine: {body!r} gave {got}')
            bad += 1
    for data, fault in FILE_REFUSED:
        got, _ = check_file('l', data, read, OWNERS)
        if not any(fault in f for f in got):
            print(f'list file not refused ({fault}): {data!r} gave {got}')
            bad += 1
    got, ms = check_file('l', FILE_PASSED + b'asc/a.py %%% if q: %%% x %%% c1 %%% one\n', read, OWNERS, 2)
    if got or [m[0] for m in ms] != [2]:
        print(f'one line of a list file: not that line alone ({got} {ms})')
        bad += 1
    got, ms = check_file('l', FILE_PASSED, read, OWNERS)
    if got or [(m[0], m[3], m[4], m[5], m[6]) for m in ms] != [(1, 'x = 1', 'x = 2', 'c1', 'one'), (2, 'x = 1', 'x = 3', 'c3', 'two'), (3, 'echo hi', '', 'c2', 'one')]:
        print(f'list file refused or misread, but fine: {got} {ms}')
        bad += 1
    if name('asc/a.py %%% a⏎b %%% c %%% k %%% one') != 'mutant: asc/a.py: a⏎b => c':
        print('name: not file, old and new as written')
        bad += 1
    with tempfile.TemporaryDirectory() as d:  # a link and a folder are not plain files
        with open(os.path.join(d, 'f'), 'w') as fh:
            fh.write('x\n')
        os.symlink('f', os.path.join(d, 'l'))
        os.mkdir(os.path.join(d, 'dir'))
        with open(os.path.join(d, 'dir', 'g'), 'w') as fh:
            fh.write('y\n')
        os.symlink('dir', os.path.join(d, 'ld'))
        got = [repo_file(d)(f) for f in ('f', 'dir/g', 'l', 'dir', 'ld/g', 'none')]
        if got != ['x\n', 'y\n', None, None, None, None]:
            print(f'repo_file: a plain file, one in a folder, a link, a folder, one through a linked folder, none gave {got}')
            bad += 1
    return bad


def main(args):
    if args == ['--self-test']:
        return 1 if self_test() else 0
    if len(args) == 2 and args[0] == '--table':
        faults, ms = read_file(ROOT, args[1])
        if faults or not ms:
            print('\n'.join(faults or [f'{args[1]}: no mutant']), file=sys.stderr)
            return 2
        for n, line, _, _, _, check, case in ms:
            sys.stdout.write(f'{n}\0{case}\0{check}\0{name(line)}\0')
        return 0
    if len(args) == 3 and args[0] == '--apply' and args[2].isdigit():
        faults, ms = read_file(ROOT, args[1], int(args[2]))
        m = [m for m in ms if m[0] == int(args[2])]
        if faults or len(m) != 1:
            print('\n'.join(faults) or f'no mutant at line {args[2]}')
            return 3
        _, _, f, old, new, _, _ = m[0]
        out, why = change(f, old, new, repo_file(ROOT), ('asc/', 'bin/'))
        if why:
            print(why)
            return 3
        with open(os.path.join(ROOT, f), 'w', encoding='utf-8') as fh:
            fh.write(out)
        return 0
    faults, n = [], 0
    for path in args:
        if os.path.basename(path) in SUITES:
            got, ms = read_file(ROOT, path)
            faults += got
            n += len(ms) + len(got)
            continue
        with open(path, encoding='utf-8') as f:
            text = f.read()
        n += len(lists(text))
        faults += check_list(path, text, repo_file(ROOT), ROOTS.get(os.path.basename(path), ('asc/', 'bin/')))
    if not n:
        faults.append('no mutant found in ' + ' '.join(args))
    for f in faults:
        print(f)
    return 1 if faults else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
