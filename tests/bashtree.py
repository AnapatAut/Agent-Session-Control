"""A small bash parser for the suites' lint (tests/checklint.py): the commands of a script, as
a tree, with what encloses each one (a function, a loop, a subshell, a $( )), the and-or list it
is in and its pipeline. It reads what the suites use: simple commands, pipelines, && and ||
lists, { }, ( ), $( ), <( ), for (also for ((...))), while, until, if, case, function
definitions, [[ ]], (( )), heredocs, here-strings, quotes, ${ }, $(( )) and redirections. What
it cannot read is a ParseError with its line, never a guess.
"""

RESERVED_END = {'}', 'done', 'fi', 'then', 'else', 'elif', 'do', 'esac'}


class ParseError(Exception):
    pass


class Node:
    """t: 'seq', 'andor', 'pipeline', 'simple', 'brace', 'subshell', 'subst', 'procsub', 'for',
    'while', 'until', 'if', 'case', 'func', 'arith', 'cond'. A simple command has `words`
    [(text, start)], a function `name`; every node `pos` and `kids`, and `up` once linked."""

    def __init__(self, t, pos, **kw):
        self.t, self.pos, self.kids, self.up = t, pos, [], None
        self.__dict__.update(kw)

    def walk(self):
        yield self
        for k in self.kids:
            yield from k.walk()

    def ancestors(self):
        n = self.up
        while n is not None:
            yield n
            n = n.up


