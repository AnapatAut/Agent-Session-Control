// The dashboard page over its API (GET api/state, GET api/past?q=, POST api/action), in the look
// of the serve dashboard: a list of sessions, and a details sheet for each where every action is.
// Every value from the server is user text (titles, folders, notes): it is set as textContent only.
"use strict";
const token = document.querySelector('meta[name="asctl-token"]').content;
const $ = (id) => document.getElementById(id);
const STALE_MS = 20000;  // no good update for this long: the warning triangle

let S = null;            // the last state from the server
let past = [];           // past conversations for the search box
let filter = "all";      // the chip pressed
let sheetOf = null;      // {kind: "fav" | "active" | "past", key}, while the sheet is open
let noteDraft = null;    // {id4, text}: a note being typed survives a refresh
let sheetSig = "";       // the data the open sheet was drawn from: redrawn only when it changes
const pending = new Set();  // ids with an action running: their controls stay disabled across redraws
let lastOk = Date.now(), lastOkTime = null;

function el(tag, text, cls) {
  const e = document.createElement(tag);
  if (text !== undefined && text !== null && text !== "") e.textContent = String(text);
  if (cls) e.className = cls;
  return e;
}
function kids(parent, ...children) { for (const c of children) if (c) parent.append(c); return parent; }

// --- formatting ------------------------------------------------------------------------------
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
  return label + (x.waiting_for ? " (" + x.waiting_for + ")" : "") +
    (x.status_at ? " since " + hms(new Date(x.status_at * 1000)) : "");
}
function ago(ts) {
  const s = Date.now() / 1000 - ts;
  if (s < 3600) return Math.max(1, Math.round(s / 60)) + " min ago";
  if (s < 86400) return Math.round(s / 3600) + " h ago";
  if (s < 86400 * 14) return Math.round(s / 86400) + " days ago";
  return when(ts);
}
const STATUS = { busy: ["Working", "busy"], idle: ["Idle", "idle"], waiting: ["Waiting for you", "wait"],
                 shell: ["Shell", "idle"], unknown: ["Running", "idle"] };

// What a favorite's state means on the page: which list, the dot, a label and why.
function look(e) {
  const st = e.state || "";
  const code = (st.match(/\((\d+)\)/) || [])[1];
  if (st === "on") {
    if (e.claudes > 1) return { group: "attention", dot: "bad", label: e.claudes + " claudes",
      why: `${e.claudes} claudes run in its tmux session; Off would end them all.` };
    const [label, dot] = STATUS[e.status] || STATUS.unknown;
    return { group: "on", dot, label };
  }
  if (st === "duplicate") return { group: "attention", dot: "bad", label: "Duplicate",
    why: "Two claudes hold this session or its name. asctl does nothing about it by itself." };
  if (st.startsWith("on (outside")) return { group: "attention", dot: "wait", label: "Running outside its tmux",
    why: `Its claude runs, but not in tmux session ${e.tmux}.` };
  if (st.startsWith("ended by a signal")) return { group: "attention", dot: "bad", label: "Ended unexpectedly",
    why: `Claude was ended by a signal (${code}); its tmux session is still up. Turn it on to start claude again.` };
  if (st.startsWith("tmux up")) return { group: "attention", dot: "wait", label: "Claude ended",
    why: `Claude ended${code ? " (exit " + code + ")" : ""}; its tmux session is still up.` };
  if (st === "off (wanted on)") return { group: "attention", dot: "wait", label: "Off, wanted on",
    why: "It should be on but is not: a reboot without resurrect, or a start that failed." };
  return { group: "off", dot: "", label: e.last_off ? "off since " + when(e.last_off) : "off" };
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
// remote control: live (lime), on but not live in a running claude (amber), on for its next start (lime
// button, grey chip)
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
                   plan: "plan", bypassPermissions: "skip permissions" };

function favRow(e) {
  const l = look(e);
  const meta = [el("span", l.label, "st " + (l.dot || ""))];
  if (isOn(e) && e.mem_kb) meta.push(tag(size(e.mem_kb)));
  const rs = rcState(e);
  if (rs) { const t = tag("rc", "rc " + rs); t.title = RC_SAYS[rs]; meta.push(t); }
  if (e.resurrect) meta.push(tag("↻ resurrect"));
  const m = MODE_TAG[isOn(e) ? e.mode_used : e.mode_next];  // auto has no tag
  if (m) meta.push(tag(m));
  return rowEl("fav:" + e.id4, () => openSheet("fav", e.id4), l.dot, e.name, e.id4, tilde(e.cwd), meta, e.note, l.why, l.dot === "wait" ? "wait" : "");
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
  const h = location.hostname;
  $("host").textContent = /^[\d.:\[\]]+$/.test(h) ? h : h.split(".")[0];
  $("upd").textContent = "Updated " + hms(new Date(s.time * 1000));

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

  // biggest processes: names and sizes only
  $("top").replaceChildren(...s.top.mine.map((p) => kids(el("div", null, "proc"), el("span", p.name), el("span", size(p.mem_kb), "mono"))),
    kids(el("div", null, "proc"), el("span", "Other users together"), el("span", size(s.top.others_kb), "mono")));

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
  }
  staleCheck();
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

