"""What a run of tests/asc.sh or tests/dash.sh showed, for tests/mutate.sh.

A check line starts exactly with "  ok    ", "  FAIL  " or "  skip  " (details after a FAIL are
indented further, so they never read as one). A name's status is FAIL if any of its lines is a
FAIL, never "the last one wins"; a name printed twice makes the run untrusted. "case done NAME"
says a case returned (tests/cases.sh).
  python3 -I tests/mutjudge.py baseline <names> <suite> <case output>...   (one file per case,
      named <case>.out) exit 0 when the baseline is sound: every case all ok, no skip, done, no
      name twice, and the names together exactly the source's (<names>: checklint.py --names
      lines), each in its own case; else exit 2 with why. Prints the names, one a line.
  python3 -I tests/mutjudge.py case <output> <check> <case>   a mutant's run of its case:
      "FAIL" (the check failed), "ok" (it passed and the case finished), or "other: why"
  python3 -I tests/mutjudge.py full <output> <check> <baseline names> <cases>   a run of the whole
      suite (<cases>: its cases, comma-separated): "FAIL", "same" (every check ok, each case
      done once, the names the baseline's), or "other: why" (a FAIL elsewhere only among them)
  python3 -I tests/mutjudge.py --self-test
"""
import sys

sys.dont_write_bytecode = True
MARKS = {'  ok    ': 'ok', '  FAIL  ': 'FAIL', '  skip  ': 'skip'}


def read(text):
    """(statuses, twice, skips, done): each check name's status, the names printed more than once,
    the skipped names, the cases that printed case done (in order, repeats kept)."""
    st, twice, skips, done = {}, set(), [], []
    for line in text.split('\n'):
        if line.startswith('case done '):
            done.append(line[len('case done '):])
            continue
        mark = MARKS.get(line[:8])
        if not mark:
            continue
        n = line[8:].strip()
        if mark == 'skip':
            skips.append(n)
            continue
        if n in st:
            twice.add(n)
        st[n] = 'FAIL' if st.get(n) == 'FAIL' or mark == 'FAIL' else 'ok'
    return st, twice, skips, done


def baseline(names, suite, outs):
    """(why not sound or '', the names seen). names: (suite, case, name) of the source;
    outs: {case: output text}."""
    want = {n: c for s, c, n in names if s == suite and n}
    cases = sorted({c for s, c, _ in names if s == suite})  # a case with no check of its own too
    seen, why = {}, []
    if not want:
        return f'{suite}: no checks in its source', []
    if sorted(outs) != cases:
        return f'{suite}: the baseline ran the cases {sorted(outs)}, the source has {cases}', []
    for c in cases:
        st, twice, skips, done = read(outs[c])
        if not st:
            why.append(f'case {c}: no check ran')
        if twice:
            why.append(f'case {c}: printed twice: {", ".join(sorted(twice))}')
        if skips:
            why.append(f'case {c}: skipped: {", ".join(skips)}')
        if done != [c]:
            why.append(f'case {c}: case done lines {done}, not one for it')
        bad = sorted(n for n, s in st.items() if s != 'ok')
        if bad:
            why.append(f'case {c}: FAIL: {", ".join(bad)}')
        for n in st:
            if n in seen:
                why.append(f'{n}: in case {seen[n]} and case {c}')
            seen.setdefault(n, c)
            if want.get(n) != c:
                why.append(f'{n}: ran in case {c}, the source has it in {want.get(n) or "no case"}')
    missing = sorted(set(want) - set(seen))
    if missing:
        why.append(f'not run: {", ".join(missing)}')
    return '; '.join(why), sorted(seen)


def case_run(text, check, case):
    st, twice, _, done = read(text)
    if twice:
        return f'other: printed twice: {", ".join(sorted(twice))}'
    if st.get(check) == 'FAIL':
        return 'FAIL'
    if st.get(check) == 'ok' and done == [case]:
        return 'ok'
    return 'other: ' + (f'{check} ok, but case done lines {done}' if check in st else f'{check} not reached')


