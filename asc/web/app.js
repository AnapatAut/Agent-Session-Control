// The dashboard page over its API (GET api/state, GET api/past?q=, GET api/events?id=, POST
// api/action), in the look
// of the serve dashboard: a list of sessions, and a details sheet for each where every action is.
// Every value from the server is user text (titles, folders): it is set as textContent only.
"use strict";
const token = document.querySelector('meta[name="asctl-token"]').content;
const $ = (id) => document.getElementById(id);
const STALE_MS = 20000;  // no good update for this long: the warning triangle
const WATCH_LATE_S = 300;  // the watcher runs every 30 s: no run for this long, and it has stopped
const HIST_FIRST = 5, HIST_PAGE = 50;  // a sheet's history: the newest lines, then this many more at a time

let S = null;            // the last state from the server
let past = [];           // past conversations for the search box
let filter = "all";      // the chip pressed
let sheetOf = null;      // {kind: "fav" | "active" | "past", key}, while the sheet is open
let sheetSig = "";       // the data the open sheet was drawn from: redrawn only when it changes
const pending = new Set();  // ids with an action running: their controls stay disabled across redraws
const hist = new Map();     // id4: its events (newest first), for its open sheet
const histOpen = new Map(); // id4: how many lines of its history are open (after Show more)
let histV = null;           // the event log's version (state.events_v) the open sheet's history is from
let lastOk = Date.now(), lastOkTime = null;

function el(tag, text, cls) {
  const e = document.createElement(tag);
  if (text !== undefined && text !== null && text !== "") e.textContent = String(text);
  if (cls) e.className = cls;
  return e;
}
function kids(parent, ...children) { for (const c of children) if (c) parent.append(c); return parent; }

