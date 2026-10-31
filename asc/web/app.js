// Temporary page over the dashboard API (GET api/state, GET api/past?q=, POST api/action).
// Every value from the server is user text (titles, folders, notes): set as textContent only.
"use strict";
const token = document.querySelector('meta[name="asctl-token"]').content;
const $ = (id) => document.getElementById(id);
const mb = (kb) => (kb / 1024).toFixed(0) + " MB";

function el(tag, text, cls) {
  const e = document.createElement(tag);
  if (text !== undefined && text !== null) e.textContent = String(text);
  if (cls) e.className = cls;
  return e;
}

function row(cells) {
  const tr = el("tr");
  for (const c of cells) {
    if (!(c instanceof Node)) tr.append(el("td", c));
    else tr.append(c.tagName === "TD" || c.tagName === "TH" ? c : wrap(c));
  }
  return tr;
}
function wrap(node) { const td = el("td"); td.append(node); return td; }

function button(label, body, confirmText) {
  const b = el("button", label);
  b.type = "button";
  b.addEventListener("click", async () => {
    if (confirmText && !window.confirm(confirmText)) return;
    b.disabled = true;
    await act(body);
    b.disabled = false;
  });
  return b;
}

async function act(body) {
  $("msg").textContent = "…";
  try {
    const r = await fetch("api/action", {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-Asctl-Token": token },
      body: JSON.stringify(body),
    });
    const j = await r.json();
    $("msg").textContent = j.ok ? j.out : "Refused: " + (j.error || r.status);
    if (!j.ok && body.action === "off" && /busy/.test(j.error || "") &&
        window.confirm(`${body.tmux}: ${j.error}\n\nForce ${body.tmux} off anyway? Everything in it ends.`)) {
      return act({ ...body, force: true });
    }
  } catch (e) {
    $("msg").textContent = "Failed: " + e;
  }
  refresh();
}

function render(s) {
  const m = s.memory;
  $("memory").textContent = `Memory available ${m.avail_pct}% (${mb(m.avail_kb)} of ${mb(m.total_kb)}), ` +
    `swap free ${mb(m.swap_free_kb)} of ${mb(m.swap_total_kb)}, ${s.on} on`;
  const warn = [];
  if (m.warn) warn.push("Memory below 15%: starting sessions is held back.");
  if (s.active.length) warn.push(`${s.active.length} running claude(s) not favorited: a reboot will not bring them back.`);
  if (s.unknown_files) warn.push(`${s.unknown_files} session file(s) in an unknown format.`);
  if (!s.server) warn.push("No tmux server is running.");
  $("banner").hidden = !warn.length;
  $("banner").textContent = warn.join(" ");

  const f = $("favorites");
  f.replaceChildren(row(["Name", "State", "Mode", "Memory", "Folder", ""].map((t) => el("th", t))));
  for (const e of s.favorites) {
    const acts = el("td");
    const ref = { id: e.id4, tmux: e.tmux };
    if (e.state === "on") acts.append(button("Off", { action: "off", ...ref }, `Turn ${e.tmux} off? Its claude and tmux session end.`));
    else acts.append(button("On", { action: "on", ...ref }));
    if (e.mode !== "skip") {
      const other = e.mode === "auto" ? "manual" : "auto";
      acts.append(button("Mode: " + other, { action: "mode", mode: other, ...ref }));
    }
    acts.append(button("Forget", { action: "forget", ...ref }, `Forget ${e.tmux}? A running session is left alone.`));
    const copy = el("button", "Copy attach");
    copy.type = "button";
    copy.addEventListener("click", () => navigator.clipboard && navigator.clipboard.writeText(e.attach));
    acts.append(copy);
    const state = e.state + (e.status ? ` (${e.status})` : "") + (e.claudes > 1 ? `, ${e.claudes} claudes` : "") +
      (e.busy ? ` — ${e.busy}` : "");
    f.append(row([e.tmux, state, e.mode, e.rss_kb ? mb(e.rss_kb) : "", el("td", e.cwd, "path"), acts]));
  }

  const a = $("active");
  a.replaceChildren(row(["Name", "Status", "tmux", "Folder", ""].map((t) => el("th", t))));
  for (const x of s.active) {
    a.append(row([x.name || x.session_id, x.status + (x.duplicate ? " (duplicate)" : ""), x.tmux || "-",
      el("td", x.cwd, "path"), wrap(button("Favorite", { action: "fav", ref: x.session_id }))]));
  }

  const t = $("top");
  t.replaceChildren(...s.top.mine.map((p) => el("li", `${p.name} ${mb(p.rss_kb)}`)),
    el("li", `other users: ${mb(s.top.others_kb)}`));
}

async function refresh() {
  try {
    const r = await fetch("api/state");
    if (r.ok) render(await r.json());
  } catch (e) { /* the next tick tries again */ }
}

let pastTimer;
async function loadPast() {
  const r = await fetch("api/past?q=" + encodeURIComponent($("q").value));
  if (!r.ok) return;
  const { past } = await r.json();
  const p = $("past");
  p.replaceChildren(row(["Title", "Last active", "Folder", ""].map((t) => el("th", t))));
  for (const c of past) {
    p.append(row([c.title || c.session_id, new Date(c.mtime * 1000).toLocaleString(), el("td", c.cwd, "path"),
      wrap(button("Favorite", { action: "fav", ref: c.session_id }))]));
  }
}

$("q").addEventListener("input", () => { clearTimeout(pastTimer); pastTimer = setTimeout(loadPast, 300); });
setInterval(() => { if (document.visibilityState === "visible") refresh(); }, 5000);
document.addEventListener("visibilitychange", () => { if (document.visibilityState === "visible") refresh(); });
refresh();
loadPast();
