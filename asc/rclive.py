"""Remote control of a running claude, now: asctl types /remote-control into its pane.

The one command asctl types into a running claude, and only when it cannot land anywhere
else: claude idle (its session file), its pane not in copy mode, its prompt empty (read from
the screen, `capture-pane -e`). After typing, before Enter: the prompt shows exactly the
command, claude is still idle, and nothing else opened under the prompt (for on, the screen
under it is as before; for off, the command menu offers /remote-control first). Otherwise what
was typed is taken back, only when the prompt holds nothing but that.
On: `/remote-control <title>` (always the title: without one claude.ai shows a random name;
only letters, digits, space, . _ -, as anything else could open a menu or be read by tmux).
Off: `/remote-control` opens a dialog (Disconnect this session / Show QR code / Continue,
Continue selected, the session status "waiting"): once that dialog is open at the bottom of
the screen, Up until Disconnect is selected, checked, then Enter. Either way the change is
confirmed from the session file (bridgeSessionId). Seen with Claude Code 2.1.316.
"""
import re
import time

from . import live, tmuxctl

ANSI = re.compile(r"\x1b\[[0-9;:?]*[A-Za-z]")
DIM = re.compile(r"\x1b\[2m.*?(?=\x1b\[(?:0|22)?m|$)")  # a placeholder ("Try ...") is dim
RULE = re.compile(r"─{10,}(?: [^─]+ ─*)?")  # the top rule may carry the session's name
TITLE = re.compile(r"[A-Za-z0-9][A-Za-z0-9 ._-]*")
CMD = "/remote-control"
DISCONNECT = "Disconnect this session"


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
    """The index of the input line of claude's one-line input box at the bottom, or None."""
    rules = [i for i, l in enumerate(lines) if RULE.fullmatch(plain(l).strip())]
    return rules[-2] + 1 if len(rules) >= 2 and rules[-1] - rules[-2] == 2 else None


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


def under(scr):
    """The lines under the input box (status lines, or a menu while one is open)."""
    lines = scr.rstrip("\n").split("\n")
    i = box(lines)
    return [] if i is None else [plain(l).rstrip() for l in lines[i + 2:]]


def menu(lines):
    """The command menu's entries among lines under the box ("/name  what it does")."""
    return {l.strip() for l in lines if re.match(r"(?:[❯›>]\s*)?/[A-Za-z]", l.strip())}


def offers_cmd(scr):
    """True when the command menu's first entry (the one Enter takes) is /remote-control itself."""
    first = next((l.strip() for l in under(scr) if l.strip()), "")
    return re.match(re.escape(CMD) + r"(\s|$)", first.lstrip("❯›> ")) is not None


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
    t = prompt_text(screen(pane))
    if t is None:
        return "its screen does not show claude's prompt (a dialog or a menu is open?)"
    if t:
        return "something is typed in its prompt"
    return None


def wait_for(cond, timeout, step=0.25):
    end = time.time() + timeout
    while True:
        v = cond()
        if v or time.time() >= end:
            return v
        time.sleep(step)


def take_back(pane, cmd):
    """Remove what asctl typed, only when the prompt holds nothing but (a start of) it."""
    if tmuxctl.pane_in_mode(pane):
        tmuxctl.send_pane(pane, "-X", "cancel")
    t = prompt_text(screen(pane))
    if t and cmd.startswith(t):
        tmuxctl.send_pane(pane, *["BSpace"] * len(t))
        t = wait_for(lambda: prompt_text(screen(pane)) == "", 2) and ""
    if t == "":
        return "nothing was sent"
    return "nothing was sent, but its prompt now holds " + (repr(t) if t else "something asctl cannot read") + "; check it"


def switch(s, on, title, confirm=10):
    """Turn remote control of the live claude s on or off now: None when done, else why not."""
    if on and not TITLE.fullmatch(title):
        return "its title has characters asctl does not type (only letters, digits, space, . _ -)"
    why = guard(s)
    if why:
        return why
    pid, pane = s["pid"], s["pane"]["pane_id"]
    cmd = f"{CMD} {title}" if on else CMD
    before = under(steady(pane))
    tmuxctl.type_pane(pane, cmd)
    wait_for(lambda: prompt_text(screen(pane)) == cmd, 2)
    scr = steady(pane)
    if prompt_text(scr) != cmd:
        why = "its prompt did not show the command as typed"
    elif tmuxctl.pane_in_mode(pane):
        why = "its pane went into copy mode"
    elif status(pid) != "idle":
        why = "claude did not stay idle"
    elif on and menu(under(scr)) - menu(before):
        # a menu would take Enter for its own entry; other changes there are claude's own (its
        # mode line drops "← 1 agent" once the prompt holds text)
        why = "a menu opened under its prompt"
    elif not on and not offers_cmd(scr):
        why = "its command menu did not offer /remote-control first"
    if why:
        return why + "; " + take_back(pane, cmd)
    tmuxctl.send_pane(pane, "Enter")
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
