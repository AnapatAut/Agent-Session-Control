"""Memory: what /proc/meminfo says, and the gate every start passes (plan row 8).

A start needs at least START_PCT of memory available, and must leave at least LEAVE_PCT
after the claude's expected size: its whole pane tree when last measured, else DEFAULT_KB
(a claude with its MCP servers is 350 to 430 MB; 600 MB leaves room). Below WARN_PCT the
dashboard warns. $ASC_MEMINFO names another meminfo file (the tests use a fake one).
"""
import os

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
    need = expected_kb or DEFAULT_KB
    if 100 * avail / total < START_PCT:
        return f"memory: {m['avail_pct']}% available, a start needs {START_PCT}%"
    left = 100 * (avail - need) / total
    if left < LEAVE_PCT:
        return (f"memory: starting it (about {need // 1024} MB) would leave {left:.1f}% available, "
                f"under {LEAVE_PCT}%")
    return ""
