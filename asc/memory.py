"""Memory: what /proc/meminfo says, and the gate every start passes (plan row 8).

A start needs at least START_PCT of memory available, and must leave at least LEAVE_PCT
after the claude's expected size: its whole pane tree when last measured, else DEFAULT_KB
(a claude with its MCP servers is 350 to 430 MB; 600 MB leaves room). Below WARN_PCT the
dashboard warns. $ASC_MEMINFO names another meminfo file (the tests use a fake one).

The watcher (asc/watch.py) keeps the samples of the last KEEP_S seconds (memory.json in the state folder):
an automatic start also needs memory steady at START_PCT for STEADY_S (steady), and an automatic
restart after a claude was ended by a signal needs memory pressure seen around then (evidence).
"""
import os
import time

WARN_PCT = 15
START_PCT = 20
LEAVE_PCT = 15
DEFAULT_KB = 600 * 1024


def meminfo():
    m = {}
    try:
        with open(os.environ.get("ASC_MEMINFO") or "/proc/meminfo", encoding="ascii") as f:
            for line in f:
                k, v = line.split(":", 1)
                m[k] = int(v.split()[0])
    except (OSError, ValueError, IndexError):
        pass
    total, avail = m.get("MemTotal", 0), m.get("MemAvailable", 0)
    pct = round(100 * avail / total, 1) if total else 0
    return {"total_kb": total, "avail_kb": avail, "avail_pct": pct, "warn": not total or pct < WARN_PCT,
            "swap_total_kb": m.get("SwapTotal", 0), "swap_free_kb": m.get("SwapFree", 0)}


def gate(expected_kb=None):
    """"" when a claude of expected_kb may start now, else why not."""
    m = meminfo()
    total, avail = m["total_kb"], m["avail_kb"]
    if not total:
        return "memory: /proc/meminfo cannot be read"
    need = expected_kb if type(expected_kb) is int and expected_kb > 0 else DEFAULT_KB
    if 100 * avail / total < START_PCT:
        return f"memory: {m['avail_pct']}% available, a start needs {START_PCT}%"
    left = 100 * (avail - need) / total
    if left < LEAVE_PCT:
        return (f"memory: starting it (about {need // 1024} MB) would leave {left:.1f}% available, "
                f"under {LEAVE_PCT}%")
    return ""


# --- samples (the watcher, every 30 s) --------------------------------------------------------
# Counters that only grow, so a short squeeze between two samples is still seen: PSI "full"
# (time all tasks stalled on memory, µs), pages swapped in and out, the kernel's OOM kills.
# $ASC_PRESSURE, $ASC_VMSTAT and $ASC_BOOT_ID name other files (the tests use fake ones).
STEADY_S = 300      # a start by the watcher or at boot needs START_PCT for this long
GAP_S = 90          # samples further apart than this do not count as a watch (the timer stopped)
KEEP_S = STEADY_S + 2 * GAP_S   # samples are kept this long (by age, so extra runs crowd nothing out)
MAX_SAMPLES = 120   # and at most this many (a run every 4 s)
PSI_US = 100_000    # evidence: tasks stalled on memory for 0.1 s or more between two samples
SWAP_PAGES = 2560   # evidence: 10 MB or more swapped in or out between two samples


def _read(env, default):
    try:
        with open(os.environ.get(env) or default, encoding="ascii") as f:
            return f.read(65536)
    except (OSError, ValueError):
        return ""


def boot_id():
    return _read("ASC_BOOT_ID", "/proc/sys/kernel/random/boot_id").strip()[:64]


def sample():
    """One reading: memory available and the counters, with the time and the boot."""
    m = meminfo()
    psi = None
    for line in _read("ASC_PRESSURE", "/proc/pressure/memory").splitlines():
        if line.startswith("full "):
            for part in line.split():
                if part.startswith("total="):
                    try:
                        psi = int(part[6:])
                    except ValueError:
                        pass
    vm = {}
    for line in _read("ASC_VMSTAT", "/proc/vmstat").splitlines():
        k, _, v = line.partition(" ")
        if k in ("pswpin", "pswpout", "oom_kill"):
            try:
                vm[k] = int(v)
            except ValueError:
                pass
    return {"t": int(time.time()), "boot": boot_id(), "total_kb": m["total_kb"], "avail_kb": m["avail_kb"],
            "avail_pct": m["avail_pct"], "psi_full_us": psi, "pswpin": vm.get("pswpin"),
            "pswpout": vm.get("pswpout"), "oom_kill": vm.get("oom_kill")}