class Parser:
    def __init__(self, text):
        self.s, self.i, self.n = text, 0, len(text)
        self.heredocs = []  # terminators waiting for the next newline
        self.substs = []    # the $( ) and <( ) of the word being read

    # -- positions and errors
    def line(self, pos):
        return self.s.count('\n', 0, pos) + 1

    def fail(self, what, pos=None):
        raise ParseError(f'line {self.line(self.i if pos is None else pos)}: {what}')

    # -- blanks, comments, heredoc bodies
    def blank(self):
        """Spaces, tabs, a backslash-newline and comments; not a newline."""
        s = self.s
        while self.i < self.n:
            c = s[self.i]
            if c in ' \t':
                self.i += 1
            elif s.startswith('\\\n', self.i):
                self.i += 2
            elif c == '#':
                while self.i < self.n and s[self.i] != '\n':
                    self.i += 1
            else:
                break

    def newline(self):
        """At a newline: past it and past the bodies of the heredocs it ends the line of."""
        self.i += 1
        while self.heredocs:
            term, strip = self.heredocs.pop(0)
            while True:
                if self.i >= self.n:
                    self.fail(f'a heredoc that never ends: {term}')
                e = self.s.find('\n', self.i)
                e = self.n if e < 0 else e
                body = self.s[self.i:e]
                self.i = min(e + 1, self.n)
                if (body.lstrip('\t') if strip else body) == term:
                    break

    def gap(self):
        """Blanks and newlines (where a list may go on: after && || | and inside blocks)."""
        while True:
            self.blank()
            if self.i < self.n and self.s[self.i] == '\n':
                self.newline()
            else:
                return

    # -- words
    def peek_op(self):
        s, i = self.s, self.i
        for op in (';;&', ';;', ';&', '&&', '||', '|&', '&>>', '&>', '>>', '>&', '<&', '<<<', '<<-', '<<',
                   '<>', '>|', ';', '&', '|', '(', ')', '<', '>', '\n'):
            if s.startswith(op, i):
                if op in ('<', '>') and s.startswith('(', i + 1):
                    return None  # <( and >( start a word (a process substitution)
                return op
        return None

    def collect(self, fn):
        """Runs fn, with the $( ) and <( ) it reads kept apart: returns them."""
        saved, self.substs = self.substs, []
        try:
            fn()
        finally:
            got, self.substs = self.substs, saved
        return got

    def word(self):
        """One word from here: (text, start), with its $( ) and <( ) parsed into self.substs."""
        s, start = self.s, self.i
        while self.i < self.n:
            c = s[self.i]
            if c in ' \t\n;&|)':
                break
            if c in '<>':
                if s.startswith('(', self.i + 1) and self.i == start:
                    self.nested('procsub')
                    continue
                break
            if c == '(':
                if self.i > start and s[self.i - 1] == '=':  # an array: x=(a b)
                    self.i = self.skip_parens(self.i + 1)
                    continue
                if self.i > start and s[self.i - 1] in '@!*+?':  # an extglob in a pattern
                    self.i = self.skip_parens(self.i + 1)
                    continue
                break
            if c == '\\':
                self.i += 2
            elif c == "'":
                self.squote()
            elif s.startswith("$'", self.i):
                self.i += 1
                self.ansi()
            elif c == '"':
                self.dquote()
            elif c == '$':
                self.dollar()
            elif c == '`':
                e = s.find('`', self.i + 1)
                if e < 0:
                    self.fail('a backquote that never ends')
                self.i = e + 1
            else:
                self.i += 1
        return s[start:self.i], start

    def squote(self):
        e = self.s.find("'", self.i + 1)
        if e < 0:
            self.fail("a ' that never ends")
        self.i = e + 1

    def ansi(self):  # at the ' of $'...'
        j = self.i + 1
        while j < self.n and self.s[j] != "'":
            j += 2 if self.s[j] == '\\' else 1
        if j >= self.n:
            self.fail("a $' that never ends")
        self.i = j + 1

    def dquote(self):
        start = self.i
        self.i += 1
        while self.i < self.n:
            c = self.s[self.i]
            if c == '\\':
                self.i += 2
            elif c == '"':
                self.i += 1
                return
            elif c == '$':
                self.dollar()
            elif c == '`':
                e = self.s.find('`', self.i + 1)
                if e < 0:
                    self.fail('a backquote that never ends')
                self.i = e + 1
            else:
                self.i += 1
        self.fail('a " that never ends', start)

    def dollar(self):
        s = self.s
        if s.startswith('$((', self.i):
            self.i = self.skip_parens(self.i + 2)
            return
        if s.startswith('$(', self.i):
            self.nested('subst')
            return
        if s.startswith('${', self.i):
            self.i = self.skip_braces(self.i + 2)
            return
        self.i += 1

    def nested(self, t):
        """At the $ of $( (t 'subst'), or the < or > of <( or >( ('procsub'): its commands, read
        as a script of their own, kept with the word they are in."""
        start = self.i
        self.i += 2
        body = []
        body.extend(self.collect(lambda: body.append(self.seq({')'}))))
        if not self.s.startswith(')', self.i):
            self.fail(f'a {self.s[start:start + 2]} that never ends', start)
        self.i += 1
        node = Node(t, start)
        node.kids = body
        self.substs.append(node)

    def skip_parens(self, j):
        """j just past an opening (: past its closing ), quotes and nesting followed (for
        arithmetic, arrays and extglobs; a $( ) in them is read as one)."""
        depth, s = 1, self.s
        while j < self.n:
            c = s[j]
            if c == '\\':
                j += 2
                continue
            if s.startswith('$(', j) and not s.startswith('$((', j):
                self.i = j
                self.nested('subst')
                j = self.i
                continue
            if c == "'":
                e = s.find("'", j + 1)
                if e < 0:
                    break
                j = e + 1
                continue
            if c == '"':
                self.i = j
                self.dquote()
                j = self.i
                continue
            if c == '(':
                depth += 1
            elif c == ')':
                depth -= 1
                if depth == 0:
                    return j + 1
            j += 1
        self.fail('a ( that never ends', j)

    def skip_braces(self, j):
        depth, s = 1, self.s
        while j < self.n:
            c = s[j]
            if c == '\\':
                j += 2
                continue
            if s.startswith("$'", j):
                self.i = j + 1
                self.ansi()
                j = self.i
                continue
            if c == "'":
                e = s.find("'", j + 1)
                if e < 0:
                    break
                j = e + 1
                continue
            if c == '"':
                self.i = j
                self.dquote()
                j = self.i
                continue
            if s.startswith('$(', j) or s.startswith('${', j):
                self.i = j
                self.dollar()
                j = self.i
                continue
            if c == '{':
                depth += 1
            elif c == '}':
                depth -= 1
                if depth == 0:
                    return j + 1
            j += 1
        self.fail('a ${ that never ends', j)

    # -- the grammar
    def seq(self, ends):
        """And-or lists until a reserved word in `ends` at a command's start, a ')' in `ends`,
        ';;' when 'esac' is in ends (a case arm), or the end of the text."""
        node = Node('seq', self.i)
        while True:
            self.gap()
            if self.i >= self.n:
                return node
            if ')' in ends and self.s.startswith(')', self.i):
                return node
            if 'esac' in ends and (self.s.startswith(';;', self.i) or self.s.startswith(';&', self.i)):
                return node
            w = self.reserved_here()
            if w in ends:
                return node
            node.kids.append(self.andor())

    def reserved_here(self):
        """The reserved word that starts here, if any (a word ended by a blank or operator)."""
        s, i = self.s, self.i
        for w in ('}', '{', 'done', 'fi', 'then', 'else', 'elif', 'do', 'esac', 'for', 'while', 'until',
                  'if', 'case', 'in', '!', 'function'):
            if s.startswith(w, i):
                e = i + len(w)
                if e >= self.n or s[e] in ' \t\n;&|()<>':
                    return w
        return None

    def andor(self):
        node = Node('andor', self.i, ops=[], term=None)
        node.kids.append(self.pipeline())
        while True:
            self.blank()
            op = self.peek_op()
            if op in ('&&', '||'):
                self.i += 2
                self.gap()
                node.ops.append(op)
                node.kids.append(self.pipeline())
                continue
            if op in (';', '&'):
                self.i += 1
                node.term = op
            elif op == '\n':
                self.newline()
                node.term = '\n'
            return node

    def pipeline(self):
        node = Node('pipeline', self.i, neg=False, timed=False)
        self.blank()
        while True:
            w = self.reserved_here()
            if w == '!':
                node.neg = True
                self.i += 1
                self.blank()
            elif self.s.startswith('time', self.i) and self.s[self.i + 4:self.i + 5] in (' ', '\t'):
                node.timed = True
                self.i += 4
                self.blank()
            else:
                break
        node.kids.append(self.command())
        while True:
            self.blank()
            op = self.peek_op()
            if op in ('|', '|&'):
                self.i += len(op)
                self.gap()
                node.kids.append(self.command())
                continue
            return node

    def command(self):
        self.blank()
        s, start = self.s, self.i
        if self.i >= self.n:
            self.fail('a command missing at the end')
        w = self.reserved_here()
        if w == '{':
            self.i += 1
            node = Node('brace', start)
            node.kids = [self.seq({'}'})]
            self.expect('}')
            return self.redirs(node)
        if s.startswith('((', self.i):
            self.i = self.skip_parens(self.i + 1)
            return self.redirs(Node('arith', start))
        if s.startswith('(', self.i):
            self.i += 1
            node = Node('subshell', start)
            node.kids = [self.seq({')'})]
            if not s.startswith(')', self.i):
                self.fail('a ( that never ends', start)
            self.i += 1
            return self.redirs(node)
        if s.startswith('[[', self.i) and s[self.i + 2:self.i + 3] in (' ', '\t'):
            return self.cond(start)
        if w in ('for', 'while', 'until'):
            return self.loop(w, start)
        if w == 'if':
            return self.if_(start)
        if w == 'case':
            return self.case(start)
        if w == 'function':
            self.i += len(w)
            self.blank()
            name, _ = self.word()
            self.blank()
            if s.startswith('()', self.i):
                self.i += 2
            return self.func(name, start)
        if w in RESERVED_END or w == 'in':
            self.fail(f'{w} where a command was expected')
        return self.simple(start)

    def expect(self, w):
        self.gap()
        if self.reserved_here() != w:
            self.fail(f'{w} expected')
        self.i += len(w)

    def redirs(self, node):
        """Redirections after a compound command (`done < <(...)`, `} 9>file`)."""
        s = self.s
        while True:
            self.blank()
            j = self.i
            while j < self.n and s[j].isdigit():
                j += 1
            if not (j < self.n and s[j] in '<>' and not s.startswith('(', j + 1) or s.startswith('&>', j)):
                return node
            self.i = j
            node.kids.extend(self.collect(self.redirect))

    def simple(self, start):
        node = Node('simple', start, words=[], redirected=False)
        saved = self.substs
        self.substs = []
        s = self.s
        while True:
            self.blank()
            if self.i >= self.n:
                break
            c = s[self.i]
            if c in '\n;&|)':
                if s.startswith('&>', self.i):
                    self.redirect()
                    node.redirected = True
                    continue
                break
            if c == '(' :
                if node.words and len(node.words) == 1 and s.startswith('()', self.i):
                    self.i += 2
                    name = node.words[0][0]
                    self.substs = saved
                    return self.func(name, start)
                self.fail('a ( inside a command')
            j = self.i
            while j < self.n and s[j].isdigit():
                j += 1
            if j < self.n and s[j] in '<>' and not s.startswith('<(', j) and not s.startswith('>(', j):
                self.i = j
                self.redirect()
                node.redirected = True
                continue
            node.words.append(self.word())
        node.kids = self.substs
        self.substs = saved
        if not node.words and not node.redirected:
            self.fail('an empty command', start)
        return node

    def redirect(self):
        s = self.s
        for o in ('&>>', '&>', '>>', '>&', '<&', '<<<', '<<-', '<<', '<>', '>|', '<', '>'):
            if s.startswith(o, self.i):
                self.i += len(o)
                break
        self.blank()
        if o in ('<<', '<<-'):
            w, _ = self.word()
            term = w.replace("'", '').replace('"', '').replace('\\', '')
            self.heredocs.append((term, o == '<<-'))
            return
        self.word()

    def cond(self, start):
        """[[ ... ]]: words up to ]], its && || < > ( ) its own."""
        s = self.s
        self.i += 2
        node = Node('cond', start, words=[('[[', start)])
        saved = self.substs
        self.substs = []
        while True:
            self.blank()
            if self.i >= self.n:
                self.fail('a [[ that never ends', start)
            if s.startswith(']]', self.i) and (self.i + 2 >= self.n or s[self.i + 2] in ' \t\n;&|)'):
                self.i += 2
                break
            if s[self.i] == '\n':
                self.newline()
                continue
            op = None
            for o in ('&&', '||', '==', '!=', '=~', '<', '>', '(', ')', '!'):
                if s.startswith(o, self.i):
                    op = o
                    break
            if op in ('&&', '||', '<', '>', '(', ')'):
                self.i += len(op)
                continue
            if op == '=~':
                self.i += 2
                self.blank()
                self.regex()
                continue
            j = self.i
            self.word_cond()
            if self.i == j:
                self.i += 1
        node.kids = self.substs
        self.substs = saved
        return self.redirs(node)

    def word_cond(self):
        """A word in [[ ]]: as word(), but ( ) < > in a pattern belong to it."""
        s = self.s
        while self.i < self.n and s[self.i] not in ' \t\n':
            if s.startswith(']]', self.i):
                break
            c = s[self.i]
            if c == '\\':
                self.i += 2
            elif c == "'":
                self.squote()
            elif s.startswith("$'", self.i):
                self.i += 1
                self.ansi()
            elif c == '"':
                self.dquote()
            elif c == '$':
                self.dollar()
            elif c in '&|' and s.startswith(c * 2, self.i):
                break
            elif c in ')':
                break
            else:
                self.i += 1

    def regex(self):
        """The right side of =~: up to a blank outside ( ) and quotes."""
        s, depth = self.s, 0
        while self.i < self.n:
            c = s[self.i]
            if c in ' \t\n' and depth == 0:
                return
            if c == '\\':
                self.i += 2
            elif c == "'":
                self.squote()
            elif c == '"':
                self.dquote()
            elif s.startswith('$(', self.i) or s.startswith('${', self.i):
                self.dollar()
            else:
                depth += (c == '(') - (c == ')')
                self.i += 1

    def loop(self, w, start):
        self.i += len(w)
        node = Node(w, start)
        self.blank()
        if w == 'for':
            if self.s.startswith('((', self.i):
                self.i = self.skip_parens(self.i + 1)
            else:
                self.word()  # the variable
                self.blank()
                if self.reserved_here() == 'in':
                    self.i += 2

                    def words():
                        while True:
                            self.blank()
                            if self.i >= self.n or self.s[self.i] in ';\n':
                                return
                            self.word()
                    node.kids.extend(self.collect(words))
            self.blank()
            if self.s.startswith(';', self.i):
                self.i += 1
        else:
            node.kids.append(self.seq({'do'}))
        self.expect('do')
        node.kids.append(self.seq({'done'}))
        self.expect('done')
        return self.redirs(node)

    def if_(self, start):
        self.i += 2
        node = Node('if', start)
        node.kids.append(self.seq({'then'}))
        self.expect('then')
        while True:
            node.kids.append(self.seq({'elif', 'else', 'fi'}))
            self.gap()
            w = self.reserved_here()
            if w == 'elif':
                self.i += 4
                node.kids.append(self.seq({'then'}))
                self.expect('then')
            elif w == 'else':
                self.i += 4
                node.kids.append(self.seq({'fi'}))
                self.expect('fi')
                break
            else:
                self.expect('fi')
                break
        return self.redirs(node)

    def case(self, start):
        self.i += 4
        self.blank()
        node = Node('case', start)
        node.kids.extend(self.collect(self.word))
        self.gap()
        if self.reserved_here() != 'in':
            self.fail('case without in', start)
        self.i += 2
        while True:
            self.gap()
            if self.reserved_here() == 'esac':
                self.i += 4
                return self.redirs(node)
            if self.s.startswith('(', self.i):
                self.i += 1
            while True:  # the patterns, to their )
                self.blank()
                node.kids.extend(self.collect(self.word))
                self.blank()
                if self.s.startswith('|', self.i):
                    self.i += 1
                    continue
                if not self.s.startswith(')', self.i):
                    self.fail('a case pattern without its )')
                self.i += 1
                break
            node.kids.append(self.seq({'esac'}))
            self.gap()
            for o in (';;&', ';;', ';&'):
                if self.s.startswith(o, self.i):
                    self.i += len(o)
                    break

    def func(self, name, start):
        self.gap()
        node = Node('func', start, name=name)
        node.kids.append(self.command())
        return node


def parse(text):
    """The script's tree (a 'seq'), every node linked to the one around it."""
    p = Parser(text)
    root = p.seq(set())
    if p.i < p.n:
        p.fail('cannot read on from here')
    if p.heredocs:
        p.fail(f'a heredoc that never ends: {p.heredocs[0][0]}')

    def link(n):
        for k in n.kids:
            k.up = n
            link(k)
    link(root)
    root.line = p.line
    return root
