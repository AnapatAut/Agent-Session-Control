"""The mutant lists in tests/asc.sh, tests/dash.sh and tests/privacy.sh (run by tests/lint.sh).

A mutant is a line "file %%% old %%% new" in a heredoc ending at MUTANTS (tests/mutate.sh and
privacy.sh run them, and refuse the same as here; a mutant run comes seldom, so this says it at
every lint). A ⏎ in old or new stands for a newline. Refused: a line not in that form, a file
that is not a plain file of the repo in the folders its runner copies (asc/ or bin/; for
privacy.sh tools/ or .githooks/), an empty old text, a new text the same as the old, an old
text not found exactly once in its file (never "the first one"), a line given twice in a list,
and a change that no longer parses (Python by compile() in memory, bash by `bash -n`, JS by
`node --check` if node is here): a mutant that breaks the syntax fails every check, so it would
be a catch that tests nothing.
  python3 -I tests/mutantlint.py <suite>...   prints each fault; exit 1 if any
  python3 -I tests/mutantlint.py --self-test  each form it must refuse, refused
"""
import os
import shutil
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
SEP = ' %%% '
NL = '⏎'
ROOTS = {'privacy.sh': ('tools/', '.githooks/')}  # else asc/ and bin/: product code only


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
    """file, old, new as the runners split them (the new text keeps any later separator)."""
    if line.count(SEP) < 2:
        return None
    f, rest = line.split(SEP, 1)
    old, new = rest.split(SEP, 1)
    return f, old.replace(NL, '\n'), new.replace(NL, '\n')


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


def check_list(path, text, read, roots=('',)):
    """Faults of the mutant lists in suite text; read(file) is the file's text, or None. A
    file's text is taken as the runners take it, by $(<file): without its trailing newlines."""
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
        f, old, new = got
        body = None if f.startswith('/') or '..' in f.split('/') or not f.startswith(roots) else read(f)
        if body is None:
            faults.append(f'{where}: {f} is not a plain file of the repo under {" or ".join(roots)}')
            continue
        body = body.rstrip('\n')
        if not old:
            faults.append(f'{where}: an empty old text')
        elif old == new:
            faults.append(f'{where}: the new text is the old one')
        elif body.count(old) != 1:
            faults.append(f'{where}: the old text is in {f} {body.count(old)} times, not once')
        else:
            why = parses(f, body + '\n')
            if why:
                faults.append(f'{where}: {f} does not parse even unchanged: {why}')
            else:
                why = parses(f, body.replace(old, new) + '\n')
                if why:
                    faults.append(f'{where}: {f} no longer parses with it: {why}')
    return faults


def repo_file(root):
    def read(f):  # a link, or a path through a linked folder, is not a plain file of the repo
        p = os.path.join(root, f)
        if os.path.realpath(p) != os.path.join(os.path.realpath(root), os.path.normpath(f)) or not os.path.isfile(p):
            return None
        with open(p, encoding='utf-8') as fh:
            return fh.read()
    return read


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
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    faults, n = [], 0
    for path in args:
        with open(path, encoding='utf-8') as f:
            text = f.read()
        n += len(lists(text))
        faults += check_list(path, text, repo_file(root), ROOTS.get(os.path.basename(path), ('asc/', 'bin/')))
    if not n:
        faults.append('no mutant found in ' + ' '.join(args))
    for f in faults:
        print(f)
    return 1 if faults else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