function favSheet(e) {
  const l = look(e), ref = { id: e.id4, tmux: e.tmux }, on = isOn(e), wait = pending.has(e.id4);
  const out = [el("h2", e.name), el("div", "#" + e.id4 + " · " + tilde(e.cwd), "s2 mono")];
  const rcDesc = (on ? (e.rc_live ? "Live now" : "Not live now") + (e.rc !== e.rc_live ? " · changes at its next start" : "")
                     : "Used when it starts") + (e.rc ? " · title " + (e.rc_title || e.tmux) : "");
  // the two actions used most: power (lime on, red off) and rc (colored as rcState)
  // rc shows the live state of a running claude (a tap on amber tries again), else the setting
  const rs = rcState(e), rcOn = rs === "live" || rs === "set";
  const rcb = btn("rc", "rcb " + rs, () => act({ action: "rc", on: !rcOn, ...ref }), wait);
  rcb.setAttribute("aria-pressed", String(rcOn));
  rcb.setAttribute("aria-label", (RC_SAYS[rs] || "Remote control off") + (rcOn ? ": turn it off" : ": turn it on"));
  rcb.title = RC_SAYS[rs] || "Remote control off";
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
  out.push(el("div", "Remote control " + (e.rc ? "on" : "off") + " · " + rcDesc, "rcd"));
  if (l.why) out.push(el("div", l.why, "warn " + (l.dot === "bad" ? "bad" : "")));
  if (on && e.busy) out.push(el("div", "Busy: " + e.busy + ". Off asks before forcing it.", "warn"));

  out.push(el("span", "SETTINGS", "lab"));
  // Permissions follow claude: a start uses the mode the conversation last ran in (asc/cli.py)
  // the mode it runs in (a start keeps it); the next start's only where it differs (skip, plan)
  const next = MODE[e.mode_next] || e.mode_next, cur = MODE[e.mode_used] || next;
  const perm = cur + (e.mode_used && cur !== next ? " · next start " + next +
    (e.mode_used === "bypassPermissions" ? " (skip only if set on the machine: asctl mode " + e.id4 + " skip)" : "") : "");
  out.push(kids(el("div", null, "opts"),
    opt("Resurrect", "Bring it back after a reboot or a tmux crash (always with remote control)",
      sw(e.resurrect, "Resurrect", () => act({ action: "resurrect", on: !e.resurrect, ...ref }), wait))));

  out.push(el("span", "NOTE", "lab"));
  const draft = noteDraft && noteDraft.id4 === e.id4 ? noteDraft.text : e.note;
  const ta = el("textarea");
  ta.maxLength = 500;
  ta.value = draft;
  ta.setAttribute("aria-label", "Note");
  const count = el("span", draft.length + "/500", "count");
  const save = btn("Save note", "sm p", async () => {
    const j = await act({ action: "note", text: ta.value, ...ref });
    if (j.ok) noteDraft = null;
  });
  save.disabled = wait || draft === e.note;
  ta.addEventListener("input", () => {
    ta.value = ta.value.replace(/[\r\n\t]+/g, " ");  // one line: no control characters
    noteDraft = { id4: e.id4, text: ta.value };
    count.textContent = ta.value.length + "/500";
    save.disabled = pending.has(e.id4) || ta.value === e.note;
  });
  out.push(kids(el("div", null, "field"), ta, count), save);

  out.push(el("span", "SESSION", "lab"), kv([
    ["Status", on ? statusText(e) : l.label.replace(/^off since.*/, "Off")], ["Memory", on ? size(e.mem_kb) : ""], ["Permissions", perm], ["tmux", e.tmux], ["Session id", e.session_id], ["Claudes", e.claudes > 1 ? e.claudes : ""],
    ["Last on", full(e.last_on)], ["Last off", full(e.last_off)]]));
  out.push(kids(el("div", null, "acts"),
    btn("Copy attach", "", async () => {
      try { await navigator.clipboard.writeText(e.attach); toast("Copied: " + e.attach); }
      catch (err) { toast(e.attach); }
    }),
    btn("Rename", "", async () => {
      const name = await ask({ title: `Rename ${e.tmux}`, text: `The id stays: it becomes NAME-${e.id4}.`, ok: "Rename",
        input: { value: e.name, check: (v) => /^[a-z0-9][a-z0-9-]{0,30}$/.test(v) ? "" : "a-z, 0-9 and -, starting with a letter or digit, up to 31" } });
      if (name === null || name === e.name) return;
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
  const sig = sheetOf.kind + ":" + pending.has(id) + ":" + JSON.stringify({ ...item, mem_kb: 0 });
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
  noteDraft = null;
  renderSheet();
  if (!sheetOf) return;
  if (first) opener = document.activeElement;
  // the page behind is out of reach (Tab, screen readers) while the sheet is open
  for (const c of document.body.children) if (c.id !== "scrim" && c.id !== "toast" && c.id !== "dscrim") c.inert = true;
  $("scrim").classList.add("on");
  $("sheet").scrollTop = 0;
  $("sheet").querySelector(".x").focus();
  if (first) history.pushState({ sheet: true }, "");  // the phone's Back closes the sheet
}
function closeSheet(fromBack) {
  if (!sheetOf) return;
  if (ask.cancel) ask.cancel();
  sheetOf = null;
  noteDraft = null;
  $("scrim").classList.remove("on");
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