def full_run(text, check, names, cases):
    st, twice, skips, done = read(text)
    if twice:
        return f'other: printed twice: {", ".join(sorted(twice))}'
    if st.get(check) == 'FAIL':
        return 'FAIL'
    if check not in st:
        return f'other: {check} not reached'
    if skips:
        return f'other: skipped: {", ".join(skips)}'
    elsewhere = sorted(n for n, v in st.items() if v != 'ok')
    if elsewhere:
        return f'other: {check} ok, a FAIL elsewhere: {", ".join(elsewhere[:5])}'
    if sorted(st) != sorted(names):
        gone, more = sorted(set(names) - set(st)), sorted(set(st) - set(names))
        return f'other: not the baseline\'s checks (not run: {gone[:5]}, new: {more[:5]})'
    if sorted(done) != sorted(cases):
        return f'other: case done lines {done}, not one for each of {cases}'
    return 'same'


TESTS = [
    # (function, args, expected)
    (case_run, ('  ok    a\n  FAIL  b\n        x\ncase done c\n', 'b', 'c'), 'FAIL'),
    (case_run, ('  FAIL  b\n', 'b', 'c'), 'FAIL'),  # stopped at it: a FAIL all the same
    (case_run, ('  ok    a\n  ok    b\ncase done c\n', 'b', 'c'), 'ok'),
    (case_run, ('  ok    a\n  ok    b\n', 'b', 'c'), 'other: b ok, but case done lines []'),
    (case_run, ('  ok    a\nsetup: x\n', 'b', 'c'), 'other: b not reached'),
    (case_run, ('  ok    b\n  FAIL  b\ncase done c\n', 'b', 'c'), 'other: printed twice: b'),
    (case_run, ('  FAIL  a\n  ok    b\ncase done c\n', 'b', 'c'), 'ok'),  # a FAIL elsewhere only
    (case_run, ('  okay  b\n   ok    b\n        FAIL  b\ncase done c\n', 'b', 'c'), 'other: b not reached'),
    (full_run, ('  ok    a\n  FAIL  b\n', 'b', ['a', 'b'], ['x', 'y']), 'FAIL'),
    (full_run, ('  ok    a\n  ok    b\ncase done x\ncase done y\n', 'b', ['a', 'b'], ['x', 'y']), 'same'),
    (full_run, ('  ok    a\n  ok    b\ncase done y\ncase done x\n', 'b', ['a', 'b'], ['x', 'y']), 'same'),
    (full_run, ('  ok    a\n  ok    b\ncase done x\n', 'b', ['a', 'b'], ['x', 'y']), "other: case done lines ['x'], not one for each of ['x', 'y']"),
    (full_run, ('  ok    a\n  ok    b\ncase done x\ncase done x\n', 'b', ['a', 'b'], ['x', 'y']), "other: case done lines ['x', 'x'], not one for each of ['x', 'y']"),
    (full_run, ('  ok    b\ncase done x\n', 'b', ['a', 'b'], ['x', 'y']), "other: not the baseline's checks (not run: ['a'], new: [])"),
    (full_run, ('  ok    a\n  ok    b\n  ok    c\ncase done x\n', 'b', ['a', 'b'], ['x', 'y']), "other: not the baseline's checks (not run: [], new: ['c'])"),
    (full_run, ('  ok    a\n  ok    b\n  skip  c\ncase done x\n', 'b', ['a', 'b'], ['x', 'y']), 'other: skipped: c'),
    (full_run, ('  ok    a\n', 'b', ['a', 'b'], ['x', 'y']), 'other: b not reached'),
    (full_run, ('  FAIL  a\n  ok    b\ncase done x\ncase done y\n', 'b', ['a', 'b'], ['x', 'y']), 'other: b ok, a FAIL elsewhere: a'),
    (full_run, ('  ok    a\n  ok    b\n', 'b', ['a', 'b'], ['x', 'y']), "other: case done lines [], not one for each of ['x', 'y']"),
    (full_run, ('  ok    a\n  ok    a\n  ok    b\ncase done x\n', 'b', ['a', 'b'], ['x', 'y']), 'other: printed twice: a'),
]
NAMES = [('s', 'x', 'a'), ('s', 'x', 'b'), ('s', 'y', 'c'), ('t', 'z', 'd'), ('s', 'x', ''), ('s', 'y', '')]
GOOD = {'x': '  ok    a\n  ok    b\ncase done x\n', 'y': '  ok    c\ncase done y\n'}
BASE_REFUSED = [
    ({'x': GOOD['x']}, 'the baseline ran the cases'),
    ({**GOOD, 'y': '  ok    c\n'}, "case y: case done lines []"),
    ({**GOOD, 'y': '  ok    c\ncase done y\ncase done y\n'}, "case done lines ['y', 'y']"),
    ({**GOOD, 'y': '  FAIL  c\ncase done y\n'}, 'case y: FAIL: c'),
    ({**GOOD, 'y': '  ok    c\n  skip  e\ncase done y\n'}, 'case y: skipped: e'),
    ({**GOOD, 'y': '  ok    c\n  ok    c\ncase done y\n'}, 'case y: printed twice: c'),
    ({**GOOD, 'y': 'case done y\n'}, 'case y: no check ran'),
    ({**GOOD, 'y': '  ok    c\n  ok    a\ncase done y\n'}, 'a: in case x and case y'),
    ({**GOOD, 'y': '  ok    c\n  ok    e\ncase done y\n'}, 'e: ran in case y, the source has it in no case'),
    ({'x': '  ok    a\ncase done x\n', 'y': GOOD['y']}, 'not run: b'),
]
NAMES_W = NAMES + [('s', 'w', '')]  # a case w with no check of its own: run, and judged too


