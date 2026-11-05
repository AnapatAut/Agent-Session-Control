"""Remote control of a running claude, now: asctl types /remote-control into its pane.

The one command asctl types into a running claude, and only when it cannot land anywhere
else: claude idle (its session file), its pane not in copy mode, its prompt empty (read from
the screen, `capture-pane -e`). After typing, before Enter: the prompt shows exactly the
command, claude is still idle, and no command menu opened (for on), or the menu would take
/remote-control on Enter (for off, waited for up to 3 s: a claude with many commands draws it
after the typed text). Claude draws its menu under the input box (2.1.316) or above it
(2.1.318), and a status line or plugins may draw any number of lines on either side, some
changing on their own; so the menu is never looked for at a place: it is the lines that
changed since before typing and are shaped like menu entries, and Enter takes the one marked ❯.
Otherwise what was typed is taken back, only when the prompt holds nothing but that. Nobody at
its tmux session may have typed in the last TYPED_S seconds, nor while asctl types (its clients'
last key; asctl's own keys are not a client's): else nothing is typed, or Enter not pressed and
nothing taken back. A slow claude (a busy host) draws the typed keys late: its prompt is read
once it stopped changing.
On: `/remote-control <title>` (always the title: without one claude.ai shows a random name;
only letters, digits, space, . _ -, as anything else could open a menu or be read by tmux).
Off: `/remote-control` opens a dialog (Disconnect this session / Show QR code / Continue,
Continue selected, the session status "waiting"): once that dialog is open at the bottom of
the screen, Up until Disconnect is selected, checked, then Enter. Either way the change is
confirmed from the session file (bridgeSessionId). Seen with Claude Code 2.1.316 and 2.1.318.
"""
import glob
import os
import re
import time

from . import live, tmuxctl

TYPED_S = 5  # a key at its tmux session this recently: someone is at it, asctl does not type there

ANSI = re.compile(r"\x1b\[[0-9;:?]*[A-Za-z]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)")  # colours; links (OSC 8)
DIM = re.compile(r"\x1b\[2m.*?(?=\x1b\[(?:0|22)?m|$)")  # a placeholder ("Try ...") is dim
RULE = re.compile(r"─{10,}(?: [^─]+ ─*)?")  # the top rule may carry the session's name
TITLE = re.compile(r"[A-Za-z0-9][A-Za-z0-9 ._-]*")
CMD = "/remote-control"
DISCONNECT = "Disconnect this session"
# A command menu's entry: indented (a prompt in the transcript is not), "/name", then nothing or
# its description after two spaces or more; group 1 is the selection mark Enter goes by.
ENTRY = re.compile(r"\s+(?:(❯)\s*)?(/[A-Za-z][\w:.-]*)(?:\s{2,}\S.*)?")


def steady(pane, tries=10, gap=0.15):
    """The pane's screen once two captures in a row match: a capture in the middle of a redraw
    can show half a frame (a quoted Disconnect line without the dialog under it)."""
    scr = screen(pane)
    for _ in range(tries):
        time.sleep(gap)
        nxt = screen(pane)
        if nxt == scr:
            break
        scr = nxt
    return scr


def plain(line):
    return ANSI.sub("", line).replace("\xa0", " ")


def screen(pane):
    return tmuxctl.capture_pane(pane, escapes=True)


def box(lines):
    """The index of the input line of claude's one-line input box, or None: the lowest line that
    starts with ❯ and has a rule right above and right below it. Whatever a status line or
    plugins draw above or below the box (rules too, any number of lines) does not move it."""
    p = [plain(l).strip() for l in lines]
    for i in range(len(p) - 2, 0, -1):
        if p[i].startswith("❯") and RULE.fullmatch(p[i - 1]) and RULE.fullmatch(p[i + 1]):
            return i
    return None


def prompt_text(scr):
    """What is typed in claude's input box, from a capture with escapes: "" when empty (a dim
    placeholder counts as empty), None when the screen does not end with claude's one-line input
    box between two rules (a dialog, a long or wrapped prompt)."""
    lines = scr.rstrip("\n").split("\n")
    i = box(lines)
    if i is None:
        return None
    text = plain(DIM.sub("", lines[i])).strip()
    return text[1:].strip() if text.startswith("❯") else None


def changed(scr, before):
    """The lines of the capture scr (plain) that differ from the capture before of the same pane,
    row by row from the top (a row the other lacks counts as changed), without claude's input
    line: where a menu shows, wherever claude draws it, among what else changed."""
    a, b = scr.rstrip("\n").split("\n"), before.rstrip("\n").split("\n")
    i = box(a)
    return [plain(l).rstrip() for j, l in enumerate(a)
            if j != i and (j >= len(b) or plain(b[j]).rstrip() != plain(l).rstrip())]