// --- formatting ------------------------------------------------------------------------------
function bytes(n) {
  return n >= 1 << 20 ? size(n / 1024) : Math.max(1, Math.round(n / 1024)) + " KB";
}
function size(kb) {
  if (!kb) return "";
  return kb >= 1024 * 1024 ? (kb / 1024 / 1024).toFixed(1) + " GB" : Math.round(kb / 1024) + " MB";
}
function tilde(p) {
  const h = S && S.home;
  if (!p) return "";
  return h && (p === h || p.startsWith(h + "/")) ? "~" + p.slice(h.length) : p;
}
// times on the 24-hour clock, whatever the phone's locale
const pad = (n) => String(n).padStart(2, "0");
function hm(d) { return pad(d.getHours()) + ":" + pad(d.getMinutes()); }
function hms(d) { return hm(d) + ":" + pad(d.getSeconds()); }
// "4 Nov 2026, 11:27:42"
function stamp(d) { return d.toLocaleDateString("en-GB", { day: "numeric", month: "short", year: "numeric" }) + ", " + hms(d); }
function full(ts) {
  if (!ts) return "";
  const d = new Date(ts * 1000);
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${hms(d)}`;
}
function when(ts) {
  if (!ts) return "";
  const d = new Date(ts * 1000), now = new Date();
  const day = (x) => new Date(x.getFullYear(), x.getMonth(), x.getDate()).getTime();
  const diff = Math.round((day(now) - day(d)) / 86400000);
  if (diff === 0) return "today " + hm(d);
  if (diff === 1) return "yesterday " + hm(d);
  return d.toLocaleDateString([], { day: "numeric", month: "short", year: d.getFullYear() === now.getFullYear() ? undefined : "numeric" });
}
// What claude itself last wrote: its status, why it waits, and since when (to the second).
function statusText(x) {
  if (!x.status) return "";
  const [label] = STATUS[x.status] || STATUS.unknown;
  // what claude waits for (a prompt it names no reason for: a question or a command to approve),
  // or what it still runs while idle
  const why = x.waiting_for || x.task || (x.status === "waiting" ? "a prompt in its pane" : "");
  return label + (why ? " (" + why + ")" : "") +
    (x.status_at ? " since " + hms(new Date(x.status_at * 1000)) : "");
}
function ago(ts) {
  const s = Date.now() / 1000 - ts;
  if (s < 3600) return Math.max(1, Math.round(s / 60)) + " min ago";
  if (s < 86400) return Math.round(s / 3600) + " h ago";
  if (s < 86400 * 14) { const n = Math.round(s / 86400); return n + (n === 1 ? " day ago" : " days ago"); }
  return when(ts);
}
const STATUS = { busy: ["Working", "busy"], idle: ["Idle", "idle"], waiting: ["Waiting for you", "wait"],
                 shell: ["Shell", "idle"], unknown: ["Running", "idle"] };

// What asctl boot says the next favorite it brings back waits for (asc/boot.py), in words.
function bootWhy(why) {
  if (/^memory: (watched for under|down to|[0-9.]+% available, a start needs)/.test(why))
    return "Starts once memory has stayed under 80% used for 5 min.";
  if (why.startsWith("network")) return "Starts once claude.ai answers (at most 2 min).";
  if (why.startsWith("pause") || !why) return "Starts in a moment.";
  why = why.replace(/^memory: /, "");
  return why.charAt(0).toUpperCase() + why.slice(1) + ".";
}

// What a favorite's state means on the page: which list, the dot, a label, why (on the row and
// in the sheet) and a hint (the row only: the sheet says it in Status).
function look(e) {
  const st = e.state || "";
  const code = (st.match(/\((\d+)\)/) || [])[1];
  if (st === "on") {
    if (e.claudes > 1) return { group: "attention", dot: "bad", label: e.claudes + " claudes",
      why: `${e.claudes} claudes run in its tmux session; Off would end them all.` };
    const [label, dot] = STATUS[e.status] || STATUS.unknown;
    const hint = e.status === "waiting"
      ? (e.waiting_for || "A prompt in its pane") + (e.status_at ? ", since " + hm(new Date(e.status_at * 1000)) : "") : "";
    return { group: "on", dot, label, hint };
  }
  if (st === "duplicate") return { group: "attention", dot: "bad", label: "Duplicate",
    why: "Two claudes hold this session or its name. asctl does nothing about it by itself." };
  if (st.startsWith("on (outside")) return { group: "attention", dot: "wait", label: "Running outside its tmux",
    why: `Its claude runs, but not in tmux session ${e.tmux}.` };
  if (st.startsWith("ended by a signal")) return { group: "attention", dot: "bad", label: "Ended unexpectedly",
    why: `Claude was ended by a signal (${code}); its tmux session is still up. Turn it on to start claude again.` };
  if (st.startsWith("tmux up")) return { group: "attention", dot: "wait", label: "Claude ended",
    why: `Claude ended${code ? " (exit " + code + ")" : ""}; its tmux session is still up.` };
  const boot = S && S.boot ? S.boot.todo : [];
  if (boot.includes(e.id4) && !isOn(e)) return { group: "attention", dot: "wait", label: "Coming back",
    why: boot.find((id) => S.favorites.some((f) => f.id4 === id && !isOn(f))) === e.id4 ? bootWhy(S.boot.why)
                                                                                    : "Waits its turn: one start at a time." };
  if (st === "off (wanted on)") return { group: "attention", dot: "wait", label: "Off, wanted on",
    why: "It should be on but is not: a reboot without resurrect, or a start that failed." };
  return { group: "off", dot: "", label: e.last_off ? "off since " + when(e.last_off) : "off",
           why: e.resurrect ? "Off, so a reboot won't bring it back." : "", whyCls: "wait" };
}
const isOn = (e) => e.state === "on" || e.state === "duplicate" || (e.state || "").startsWith("on (");

// --- the list --------------------------------------------------------------------------------
// Rows are kept by key across refreshes (every 5 s): one whose content is unchanged is not touched,
// and a changed one keeps its element, so a tap that spans a refresh still reaches its row.
const rows = new Map(), used = new Set();
function rowEl(key, open, dotCls, name, id, sub, meta, note, why, whyCls) {
  const r = el("div", null, "row");
  const nm = el("div", name, "nm");
  if (id) nm.append(el("span", "#" + id, "id"));
  const cwd = el("div", sub, "cwd mono");
  cwd.title = sub;  // the whole line on hover when it ends in ...
  const head = kids(el("div", null, "head"), el("span", null, "dot " + dotCls), kids(el("div"), nm, cwd));
  r.append(head, kids(el("div", null, "meta"), ...meta), el("div", note, "note"), el("span", "›", "sw"));
  if (why) r.append(el("div", why, "why " + (whyCls || "")));
  r.setAttribute("aria-label", name + (id ? " " + id : ""));
  used.add(key);
  const sig = r.outerHTML, old = rows.get(key);  // outerHTML is only read, to compare
  if (old) {
    if (old.sig !== sig) { old.el.replaceChildren(...r.childNodes); old.el.setAttribute("aria-label", r.getAttribute("aria-label")); old.sig = sig; }
    return old.el;
  }
  r.tabIndex = 0;
  r.setAttribute("role", "button");
  r.dataset.fk = key;
  r.addEventListener("click", open);
  // Enter on keydown, Space on keyup, as a native button: a keyup after the sheet moved the focus
  // must not press the sheet's close button
  r.addEventListener("keydown", (ev) => { if (ev.key === "Enter") { ev.preventDefault(); open(); } else if (ev.key === " ") ev.preventDefault(); });
  r.addEventListener("keyup", (ev) => { if (ev.key === " ") { ev.preventDefault(); open(); } });
  rows.set(key, { el: r, sig });
  return r;
}
// Forget the rows of these lists that the last render did not use.
function sweepRows(...prefixes) {
  for (const k of [...rows.keys()]) if (prefixes.some((p) => k.startsWith(p)) && !used.has(k)) rows.delete(k);
  for (const k of [...used]) if (prefixes.some((p) => k.startsWith(p))) used.delete(k);
}
function tag(text, cls) { return el("span", text, "tag " + (cls || "")); }
// remote control: live (lime), on but not live in a running claude (amber), on for its next start (grey
// chip; the button is off while the session is)
function rcState(e) {
  if (!isOn(e)) return e.rc ? "set" : "";
  return e.rc_live ? "live" : e.rc ? "down" : "";
}
const RC_SAYS = { live: "Remote control live", down: "Remote control on, not live now", set: "Remote control on from its next start" };
// Moving a row or rebuilding a chip drops the keyboard focus to the page: put it back.
function keepFocus(draw) {
  const fk = document.activeElement && document.activeElement.dataset ? document.activeElement.dataset.fk : null;
  draw();
  if (fk && document.activeElement === document.body) {
    const t = document.querySelector(`[data-fk="${CSS.escape(fk)}"]`);
    if (t) t.focus({ preventScroll: true });
  }
}

// claude's permission modes, as the page names them
const MODE = { auto: "Auto", manual: "Manual", default: "Manual", acceptEdits: "Accept edits", dontAsk: "Don't ask",
               plan: "Plan", bypassPermissions: "Skip permissions" };
const MODE_TAG = { manual: "asks first", default: "asks first", acceptEdits: "accept edits", dontAsk: "don't ask",
                   plan: "plan" };  // skip has no tag either (not on the main list)

function favRow(e) {
  const l = look(e);
  const meta = [el("span", l.label, "st " + (l.dot || ""))];
  if (isOn(e) && e.mem_kb) meta.push(tag(size(e.mem_kb)));
  const rs = rcState(e);
  if (rs) { const t = tag("rc", "rc " + rs); t.title = RC_SAYS[rs]; meta.push(t); }
  if (e.resurrect) meta.push(tag("↻ resurrect"));
  const m = MODE_TAG[isOn(e) ? e.mode_used : e.mode_next];  // auto has no tag
  if (m) meta.push(tag(m));
  return rowEl("fav:" + e.id4, () => openSheet("fav", e.id4), l.dot, e.name, e.id4, tilde(e.cwd), meta, "", l.why || l.hint,
               l.whyCls || (l.dot === "wait" ? "wait" : ""));
}

function section(title, pillCls, rows) {
  if (!rows.length) return [];
  const h = kids(el("div", title, "sect"), el("span", rows.length, "pill " + pillCls));
  return [h, kids(el("div", null, "list"), ...rows)];
}

function shown(e) {
  if (filter === "on") return isOn(e);
  if (filter === "off") return !isOn(e);
  if (filter === "busy") return isOn(e) && e.status === "busy";
  return true;
}

function render() { keepFocus(draw); }
function draw() {
  const s = S;
  $("me").textContent = s.login.split("@")[0];  // the name only; the whole login on hover
  $("me").title = s.login;
  $("host").textContent = location.hostname;
  $("upd").textContent = "Updated " + stamp(new Date(s.time * 1000));

  // memory
  const m = s.memory, used = m.total_kb ? 100 - m.avail_pct : 0;
  $("mem").classList.toggle("warn", m.warn);
  $("mem-pct").textContent = m.total_kb ? Math.round(used) + "% used" : "unknown";
  $("mem-used").style.width = Math.max(0, Math.min(100, used)) + "%";
  const onKb = s.favorites.filter(isOn).reduce((a, e) => a + (e.mem_kb || 0), 0);
  $("mem-det").replaceChildren(document.createTextNode(`${size(m.total_kb - m.avail_kb)} of ${size(m.total_kb)} used`), el("br"),
    document.createTextNode(`${s.on} favorite${s.on === 1 ? "" : "s"} on, using ${size(onKb) || "0 MB"}`));

  const warn = [];
  if (m.warn) warn.push("Memory is over 85% used; a start needs it at most 80% used.");
  if (!s.server) warn.push("No tmux server is running.");
  if (s.unknown_files) warn.push(`${s.unknown_files} session file(s) in a format asctl does not know.`);
  $("banner").hidden = !warn.length;
  $("banner").textContent = warn.join(" ");
  // after a reboot, no setup, a watcher that stopped: each only while it is so
  const notes = [], name = (id) => (s.favorites.find((e) => e.id4 === id) || {}).name || id;
  // asctl boot's list, less any favorite on by now (by hand) or gone
  const back = (s.boot ? s.boot.todo : []).filter((id) => s.favorites.some((e) => e.id4 === id && !isOn(e)));
  if (back.length) notes.push(el("div", `Bringing back ${back.length} favorite${back.length === 1 ? "" : "s"} ` +
                                        `(${back.map(name).join(", ")}), one at a time.`, "notice info"));
  if (s.setup === false) notes.push(el("div", "Not set up: favorites won't come back after a reboot. Run asctl setup.", "notice"));
  else if (s.setup && !s.watch_at) notes.push(el("div", "The watcher has not run yet: ended claudes go unnoticed. Check asctl-watch.timer.", "notice"));
  else if (s.setup && s.time - s.watch_at > WATCH_LATE_S)
    notes.push(el("div", `Watcher stopped ${Math.round((s.time - s.watch_at) / 60)} min ago: ended claudes go unnoticed. Check asctl-watch.timer.`, "notice"));
  const nsig = notes.map((x) => x.className + x.textContent).join("|");
  if ($("notes").dataset.sig !== nsig) { $("notes").replaceChildren(...notes); $("notes").dataset.sig = nsig; }

  // settings: the switch is made once and then only updated, so it keeps a tap and the focus
  const ar = !!(s.settings && s.settings.auto_restart);
  if (!$("opts").firstChild)
    $("opts").append(opt("Restart after an out-of-memory kill",
      "Starts a favorite again after its claude is killed under memory pressure. At most once per 30 min.",
      sw(ar, "Restart after an out-of-memory kill", () => autoRestart(!(S.settings && S.settings.auto_restart)))));
  const arb = $("opts").querySelector("[role=switch]");
  arb.setAttribute("aria-checked", String(ar));
  if (pending.has("auto_restart")) arb.disabled = true;

  // chips
  const n = { all: s.favorites.length, on: s.favorites.filter(isOn).length };
  n.off = n.all - n.on;
  n.busy = s.favorites.filter((e) => isOn(e) && e.status === "busy").length;
  $("chips").replaceChildren(...[["all", "All"], ["on", "On"], ["off", "Off"], ["busy", "Busy"]].map(([k, t]) => {
    const c = kids(el("button", t, "chip"), el("span", n[k], "n"));
    c.type = "button";
    c.dataset.fk = "chip:" + k;
    c.setAttribute("aria-pressed", String(filter === k));
    c.addEventListener("click", () => { filter = k; render(); });
    return c;
  }));

  // sessions
  const groups = { attention: [], on: [], off: [] };
  for (const e of s.favorites) if (shown(e)) groups[look(e).group].push(favRow(e));
  const parts = [...section("Needs attention", "red", groups.attention), ...section("On", "", groups.on),
                 ...section("Off", "grey", groups.off)];
  if (!s.favorites.length) parts.push(el("div", "No favorites yet: open a running claude or a past conversation below and favorite it.", "none"));
  else if (!parts.length) parts.push(el("div", "None.", "none"));
  const act = s.active.map((x) => {
    const [label, dot] = STATUS[x.status] || STATUS.unknown;
    return rowEl("active:" + x.pid, () => openSheet("active", x.pid), x.duplicate ? "bad" : dot, x.name || "Unnamed claude", "",
      tilde(x.cwd) + (x.tmux ? " · tmux " + x.tmux : " · not in tmux"),
      [el("span", x.duplicate ? "Duplicate" : label, "st " + (x.duplicate ? "bad" : dot))], "", "", "");
  });
  parts.push(...section("Running, not favorited", "grey", act));
  $("lists").replaceChildren(...parts);
  sweepRows("fav:", "active:");

  // memory in use, by whom (adds up to the memory card's "used"), then this user's biggest
  // processes: names and sizes only
  const proc = (name, kb, cls) => kids(el("div", null, "proc" + (cls ? " " + cls : "")), el("span", name), el("span", size(kb), "mono"));
  $("use").replaceChildren(proc("You", s.top.mine_kb), proc("Other users and the system", s.top.others_kb),
    proc("In use", s.top.mine_kb + s.top.others_kb, "sum"));
  $("top").replaceChildren(...s.top.mine.map((p) => proc(p.name, p.mem_kb)));

  if (sheetOf) renderSheet();
}

function renderPast() { keepFocus(drawPast); }
function drawPast() {
  $("past").replaceChildren(...past.map((c) => rowEl("past:" + c.session_id, () => openSheet("past", c.session_id), "blank", c.title || "Untitled", "",
    tilde(c.cwd), [el("span", ago(c.mtime))], "", "", "")));
  sweepRows("past:");
}

// --- our own confirm and prompt ---------------------------------------------------------------
// The browser's own confirm and prompt boxes look like another site's and name it in their title. This
// card resolves true/false for a question, or the text/null with input: {value, check(v) -> error}.
function ask({ title, text = "", ok = "OK", danger = false, input = null }) {
  if (ask.cancel) ask.cancel();
  return new Promise((done) => {
    const inp = $("dlg-in"), okb = $("dlg-ok"), nob = $("dlg-no"), err = $("dlg-err");
    $("dlg-t").textContent = title;
    $("dlg-m").textContent = text;
    $("dlg-m").hidden = !text;
    okb.textContent = ok;
    okb.className = "btn " + (danger ? "dz" : "p");
    inp.hidden = !input;
    if (input) { inp.value = input.value || ""; inp.setAttribute("aria-label", title); }
    const check = () => {
      const why = input ? input.check(inp.value) : "";
      err.textContent = why || "";
      okb.disabled = !!why;
      return !why;
    };
    check();
    const prev = document.activeElement;
    // everything else out of reach (the sheet too); put back as it was
    const outside = [...document.body.children].filter((c) => c.id !== "dscrim" && c.id !== "toast");
    const was = outside.map((c) => c.inert);
    for (const c of outside) c.inert = true;
    $("dscrim").hidden = false;
    const finish = (v) => {
      $("dscrim").hidden = true;
      outside.forEach((c, i) => { c.inert = was[i]; });
      document.removeEventListener("keydown", key, true);
      okb.onclick = nob.onclick = inp.oninput = $("dscrim").onclick = null;
      ask.cancel = null;
      if (prev && prev.isConnected) prev.focus({ preventScroll: true });
      done(v);
    };
    const no = () => finish(input ? null : false);
    // a second tap of the one that opened it (Turn off, then Force off at the same spot) is not a yes
    const opened = performance.now();
    const yes = () => { if (performance.now() - opened > 400 && check()) finish(input ? inp.value : true); };
    const key = (ev) => {
      if (ev.key === "Escape") { ev.preventDefault(); ev.stopPropagation(); no(); }
      else if (ev.key === "Enter" && ev.target === inp) { ev.preventDefault(); yes(); }
    };
    document.addEventListener("keydown", key, true);  // before the sheet's Escape
    okb.onclick = yes;
    nob.onclick = no;
    inp.oninput = check;
    $("dscrim").onclick = (ev) => { if (ev.target === $("dscrim")) no(); };
    ask.cancel = no;
    // a risky OK never has the focus first: Enter or a stray tap must not confirm it
    (input ? inp : danger ? nob : okb).focus();
  });
}

// --- talking to the server -------------------------------------------------------------------
function toast(text) {
  const t = $("toast");
  t.textContent = text;
  t.hidden = false;
  clearTimeout(toast.timer);
  toast.timer = setTimeout(() => { t.hidden = true; }, 5000);
}

// One action; returns {ok, out|error}. Off refused as busy, and On refused for memory, offer the
// forced one after a confirm (never automatic).
async function act(body) {
  const id = body.id || body.ref;
  pending.add(id);
  if (sheetOf) renderSheet();  // every control of this session off until the answer
  let j;
  try {
    const r = await fetch("api/action", {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-Asctl-Token": token },
      body: JSON.stringify(body),
    });
    j = await r.json().catch(() => ({ ok: false, error: "HTTP " + r.status }));
  } catch (e) {
    j = { ok: false, error: "the dashboard did not answer (" + e.message + ")" };
  }
  if (!j.ok && body.action === "off" && !body.force && /busy/.test(j.error || "") &&
      await ask({ title: `${body.tmux} is busy`, text: j.error + "\n\nForce it off anyway? Everything in it ends.",
                  ok: "Force off", danger: true })) {
    return act({ ...body, force: true });
  }
  if (!j.ok && body.action === "on" && !body.force_memory && /^memory:/.test(j.error || "") &&
      await ask({ title: "Memory is short", text: `${j.error}\n\nStart ${body.tmux} anyway? earlyoom may then end other sessions.`,
                  ok: "Start anyway", danger: true })) {
    return act({ ...body, force_memory: true });
  }
  pending.delete(id);
  toast(j.ok ? (j.out || "Done.") : "Refused: " + (j.error || "unknown error"));
  await refresh();
  if (sheetOf) renderSheet();  // also when the state did not change
  return j;
}

async function refresh() {
  const rf = $("rf");
  rf.classList.add("spin");
  let fresh = null;
  try {
    const r = await fetch("api/state", { cache: "no-store" });
    if (r.ok) fresh = await r.json();
  } catch (e) { /* the network: the next tick tries again; the triangle tells after STALE_MS */ }
  rf.classList.remove("spin");
  if (fresh) {
    S = fresh;
    lastOk = Date.now();
    lastOkTime = new Date();
    render();  // outside the try: a bug here shows in the console, never as "not updating"
    if (sheetOf && sheetOf.kind === "fav" && S.events_v !== histV) loadHist(sheetOf.key);  // only when the log changed
  }
  staleCheck();
}

// The one page-wide setting (its own function: draw() has an act of its own, the active rows).
async function autoRestart(on) {
  await act({ action: "auto_restart", id: "auto_restart", on });
  // the switch was disabled while it ran, which dropped the focus: back to it once enabled again
  const b = $("opts").querySelector("[role=switch]");
  setTimeout(() => { if (b && document.activeElement === document.body) b.focus({ preventScroll: true }); });
}

// A favorite's events for its open sheet (asctl keeps its last 200: one request has them all).
async function loadHist(id4) {
  const v = S ? S.events_v : null;
  let got = null;
  try {
    const r = await fetch("api/events?id=" + encodeURIComponent(id4), { cache: "no-store" });
    if (r.ok) got = (await r.json()).events;
  } catch (e) { /* the network: the next refresh tries again */ }
  if (!Array.isArray(got) || !sheetOf || sheetOf.kind !== "fav" || sheetOf.key !== id4) return;
  hist.set(id4, got);
  histV = v;
  renderSheet();
}

async function loadPast() {
  let got = null;
  try {
    const r = await fetch("api/past?q=" + encodeURIComponent($("q").value), { cache: "no-store" });
    if (r.ok) got = (await r.json()).past;
  } catch (e) { /* the network: tried again on the next search */ }
  if (got) { past = got; renderPast(); }
}

function staleCheck() {
  const stale = document.visibilityState === "visible" && Date.now() - lastOk > STALE_MS;
  $("nup").hidden = !stale;
  if (!stale) { $("stale").hidden = true; $("nup").setAttribute("aria-expanded", "false"); }
}
$("nup").addEventListener("click", () => {
  const open = $("stale").hidden;
  $("stale").hidden = !open;
  $("nup").setAttribute("aria-expanded", String(open));
  $("stale").textContent = "Not updating since " + (lastOkTime ? hms(lastOkTime) : "the page opened") +
    " (the dashboard is down, or the login expired). The list shows the last data.";
});

// --- the details sheet -----------------------------------------------------------------------
function sw(checked, label, onClick, off) {
  const b = el("button", null, "switch");
  b.disabled = !!off;
  b.type = "button";
  b.setAttribute("role", "switch");
  b.setAttribute("aria-checked", String(checked));
  b.setAttribute("aria-label", label);
  b.addEventListener("click", async () => { b.disabled = true; await onClick(); b.disabled = false; });
  return b;
}
function opt(title, desc, control) {
  return kids(el("div", null, "opt"), kids(el("div"), el("div", title, "t"), desc ? el("div", desc, "d") : null), control);
}
function btn(text, cls, onClick, off) {
  const b = el("button", text, "btn " + (cls || ""));
  b.disabled = !!off;
  b.type = "button";
  b.addEventListener("click", async () => { b.disabled = true; try { await onClick(); } finally { b.disabled = false; } });
  return b;
}
function powerIcon() {
  const ns = "http://www.w3.org/2000/svg", s = document.createElementNS(ns, "svg");
  s.setAttribute("viewBox", "0 0 24 24");
  s.setAttribute("aria-hidden", "true");
  for (const d of ["M12 3.5v8", "M6.6 7.4a7.5 7.5 0 1 0 10.8 0"]) {
    const p = document.createElementNS(ns, "path");
    p.setAttribute("d", d);
    s.append(p);
  }
  return s;
}
function kv(pairs) {
  const d = el("dl", null, "kv");
  for (const [k, v] of pairs) {
    if (v === undefined || v === null || v === "") continue;
    const dd = el("dd", v, k === "tmux" || k === "Session id" ? "mono" : "");
    dd.dataset.k = k;
    d.append(el("dt", k), dd);
  }
  return d;
}

// --- a favorite's history in its sheet: in words, with no pids, session ids or whole paths ---
const EV_KIND = { on: "Turned on", off: "Turned off", restart: "Restarted", restarted: "Restarted after an out-of-memory kill",
  ended: "Claude ended", refused: "Refused", failed: "Failed", followed: "Followed", rename: "Renamed", resurrect: "Resurrect",
  rc: "Remote control", fav: "Favorited", mode: "Permissions", waiting: "Waiting", duplicate: "Two claudes", setting: "Setting" };
const EV_BY = { cli: "asctl", page: "page", watch: "watcher", boot: "boot" };
const UUID_G = /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/gi;
function evLabel(x) {
  const t = x.text || "";
  if (x.kind === "resurrect" || x.kind === "rc") {
    const m = t.match(/: (?:rc|resurrect) (on|off)\b/);
    return EV_KIND[x.kind] + (m ? " " + m[1] : "");
  }
  if (x.kind === "followed") return /moved to /.test(t) ? "Folder moved" : "New conversation";
  if (x.kind === "rename") {
    const m = t.match(/^renamed(?: to|:) ([a-z0-9-]+?)(?:-\d{4})?(?:[;,. ]|$)/);
    return "Renamed" + (m ? " to " + m[1] : "");
  }
  return EV_KIND[x.kind] || x.kind;
}
// The why of a refusal, a failure or a wait, short: its prefixes (on:, boot:, NAME-ID:) and
// pids, session ids, tmux commands and the home folder taken out.
function evDetail(x) {
  let t = x.text || "";
  if (x.kind === "followed") {
    const m = t.match(/moved to (.+?) \(was /);
    if (m) return "Now " + tilde(m[1]);
    return /chose it at start/.test(t) ? "Claude started in another conversation" : "A branch, a rewind, /clear or /resume inside claude";
  }
  const named = x.kind === "rc" && !/: rc (on|off)\b/.test(t);  // its name not sent to claude.ai, and why
  if (!named && !["refused", "failed", "waiting", "ended", "restarted", "duplicate", "mode"].includes(x.kind)) return "";
  if (x.kind === "ended") t = t.split(";")[0].replace(/^claude ended, /, "");
  t = t.replace(/^(?:(?:boot|watch|on|off|rename|rc|resurrect|mode|forget|restart|fav|note|start again after exit \d+)(?: [\w.-]+)?: |[a-z0-9][a-z0-9-]*-\d{4}: )+/, "");
  t = t.replace(/^\d{4} is being started or stopped by another asctl; try again$/, "busy with another start or stop");
  t = t.replace(/ \(see: [^)]*\)/g, "").replace(/ \((?:pids? )?[\d, ]{3,}\)/g, "").replace(/\bclaude \d{3,}\b/g, "claude")
       .replace(UUID_G, "…");
  if (S && S.home) t = t.split(S.home + "/").join("~/");
  t = t.charAt(0).toUpperCase() + t.slice(1);
  return t.length > 160 ? t.slice(0, 159) + "…" : t;
}
function evDay(t) {
  const w = when(t);
  if (w.startsWith("today ")) return "Today";
  if (w.startsWith("yesterday ")) return "Yesterday";
  return new Date(t * 1000).toLocaleDateString([], { weekday: "short", day: "numeric", month: "short" });
}
// One line per run of the same event (a start retried and refused 8 times: "Refused ×8").
function evFold(evs) {
  const out = [];
  for (const x of evs) {
    const g = out[out.length - 1], key = x.kind + "|" + x.by + "|" + evLabel(x) + "|" + evDetail(x);
    if (g && g.key === key) { g.n++; g.first = x.t; } else out.push({ key, x, n: 1, first: x.t });
  }
  return out;
}
function historyBlock(e) {
  const evs = hist.get(e.id4);
  if (!evs) return [];  // not loaded yet: it comes with the next answer
  const lab = el("span", "HISTORY", "lab");
  if (evs.length) lab.append(el("span", " · " + evs.length, "n"));
  const box = el("div", null, "hist");
  if (!evs.length) box.append(el("div", "Nothing logged for it yet.", "none"));
  const groups = evFold(evs), open = histOpen.get(e.id4) || 0, n = open || HIST_FIRST;
  let day = "";
  for (const g of groups.slice(0, n)) {
    const d = evDay(g.x.t);
    if (d !== day) { box.append(el("div", d, "day")); day = d; }
    const bad = g.x.kind === "failed" || g.x.kind === "ended", warn = g.x.kind === "refused" || g.x.kind === "waiting";
    const k = el("div", evLabel(g.x) + (g.n > 1 ? " ×" + g.n : ""), "k" + (bad ? " bad" : warn ? " wait" : ""));
    k.append(el("small", " · " + (EV_BY[g.x.by] || g.x.by)));
    const det = [evDetail(g.x), g.n > 1 ? "from " + hm(new Date(g.first * 1000)) : ""].filter(Boolean).join(" · ");
    const row = kids(el("div", null, "ev"), el("span", hm(new Date(g.x.t * 1000)), "w"), k, det ? el("div", det, "d") : null);
    row.title = full(g.x.t);
    box.append(row);
  }
  const more = (text, to) => {
    const b = el("button", text, "all");
    b.type = "button";
    b.addEventListener("click", () => { if (to) histOpen.set(e.id4, to); else histOpen.delete(e.id4); renderSheet(); });
    return b;
  };
  if (groups.length > n) box.append(more(`Show more (${groups.length - n} left)`, open ? n + HIST_PAGE : HIST_PAGE));
  if (open) box.append(more("Show less", 0));
  return [lab, box];
}

function favSheet(e) {
  const l = look(e), ref = { id: e.id4, tmux: e.tmux }, on = isOn(e), wait = pending.has(e.id4);
  const out = [el("h2", e.name), el("div", "#" + e.id4 + " · " + tilde(e.cwd), "s2 mono")];
  // the two actions used most: power (lime on, red off) and rc (colored as rcState)
  // rc shows the live state of a running claude (a tap on amber tries again), else the setting
  const rs = rcState(e), rcOn = rs === "live" || rs === "set";
  // off: grey and not a control (its setting still applies at the next start; switch it once on)
  const rcb = btn("rc", "rcb " + (on ? rs : ""), () => act({ action: "rc", on: !rcOn, ...ref }), wait || !on);
  rcb.setAttribute("aria-pressed", String(on && rcOn));
  rcb.setAttribute("aria-label", on ? (RC_SAYS[rs] || "Remote control off") + (rcOn ? ": turn it off" : ": turn it on")
                                    : "Remote control: turn the session on first");
  rcb.title = on ? RC_SAYS[rs] || "Remote control off" : "Turn the session on first";
  const pwb = btn("", "pw " + (on ? "on" : "off"), async () => {
    if (on) {
      if (!await ask({ title: `Turn ${e.tmux} off?`, text: `What runs in its tmux session ends.`, ok: "Turn off", danger: true })) return;
      await act({ action: "off", ...ref });
    } else {
      await act({ action: "on", ...ref });
    }
  }, wait);
  pwb.append(powerIcon());
  pwb.setAttribute("aria-label", on ? "On: turn it off" : "Off: turn it on");
  pwb.title = on ? "Turn off" : "Turn on";
  out.push(kids(el("div", null, "btns"), pwb, rcb));  // the power button tells on or off
  if (l.why) out.push(el("div", l.why, "warn " + (l.dot === "bad" ? "bad" : "")));
  if (on && e.busy) out.push(el("div", "Busy: " + e.busy + ". Off asks before forcing it.", "warn"));

  out.push(el("span", "SETTINGS", "lab"));
  // Permissions follow claude: a start uses the mode the conversation last ran in (asc/cli.py)
  // the mode it runs in (a start keeps it); the next start's only where it differs (a claude
  // started in another mode that has not written its own yet)
  const next = MODE[e.mode_next] || e.mode_next, cur = MODE[e.mode_used] || next;
  const perm = cur + (e.mode_used && cur !== next ? " · next start " + next : "");
  out.push(kids(el("div", null, "opts"),
    opt("Resurrect", "Bring it back after a reboot or a tmux crash (always with remote control)",
      sw(e.resurrect, "Resurrect", () => act({ action: "resurrect", on: !e.resurrect, ...ref }), wait || !on))));  // off: like rc

  out.push(el("span", "SESSION", "lab"), kv([
    ["Status", on ? statusText(e) : l.label.replace(/^off since.*/, "Off")], ["Memory", on ? size(e.mem_kb) : ""], ["Permissions", perm], ["Claude's name", on && e.claude_name !== e.tmux ? e.claude_name + (e.claude_name_kept ? " (from an old job record of its own)" : "") : ""], ["tmux", e.tmux], ["Session id", e.session_id],
    ["Length", typeof e.conv_lines === "number" ? e.conv_lines.toLocaleString("en") + " lines · " + bytes(e.conv_bytes) : ""],
    ["Claudes", e.claudes > 1 ? e.claudes : ""],
    ["Last on", full(e.last_on)], ["Last off", full(e.last_off)]]));
  out.push(...historyBlock(e));
  out.push(kids(el("div", null, "acts"),
    btn("Rename", "", async () => {
      // claude may go by another name (favorited while it ran, renamed while busy): the same name
      // then still sends it to claude
      const drift = on && e.claude_name && e.claude_name !== e.tmux;
      const name = await ask({ title: `Rename ${e.tmux}`, ok: "Rename",
        text: drift ? `Claude goes by ${e.claude_name}. Rename sends it NAME-${e.id4}, also to claude.ai (when idle).`
                    : `It becomes NAME-${e.id4}.` + (on ? " If idle, claude takes it too, also in claude.ai." : ""),
        input: { value: e.name, check: (v) => /^[a-z0-9][a-z0-9-]{0,30}$/.test(v) ? "" : "a-z, 0-9 and -, starting with a letter or digit, up to 31" } });
      if (name === null || (name === e.name && !drift)) return;
      await act({ action: "rename", name, ...ref });
    }, wait),
    btn("Forget", "danger", async () => {
      if (!await ask({ title: `Forget ${e.tmux}?`, text: "A running session is left alone; only the favorite goes.", ok: "Forget", danger: true })) return;
      const j = await act({ action: "forget", ...ref });
      if (j.ok) closeSheet();
    }, wait)));
  return out;
}

function favoriteButton(sid) {
  return btn("☆ Favorite", "p", async () => {
    const j = await act({ action: "fav", ref: sid });
    if (j.ok) { closeSheet(); loadPast(); }
  }, pending.has(sid));
}

function activeSheet(x) {
  const [label] = STATUS[x.status] || STATUS.unknown;
  return [el("h2", x.name || "Unnamed claude"), el("div", tilde(x.cwd), "s2 mono"),
    x.duplicate ? el("div", "Another claude holds the same session id.", "warn bad") : null,
    el("span", "SESSION", "lab"),
    kv([["Status", statusText(x) || label], ["Claude's name", x.claude_name !== x.name ? x.claude_name : ""],
        ["tmux", x.tmux || "not in tmux"], ["Pid", x.pid], ["Session id", x.session_id]]),
    el("div", "Not a favorite: a reboot will not bring it back. Favorite it to turn it on and off here.", "res"),
    kids(el("div", null, "acts"), favoriteButton(x.session_id))];
}

function pastSheet(c) {
  return [el("h2", c.title || "Untitled"), el("div", tilde(c.cwd), "s2 mono"),
    el("span", "CONVERSATION", "lab"), kv([["Last active", full(c.mtime)], ["Session id", c.session_id]]),
    el("div", "Favorite it to resume it in its own tmux session.", "res"),
    kids(el("div", null, "acts"), favoriteButton(c.session_id))];
}

function renderSheet() {
  const sheet = $("sheet");
  // never redraw under the user's typing
  if (sheet.contains(document.activeElement) && document.activeElement.tagName === "TEXTAREA") return;
  let item = null, body = null;
  if (sheetOf.kind === "fav") item = S && S.favorites.find((e) => e.id4 === sheetOf.key);
  else if (sheetOf.kind === "active") item = S && S.active.find((x) => x.pid === sheetOf.key);
  else item = past.find((c) => c.session_id === sheetOf.key);
  if (!item) { closeSheet(); return; }
  // A redraw replaces every button: only when the data changed, or a tap lands on a removed one.
  // The memory figure changes on every refresh: it alone is updated in place.
  const id = sheetOf.kind === "fav" ? item.id4 : item.session_id;
  const h = sheetOf.kind === "fav" && hist.get(id);  // its history too: new events, or more of it open
  const sig = sheetOf.kind + ":" + pending.has(id) + ":" + (h ? h.length + ":" + (h[0] ? h[0].t + h[0].kind : "") : "-") +
              ":" + (histOpen.get(id) || 0) + ":" + JSON.stringify({ ...item, mem_kb: 0 });
  if (sig === sheetSig) {
    const mem = sheet.querySelector('dd[data-k="Memory"]');  // the one figure that moves on its own
    if (mem && item.mem_kb) mem.textContent = size(item.mem_kb);
    return;
  }
  sheetSig = sig;
  body = sheetOf.kind === "fav" ? favSheet(item) : sheetOf.kind === "active" ? activeSheet(item) : pastSheet(item);
  const x = el("button", "✕", "x");
  x.type = "button";
  x.setAttribute("aria-label", "Close");
  x.addEventListener("click", () => closeSheet());
  const scroll = sheet.scrollTop, controls = () => [...sheet.querySelectorAll("button, textarea")];
  const focused = controls().indexOf(document.activeElement);
  sheet.replaceChildren(x, ...body.filter(Boolean));
  sheet.scrollTop = scroll;
  const t = controls()[focused];
  if (focused >= 0) (t && !t.disabled ? t : x).focus();  // the keyboard stays where it was
}

// Closing from the page goes Back one entry (the one openSheet pushed). That Back lands later; a
// sheet opened before it lands waits for it, or the Back would close the new sheet.
let backPending = null;  // {timer, then: [kind, key] | null} while our own Back is on its way
let opener = null;       // what had the focus before the sheet opened: it gets it back
function backDone() {
  const then = backPending.then;
  clearTimeout(backPending.timer);
  backPending = null;
  if (then) openSheet(...then);
}

function openSheet(kind, key) {
  if (backPending) { backPending.then = [kind, key]; return; }
  const first = !sheetOf;
  sheetOf = { kind, key };
  sheetSig = "";
  renderSheet();
  if (!sheetOf) return;
  if (kind === "fav") loadHist(key);
  if (first) opener = document.activeElement;
  // the page behind is out of reach (Tab, screen readers) while the sheet is open
  for (const c of document.body.children) if (c.id !== "scrim" && c.id !== "toast" && c.id !== "dscrim") c.inert = true;
  $("scrim").classList.add("on");
  document.documentElement.classList.add("locked");  // the page under the sheet does not scroll
  $("sheet").scrollTop = 0;
  $("sheet").querySelector(".x").focus();
  if (first) history.pushState({ sheet: true }, "");  // the phone's Back closes the sheet
}
function closeSheet(fromBack) {
  if (!sheetOf) return;
  if (ask.cancel) ask.cancel();
  sheetOf = null;
  hist.clear();
  histOpen.clear();
  histV = null;
  $("scrim").classList.remove("on");
  document.documentElement.classList.remove("locked");
  for (const c of document.body.children) c.inert = false;
  if (opener && opener.isConnected) opener.focus({ preventScroll: true });
  opener = null;
  if (!fromBack && history.state && history.state.sheet) {
    backPending = { timer: setTimeout(backDone, 3000), then: null };  // in case no popstate comes
    history.back();
  }
}
window.addEventListener("popstate", () => {
  if (backPending) backDone();
  else if (!(history.state && history.state.sheet)) closeSheet(true);  // Forward onto a sheet entry: nothing
});
// a reload on the sheet's entry: no sheet is open, so the entry must not cost an extra Back
if (history.state && history.state.sheet) history.replaceState(null, "");
$("scrim").addEventListener("click", (ev) => { if (ev.target === $("scrim")) closeSheet(); });
document.addEventListener("keydown", (ev) => { if (ev.key === "Escape" && sheetOf) closeSheet(); });

// --- start -----------------------------------------------------------------------------------
let pastTimer;
$("q").addEventListener("input", () => { clearTimeout(pastTimer); pastTimer = setTimeout(loadPast, 300); });
$("rf").addEventListener("click", () => { refresh(); loadPast(); });
setInterval(() => { if (document.visibilityState === "visible") refresh(); }, 5000);
document.addEventListener("visibilitychange", () => {
  if (document.visibilityState === "visible") { lastOk = Math.max(lastOk, Date.now() - 5000); refresh(); }
});
refresh();
loadPast();

// The installed app: a worker makes it installable (sw.js passes everything to the network).
if ("serviceWorker" in navigator) navigator.serviceWorker.register("sw.js").catch(() => {});
// iPhone: without a startup image of the exact screen size, iOS shows black before the first
// paint, and Safari ignores the manifest for it. Draw plain white ones for this screen and common
// neighbours (iOS wants an exact match; some models report the height off by the notch). Safari
// takes them when the user taps "Add to Home Screen".
(function iosStartupImages() {
  if (!/iP(hone|ad|od)/.test(navigator.userAgent) || window.navigator.standalone) return;
  const dpr = window.devicePixelRatio || 1;
  const sizes = new Set([`${screen.width}x${screen.height}`]);
  for (const [a, b] of [[390, 844], [393, 852], [402, 874], [430, 932], [440, 956], [375, 812], [414, 896],
                        [428, 926], [375, 667], [414, 736]]) sizes.add(`${a}x${b}`);
  for (const sz of sizes) {
    const [w, h] = sz.split("x").map(Number);
    for (const [cw, ch, orient] of [[w, h, "portrait"], [h, w, "landscape"]]) {
      const c = document.createElement("canvas");
      c.width = cw * dpr; c.height = ch * dpr;
      const g = c.getContext("2d");
      g.fillStyle = "#ffffff"; g.fillRect(0, 0, c.width, c.height);
      const l = document.createElement("link");
      l.rel = "apple-touch-startup-image"; l.href = c.toDataURL("image/png");
      l.media = `screen and (device-width: ${w}px) and (device-height: ${h}px) and ` +
                `(-webkit-device-pixel-ratio: ${dpr}) and (orientation: ${orient})`;
      document.head.appendChild(l);
    }
  }
})();