def self_test():
    bad = 0
    for f, args, want in TESTS:
        got = f(*args)
        if got != want:
            print(f'{f.__name__}{args!r}: {got!r}, not {want!r}')
            bad += 1
    for outs, want in BASE_REFUSED:
        why, _ = baseline(NAMES, 's', outs)
        if want not in why:
            print(f'baseline not refused ({want}): {outs!r} gave {why!r}')
            bad += 1
    why, _ = baseline(NAMES_W, 's', GOOD)
    if 'the baseline ran the cases' not in why:
        print(f'a case with no check of its own not run, not refused: {why!r}')
        bad += 1
    why, _ = baseline(NAMES_W, 's', {**GOOD, 'w': '  skip  q (why)\ncase done w\n'})
    if 'case w: skipped: q (why)' not in why:
        print(f'a case with only a skip: not refused: {why!r}')
        bad += 1
    why, seen = baseline(NAMES, 's', GOOD)
    if why or seen != ['a', 'b', 'c']:
        print(f'a sound baseline refused: {why!r} {seen!r}')
        bad += 1
    if baseline(NAMES, 'u', {})[0] != 'u: no checks in its source':
        print('a suite with no checks in its source: not refused')
        bad += 1
    return bad


def text(path):
    with open(path, encoding='utf-8', errors='replace') as f:
        return f.read()


def main(args):
    if args == ['--self-test']:
        return 1 if self_test() else 0
    if len(args) >= 3 and args[0] == 'baseline':
        names = [tuple(l.split('\t', 2)) for l in text(args[1]).split('\n') if l]
        outs = {}
        for p in args[3:]:
            c = p.rsplit('/', 1)[-1]
            if not c.endswith('.out'):
                print(f'not a case output: {p}')
                return 2
            outs[c[:-len('.out')]] = text(p)
        suite_path = [s for s, _, _ in names if s.endswith('/' + args[2] + '.sh') or s == args[2]]
        why, seen = baseline(names, suite_path[0] if suite_path else args[2], outs)
        if why:
            print(why)
            return 2
        print('\n'.join(seen))
        return 0
    if len(args) == 4 and args[0] == 'case':
        print(case_run(text(args[1]), args[2], args[3]))
        return 0
    if len(args) == 5 and args[0] == 'full':
        print(full_run(text(args[1]), args[2], [l for l in text(args[3]).split('\n') if l], args[4].split(',')))
        return 0
    print(__doc__.strip().split('\n')[-1] if not args else f'mutjudge: bad arguments: {args}', file=sys.stderr)
    return 2


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