def entries(scr, before):
    """A command menu that showed since before: (marked, name, line) for each changed line shaped
    like an entry. Status lines, plugin lines and the transcript are not shaped like one."""
    return [(bool(m.group(1)), m.group(2), l.strip()) for l in changed(scr, before)
            if (m := ENTRY.fullmatch(l))]


def takes(scr, before):
    """The entry Enter would take in a menu that showed since before: the one marked ❯, or the
    only one; None when no menu showed; () when that cannot be told (two marked: one may be a
    quote in claude's answer; several, none marked)."""
    e = entries(scr, before)
    if not e:
        return None
    marked = [x for x in e if x[0]]
    return marked[0] if len(marked) == 1 else e[0] if not marked and len(e) == 1 else ()


def offers_cmd(scr, before):
    """True when the menu that showed since before takes /remote-control itself on Enter."""
    t = takes(scr, before)
    return bool(t) and t[1] == CMD


def offers(pane, before, timeout=3):
    """None once the command menu would take /remote-control on Enter, else why not. A claude with
    many commands (plugins, skills) draws its menu a moment after the typed text, after the screen
    has looked steady: so it is waited for, up to timeout."""
    if wait_for(lambda: offers_cmd(screen(pane), before), timeout):
        return None
    t = takes(steady(pane), before)
    why = "its command menu did not offer /remote-control for Enter"
    if t is None:
        return why + " (no menu showed)"
    return why + (f" (it offered: {t[2][:60]})" if t else " (asctl cannot tell which entry Enter takes)")


def bottom(scr, n=10):
    return [plain(l) for l in scr.splitlines() if l.strip()][-n:]


def selected(scr, label):
    """True when the dialog's line for label (its last one near the bottom: an earlier one is a
    quote in the transcript) carries the selection mark ❯."""
    l = next((l for l in reversed(bottom(scr)) if label in l), "")
    return "❯" in l and l.split("❯", 1)[1].strip().lstrip("0123456789. ").startswith(label)


def session(pid):
    return next((s for s in live.read_sessions() if s["pid"] == pid and s["live"]), None)


def status(pid):
    return (session(pid) or {}).get("status")


def dialog_open(pid, scr):
    """The Disconnect dialog, not a quote of it: claude waiting, no input box, at the bottom."""
    return status(pid) == "waiting" and prompt_text(scr) is None and any(DISCONNECT in l for l in bottom(scr))


def guard(s):
    """Why typing into the claude s could go wrong now, or None."""
    now = session(s["pid"])
    if not now:
        return "its claude ended"
    if now["status"] != "idle":
        return f"claude is {now['status']}" if now["status"] != "unknown" else "claude's status is unknown"
    pane = s["pane"]["pane_id"]
    if tmuxctl.pane_in_mode(pane):
        return "its pane is in copy mode"
    t = prompt_text(steady(pane))
    if t is None:
        return "its screen does not show claude's prompt (a dialog or a menu is open?)"
    if t:
        return "something is typed in its prompt"
    return None


def wait_for(cond, timeout, step=0.25):
    end = time.monotonic() + timeout
    while True:
        v = cond()
        if v or time.monotonic() >= end:
            return v
        time.sleep(step)


def settled(pane, quiet=1.5, timeout=5, step=0.15):
    """What is typed in the prompt once it has not changed for quiet seconds, or as it is at
    timeout: a slow claude (a busy host) draws keys one by one well after tmux took them, so a
    read in the middle sees a part of them, none yet, or a half-drawn screen (None)."""
    t, since, end = prompt_text(screen(pane)), time.monotonic(), time.monotonic() + timeout
    while time.monotonic() - since < quiet and time.monotonic() < end:
        time.sleep(step)
        nxt = prompt_text(screen(pane))
        if nxt != t:
            t, since = nxt, time.monotonic()
    return t


def typed_in(s, since):
    """Why asctl must not type or press a key in the pane of claude s: a client attached to its
    tmux session had a key at or after second since (epoch), or tmux did not list them; else None."""
    acts = tmuxctl.client_activity(s["pane"]["session"])
    if acts is None:
        return "tmux did not list the clients of its tmux session"
    if any(a >= since for a in acts):
        return "someone typed in its tmux session just now"
    return None