def _ok(s):
    """A sample as sample() writes it (memory.json is read back; nothing odd gets through)."""
    num = lambda v: type(v) in (int, float) and v == v and abs(v) != float("inf")
    return (isinstance(s, dict) and type(s.get("t")) is int and isinstance(s.get("boot"), str)
            and num(s.get("avail_pct"))
            and all(s.get(k) is None or type(s.get(k)) is int for k in ("psi_full_us", "pswpin", "pswpout", "oom_kill")))


def load_samples(d=None):
    """The kept samples, oldest first; a file that does not read gives none (no evidence, no
    steady memory: nothing automatic happens until new samples come in)."""
    from . import registry
    p = os.path.join(d or registry.state_dir(), "memory.json")
    raw = registry.read_private(p)
    return sorted((s for s in raw if _ok(s)), key=lambda s: s["t"]) if isinstance(raw, list) else []


def add_sample(s, d=None):
    from . import registry
    keep = [x for x in load_samples(d)
            if x["boot"] == s["boot"] and s["t"] - KEEP_S <= x["t"] <= s["t"]][-(MAX_SAMPLES - 1):] + [s]
    registry.write_private(os.path.join(d or registry.state_dir(), "memory.json"), keep)
    return keep


def steady(samples, now=None, pct=START_PCT, span=STEADY_S):
    """"" when memory has stayed at pct or more for span seconds (samples of this boot, none
    further apart than GAP_S, the last one recent), else why not."""
    now = now or time.time()
    boot = boot_id()
    xs = [s for s in samples if s["boot"] == boot and s["t"] <= now]
    if not xs or now - xs[-1]["t"] > GAP_S:
        return "memory: no recent sample (is the watcher running?)"
    win = [s for s in xs if s["t"] >= now - span]
    before = [s for s in xs if s["t"] < now - span]
    if not before or win and win[0]["t"] - before[-1]["t"] > GAP_S:
        return f"memory: watched for under {span // 60} min"
    chain = [before[-1]] + win
    if any(b["t"] - a["t"] > GAP_S for a, b in zip(chain, chain[1:])):
        return "memory: a gap in the samples"
    low = min(s["avail_pct"] for s in chain)
    if low < pct:
        return f"memory: down to {low}% available in the last {span // 60} min (a start needs {pct}% steady)"
    return ""


def evidence(samples, t_end):
    """Memory pressure around t_end (when a claude ended), from the samples just before and just
    after it: (True, why), (False, what was seen) or (None, why it cannot be told)."""
    boot = boot_id()
    xs = [s for s in samples if s["boot"] == boot]
    # strictly before and after: a sample of the same second may have been taken on either side
    a = next((s for s in reversed(xs) if s["t"] < t_end), None)
    b = next((s for s in xs if s["t"] > t_end), None)
    if a is None or b is None or t_end - a["t"] > GAP_S or b["t"] - t_end > GAP_S:
        return None, "no memory samples around that time"
    why = []
    if a["avail_pct"] < WARN_PCT or b["avail_pct"] < WARN_PCT:
        why.append(f"{min(a['avail_pct'], b['avail_pct'])}% available")
    grew = lambda k: a.get(k) is not None and b.get(k) is not None and b[k] - a[k]
    if (grew("oom_kill") or 0) > 0:
        why.append(f"{grew('oom_kill')} OOM kill(s)")
    if (grew("psi_full_us") or 0) >= PSI_US:
        why.append(f"stalled on memory {grew('psi_full_us') / 1e6:.1f} s")
    swap = (grew("pswpin") or 0) + (grew("pswpout") or 0)
    if swap >= SWAP_PAGES:
        why.append(f"{swap * 4 // 1024} MB swapped")
    if why:
        return True, ", ".join(why)
    return False, f"no memory pressure seen ({a['avail_pct']}% then {b['avail_pct']}% available)"