def take_back(pane, cmd, meanwhile):
    """Remove what asctl typed, only when the prompt holds nothing but (a start of) it, read once
    it stopped changing, and meanwhile() (why not: someone else typed) says None. Keys reach
    claude in order, so every key of cmd comes before the BSpaces: len(cmd) of them leave the
    prompt empty however much of cmd a slow claude had drawn, none of it too."""
    if tmuxctl.pane_in_mode(pane):
        tmuxctl.send_pane(pane, "-X", "cancel")
    t = prompt_text(steady(pane))
    if t != cmd:
        t = settled(pane)
    if t is not None and cmd.startswith(t):
        if meanwhile():
            return "nothing was sent, but what asctl typed is left in its prompt (someone typed there too); check it"
        tmuxctl.send_pane(pane, *["BSpace"] * len(cmd))
        t = "" if wait_for(lambda: prompt_text(screen(pane)) == "", 2) else settled(pane)
    if t == "":
        return "nothing was sent"
    return "nothing was sent, but its prompt now holds " + (repr(t) if t else "something asctl cannot read") + "; check it"


def enter(s, cmd, check):
    """Type cmd into the idle claude s and press Enter, when the screen allows it: None when
    Enter was pressed, else why not (what was typed taken back). check(scr, before): why the
    screen with cmd typed must not take Enter, or None."""
    why = guard(s)
    if why:
        return why
    pid, pane = s["pid"], s["pane"]["pane_id"]
    since = int(time.time()) - TYPED_S
    why = typed_in(s, since)
    if why:
        return why
    before = steady(pane)
    tmuxctl.type_pane(pane, cmd)
    if not wait_for(lambda: prompt_text(screen(pane)) == cmd, 2):
        settled(pane)  # a slow claude still drawing it: until its prompt stops changing
    scr = steady(pane)
    if prompt_text(scr) != cmd:
        why = "its prompt did not show the command as typed"
    elif tmuxctl.pane_in_mode(pane):
        why = "its pane went into copy mode"
    elif status(pid) != "idle":
        why = "claude did not stay idle"
    else:
        why = check(scr, before) or typed_in(s, since)
    if why:
        return why + "; " + take_back(pane, cmd, lambda: typed_in(s, since))
    tmuxctl.send_pane(pane, "Enter")
    return None


def no_menu(scr, before):
    # a menu would take Enter for its own entry; other changes are claude's own (its mode line
    # drops "← 1 agent" once the prompt holds text) or a status line's or plugin's
    return "a command menu opened at its prompt" if entries(scr, before) else None


def rename(s, name, confirm=5):
    """Give the live claude s a new name now with /rename, which claude also sends to its
    claude.ai session (the rc title there): None when done, else why not."""
    if not TITLE.fullmatch(name):
        return "the name has characters asctl does not type (only letters, digits, space, . _ -)"
    # claude's answer, as its transcript records it: the session file alone says nothing when the
    # name is the same (a rename only to send it to claude.ai again), and the screen can hold an
    # older answer (a resumed or branched conversation shows its last turns)
    said = f"<local-command-stdout>Session renamed to: {name}</local-command-stdout>".encode()
    seen = lambda: answers(s["session_id"], said)
    n = seen()
    why = enter(s, f"/rename {name}", no_menu)
    if why:
        return why
    if not wait_for(lambda: seen() > n and (session(s["pid"]) or {}).get("name") == name, confirm):
        return "typed, but claude did not record the new name; check the session"
    return None


def answers(sid, text, tail=1 << 18):
    """How often text is in the end of the conversation's transcript (in every folder that has one)."""
    n = 0
    for path in glob.glob(os.path.expanduser(f"~/.claude/projects/*/{sid}.jsonl")):
        f = live.open_regular(path)
        if f is None:
            continue
        with f:
            f.seek(max(0, os.fstat(f.fileno()).st_size - tail))
            n += f.read(tail).count(text)
    return n


def switch(s, on, title, confirm=10):
    """Turn remote control of the live claude s on or off now: None when done, else why not."""
    if on and not TITLE.fullmatch(title):
        return "its title has characters asctl does not type (only letters, digits, space, . _ -)"
    pid, pane = s["pid"], s["pane"]["pane_id"]
    why = enter(s, f"{CMD} {title}" if on else CMD, no_menu if on else lambda scr, before: offers(pane, before))
    if why:
        return why
    if not on:
        if not wait_for(lambda: dialog_open(pid, screen(pane)), 5):
            return "no Disconnect dialog appeared; check the session"
        for _ in range(3):
            scr = steady(pane)
            if not dialog_open(pid, scr) or selected(scr, DISCONNECT):
                break
            tmuxctl.send_pane(pane, "Up")
            time.sleep(0.3)
        scr = steady(pane)
        if not dialog_open(pid, scr):
            return "its dialog closed before Disconnect was chosen; check the session"
        if not selected(scr, DISCONNECT):
            tmuxctl.send_pane(pane, "Escape")  # the dialog is open: Esc closes it, nothing chosen
            return "could not select Disconnect in its dialog; closed it"
        tmuxctl.send_pane(pane, "Enter")
    if not wait_for(lambda: (session(pid) or {}).get("rc") == on, confirm):
        return "typed, but its session file does not show the change yet; check claude.ai"
    return None
