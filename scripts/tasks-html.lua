---@brief `scripts/tasks-html.lua` -- one self-contained HTML overview of the vault (W1 of the tasks app).
---@description
--- A pure consumer of the CLI: it runs `list`, `plan --format=tsv` and `next` of `scripts/tasks.lua`, merges the
--- three answers by task id and writes ONE file with the data inlined. No server, no engine change, no network.
---
---     nvim --headless -u NONE -l scripts/tasks-html.lua --vault=<vault> --out=tasks.html
---
--- Options: `--vault=<dir>` (else `$TASKS_VAULT`), `--out=<file>` (default `tasks-overview.html`),
--- `--area=<area>` (only that area; the Today card still asks the whole vault).
---
--- Titles come from files and are untrusted: the page builds its DOM with `textContent` only (no `innerHTML`) and
--- the inlined JSON has every `<` escaped, so a title can never close the data block.

local script = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")
local plugin_root = vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(script)))
local cli = plugin_root .. "/scripts/tasks.lua"

local opts = {}
for i = 1, #(arg or {}) do
  local key, value = tostring(arg[i]):match("^%-%-([%w-]+)=(.*)$")
  if key then
    opts[key] = value
  else
    io.stderr:write("error: unknown argument " .. tostring(arg[i]) .. "\n")
    os.exit(2)
  end
end

local STATUSES = "open,doing,decision,blocked,parked"

---Run one command of the CLI and return its lines.
---@param args string[]
---@return string[] lines
local function run(args)
  local cmd = { vim.v.progpath, "--headless", "-u", "NONE", "-l", cli }
  vim.list_extend(cmd, args)
  if opts.vault and opts.vault ~= "" then
    cmd[#cmd + 1] = "--vault=" .. opts.vault
  end
  local res = vim.system(cmd, { text = true }):wait()
  if res.code ~= 0 then
    io.stderr:write(
      ("error: `tasks %s` failed (%d): %s\n"):format(args[1], res.code, res.stderr or "")
    )
    os.exit(1)
  end
  return vim.split(res.stdout or "", "\r?\n", { trimempty = true })
end

---@param line string
---@return string[]
local function cols(line)
  return vim.split(line, "\t", { plain = true })
end

---@param s string|nil
---@return integer|nil
local function num(s)
  return tonumber(s)
end

---Value of an empty or `-` column is nil.
---@param s string|nil
---@return string|nil
local function val(s)
  if s == nil or s == "" or s == "-" then
    return nil
  end
  return s
end

local list_args = { "list", "--status=" .. STATUSES }
if opts.area and opts.area ~= "" then
  table.insert(list_args, 2, opts.area)
end

---@type table<string, table>
local by_id = {}
---@type table[]
local tasks = {}

-- list: id status prio effort kind updated title
for _, line in ipairs(run(list_args)) do
  local c = cols(line)
  if #c >= 7 and c[1]:find("/", 1, true) then
    local area, slug = c[1]:match("^(.-)/(.+)$")
    local t = {
      id = c[1],
      area = area,
      slug = slug,
      status = c[2],
      prio = num(c[3]),
      effort = val(c[4]),
      kind = val(c[5]),
      updated = val(c[6]),
      title = c[7],
    }
    by_id[t.id] = t
    tasks[#tasks + 1] = t
  end
end

-- plan --format=tsv: stage id readiness status prio effort leverage title
for _, line in ipairs(run({ "plan", "--format=tsv" })) do
  local c = cols(line)
  local t = by_id[c[2] or ""]
  if t then
    t.stage = num(c[1])
    t.ready = c[3] == "ready"
    t.leverage = num(c[7])
  end
end

-- next: "next: <id>\t<title>\t<reason>", "then: ...", "cdx: ..."
local today = { next = {}, ["then"] = {}, cdx = {} }
local empty_note
for _, line in ipairs(run({ "next", "--n=5" })) do
  local kind, rest = line:match("^(%a+):%s*(.*)$")
  if kind and today[kind] then
    local c = cols(rest)
    today[kind][#today[kind] + 1] = { id = c[1], title = c[2] or "", reason = c[3] or "" }
  elseif line ~= "" then
    empty_note = (empty_note and (empty_note .. " ") or "") .. line
  end
end

local data = {
  generated = os.date("%Y-%m-%d %H:%M"),
  vault = opts.vault or vim.env.TASKS_VAULT or "",
  area = opts.area,
  tasks = tasks,
  today = today,
  note = empty_note,
}

-- `<` escaped: a title containing `</script>` must not end the data block.
local json = vim.json
  .encode(data)
  :gsub("<", "\\u003c")
  :gsub("\226\128\168", "\\u2028")
  :gsub("\226\128\169", "\\u2029")

local TEMPLATE = [==[<!doctype html>
<html lang="de">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="light dark">
<title>Tasks Übersicht</title>
<style>
:root {
  --bg: #f7f7f5; --panel: #ffffff; --text: #1d1d1b; --muted: #6b6b66; --line: #dedcd6;
  --accent: #2f6fdd; --chip: #ecebe6; --chip-on: #2f6fdd; --chip-on-text: #ffffff;
  --doing: #2f8f4e; --decision: #b8741a; --blocked: #c0392b; --open: #2f6fdd; --parked: #8a8a85;
}
@media (prefers-color-scheme: dark) {
  :root:not([data-theme="light"]) {
    --bg: #161618; --panel: #1f1f22; --text: #ececea; --muted: #9a9a95; --line: #333337;
    --accent: #6b9cf0; --chip: #2a2a2e; --chip-on: #6b9cf0; --chip-on-text: #101012;
    --doing: #5fbf7f; --decision: #e0a04a; --blocked: #e8695c; --open: #6b9cf0; --parked: #8a8a85;
  }
}
:root[data-theme="dark"] {
  --bg: #161618; --panel: #1f1f22; --text: #ececea; --muted: #9a9a95; --line: #333337;
  --accent: #6b9cf0; --chip: #2a2a2e; --chip-on: #6b9cf0; --chip-on-text: #101012;
  --doing: #5fbf7f; --decision: #e0a04a; --blocked: #e8695c; --open: #6b9cf0; --parked: #8a8a85;
}
* { box-sizing: border-box; }
body { margin: 0; background: var(--bg); color: var(--text); font: 14px/1.45 system-ui, sans-serif; }
main { max-width: 1200px; margin: 0 auto; padding: 16px; }
header { display: flex; flex-wrap: wrap; gap: 8px 16px; align-items: baseline; margin-bottom: 12px; }
h1 { font-size: 20px; margin: 0; }
.meta { color: var(--muted); font-size: 12px; }
button, select, input { font: inherit; color: inherit; }
button { background: var(--chip); border: 1px solid var(--line); border-radius: 6px; padding: 4px 10px; cursor: pointer; }
button:hover { border-color: var(--accent); }
.card { background: var(--panel); border: 1px solid var(--line); border-radius: 8px; padding: 12px; margin-bottom: 12px; }
.card h2 { font-size: 13px; margin: 0 0 8px; text-transform: uppercase; letter-spacing: .04em; color: var(--muted); }
.today-row { display: flex; flex-wrap: wrap; gap: 4px 12px; padding: 3px 0; align-items: baseline; }
.today-row .why { color: var(--muted); font-size: 12px; }
.tools { display: flex; flex-wrap: wrap; gap: 8px; align-items: center; margin-bottom: 8px; }
.tools input[type=search] { flex: 1 1 260px; min-width: 200px; padding: 6px 10px; border-radius: 6px;
  border: 1px solid var(--line); background: var(--panel); }
.tools select { padding: 5px 8px; border-radius: 6px; border: 1px solid var(--line); background: var(--panel); }
.chips { display: flex; flex-wrap: wrap; gap: 6px; align-items: center; margin: 4px 0; }
.chips .label { color: var(--muted); font-size: 12px; min-width: 64px; }
.chip { background: var(--chip); border: 1px solid transparent; border-radius: 999px; padding: 2px 10px; font-size: 12px; }
.chip[aria-pressed="true"] { background: var(--chip-on); color: var(--chip-on-text); }
.chip .n { opacity: .7; margin-left: 4px; }
.group { margin: 16px 0 6px; font-size: 13px; font-weight: 600; display: flex; gap: 8px; align-items: baseline; }
.group .n { color: var(--muted); font-weight: 400; }
.row { display: grid; grid-template-columns: 3.2em 3.2em 1fr; gap: 8px; align-items: baseline;
  padding: 5px 8px; border-bottom: 1px solid var(--line); background: var(--panel); }
.row:first-of-type { border-top-left-radius: 8px; border-top-right-radius: 8px; }
.row .title { min-width: 0; }
.row .title .t { overflow-wrap: anywhere; }
.row .sub { color: var(--muted); font-size: 12px; display: flex; flex-wrap: wrap; gap: 2px 10px; }
.id { font: 12px ui-monospace, Consolas, monospace; background: none; border: 0; padding: 0; color: var(--accent);
  text-align: left; cursor: copy; }
.badge { font-size: 11px; border-radius: 4px; padding: 0 6px; border: 1px solid currentColor; white-space: nowrap; }
.s-doing { color: var(--doing); } .s-decision { color: var(--decision); } .s-blocked { color: var(--blocked); }
.s-open { color: var(--open); } .s-parked { color: var(--parked); }
.ready { color: var(--doing); }
.empty { color: var(--muted); padding: 16px; text-align: center; }
@media (max-width: 600px) { .row { grid-template-columns: 2.6em 2.6em 1fr; } }
</style>
</head>
<body>
<main>
<header>
  <h1 id="h1">Tasks</h1>
  <span class="meta" id="meta"></span>
  <button id="reload" type="button" title="Seite neu laden (nach erneutem Erzeugen der Datei)">Neu laden</button>
  <button id="theme" type="button" title="Hell/Dunkel wechseln">Theme</button>
</header>
<section class="card" id="today"></section>
<div class="tools">
  <input id="q" type="search" placeholder="Suche in ID und Titel  ( / )" aria-label="Suche">
  <label>Gruppieren
    <select id="group"><option value="status">nach Status</option><option value="stage">nach Stage</option><option value="area">nach Bereich</option></select>
  </label>
  <button id="clear" type="button">Filter zurücksetzen</button>
</div>
<div id="chips"></div>
<div id="list"></div>
<script type="application/json" id="data">__DATA__</script>
<script>
(function () {
  "use strict";
  var D = JSON.parse(document.getElementById("data").textContent);
  var STATUS_ORDER = ["doing", "decision", "blocked", "open", "parked"];
  var EFFORT_ORDER = ["XS", "S", "M", "L", "XL"];
  var state = { q: "", group: "status", sel: { status: {}, prio: {}, effort: {}, kind: {}, area: {}, ready: {} } };

  function load() {
    try {
      var raw = localStorage.getItem("tasks-html-state");
      if (raw) {
        var s = JSON.parse(raw);
        if (s && s.sel) { state.sel = Object.assign(state.sel, s.sel); }
        if (s && typeof s.group === "string") { state.group = s.group; }
      }
    } catch (e) { /* storage may be blocked */ }
  }
  function save() {
    try { localStorage.setItem("tasks-html-state", JSON.stringify({ sel: state.sel, group: state.group })); }
    catch (e) { /* ignore */ }
  }

  function el(tag, props, kids) {
    var n = document.createElement(tag);
    if (props) {
      Object.keys(props).forEach(function (k) {
        if (k === "text") { n.textContent = props[k]; }
        else if (k === "class") { n.className = props[k]; }
        else if (k.slice(0, 2) === "on") { n.addEventListener(k.slice(2), props[k]); }
        else { n.setAttribute(k, props[k]); }
      });
    }
    (kids || []).forEach(function (c) { if (c) { n.appendChild(c); } });
    return n;
  }

  function copy(text, btn) {
    var done = function () { var old = btn.textContent; btn.textContent = "kopiert"; setTimeout(function () { btn.textContent = old; }, 900); };
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(text).then(done, function () {});
    }
  }

  function dim(t, name) {
    if (name === "prio") { return t.prio == null ? "–" : "P" + t.prio; }
    if (name === "ready") { return t.ready ? "startbar" : "wartet"; }
    var v = t[name];
    if (name === "effort" && v && EFFORT_ORDER.indexOf(v) === -1) { return "Tage"; }
    return v == null || v === "" ? "–" : String(v);
  }
  function active(name) { return Object.keys(state.sel[name]).filter(function (k) { return state.sel[name][k]; }); }

  function matches(t, skip) {
    var q = state.q.trim().toLowerCase();
    if (q && (t.id + " " + t.title).toLowerCase().indexOf(q) === -1) { return false; }
    return Object.keys(state.sel).every(function (name) {
      if (name === skip) { return true; }
      var on = active(name);
      return on.length === 0 || on.indexOf(dim(t, name)) !== -1;
    });
  }

  function values(name) {
    var seen = {};
    D.tasks.forEach(function (t) { seen[dim(t, name)] = true; });
    var keys = Object.keys(seen);
    var order = name === "status" ? STATUS_ORDER : name === "effort" ? EFFORT_ORDER : null;
    keys.sort(function (a, b) {
      if (order) {
        var ia = order.indexOf(a), ib = order.indexOf(b);
        ia = ia < 0 ? 99 : ia; ib = ib < 0 ? 99 : ib;
        if (ia !== ib) { return ia - ib; }
      }
      return a < b ? -1 : a > b ? 1 : 0;
    });
    return keys;
  }

  function renderChips() {
    var box = document.getElementById("chips");
    box.textContent = "";
    [["status", "Status"], ["prio", "Prio"], ["effort", "Aufwand"], ["kind", "Art"], ["ready", "Bereit"], ["area", "Bereich"]]
      .forEach(function (pair) {
        var name = pair[0];
        var vs = values(name);
        if (vs.length < 2 && name !== "status") { return; }
        var row = el("div", { class: "chips" }, [el("span", { class: "label", text: pair[1] })]);
        vs.forEach(function (v) {
          var n = D.tasks.filter(function (t) { return dim(t, name) === v && matches(t, name); }).length;
          var on = !!state.sel[name][v];
          var chip = el("button", {
            type: "button", class: "chip", "aria-pressed": on ? "true" : "false",
            onclick: function () { state.sel[name][v] = !on; save(); render(); }
          }, [document.createTextNode(v), el("span", { class: "n", text: String(n) })]);
          row.appendChild(chip);
        });
        box.appendChild(row);
      });
  }

  function renderToday() {
    var box = document.getElementById("today");
    box.textContent = "";
    box.appendChild(el("h2", { text: "Heute" }));
    var any = false;
    [["next", "Als Nächstes"], ["then", "Danach"], ["cdx", "Für eine KI-Sitzung"]].forEach(function (p) {
      (D.today[p[0]] || []).forEach(function (r) {
        any = true;
        var idb = el("button", { type: "button", class: "id", text: r.id, title: "ID kopieren" });
        idb.addEventListener("click", function () { copy(r.id, idb); });
        box.appendChild(el("div", { class: "today-row" }, [
          el("span", { class: "badge", text: p[1] }), idb, el("span", { text: r.title }),
          r.reason ? el("span", { class: "why", text: r.reason }) : null
        ]));
      });
    });
    if (!any) { box.appendChild(el("div", { class: "why", text: D.note || "Nichts startbar." })); }
  }

  function groupKey(t) {
    if (state.group === "stage") { return t.stage == null ? "ohne Stage" : "Stage " + String(t.stage).padStart(2, "0"); }
    if (state.group === "area") { return t.area; }
    return t.status;
  }
  function groupSort(a, b) {
    if (state.group === "status") { return STATUS_ORDER.indexOf(a) - STATUS_ORDER.indexOf(b); }
    return a < b ? -1 : a > b ? 1 : 0;
  }
  function taskSort(a, b) {
    var pa = a.prio == null ? 9 : a.prio, pb = b.prio == null ? 9 : b.prio;
    if (state.group === "stage" && a.stage !== b.stage) { return (a.stage == null ? 999 : a.stage) - (b.stage == null ? 999 : b.stage); }
    if (pa !== pb) { return pa - pb; }
    return a.id < b.id ? -1 : 1;
  }

  function renderList() {
    var box = document.getElementById("list");
    box.textContent = "";
    var shown = D.tasks.filter(function (t) { return matches(t); });
    document.getElementById("meta").textContent =
      shown.length + " von " + D.tasks.length + " · erzeugt " + D.generated + (D.area ? " · Bereich " + D.area : "");
    if (shown.length === 0) { box.appendChild(el("div", { class: "empty", text: "Keine Treffer." })); return; }
    var groups = {};
    shown.forEach(function (t) { (groups[groupKey(t)] = groups[groupKey(t)] || []).push(t); });
    Object.keys(groups).sort(groupSort).forEach(function (g) {
      var items = groups[g].sort(taskSort);
      box.appendChild(el("div", { class: "group" }, [
        el("span", { class: state.group === "status" ? "s-" + g : "", text: g }),
        el("span", { class: "n", text: String(items.length) })
      ]));
      items.forEach(function (t) {
        var idb = el("button", { type: "button", class: "id", text: t.area + "/", title: "ID kopieren: " + t.id });
        idb.addEventListener("click", function () { copy(t.id, idb); });
        var sub = [
          el("span", { class: "badge s-" + t.status, text: t.status }),
          t.ready ? el("span", { class: "ready", text: "startbar" }) : null,
          t.kind ? el("span", { text: t.kind }) : null,
          t.stage != null ? el("span", { text: "Stage " + t.stage }) : null,
          t.leverage ? el("span", { text: "Hebel " + t.leverage }) : null,
          t.updated ? el("span", { text: t.updated }) : null,
          el("span", { text: t.slug })
        ];
        box.appendChild(el("div", { class: "row" }, [
          el("span", { text: t.prio == null ? "–" : "P" + t.prio }),
          el("span", { text: t.effort || "–" }),
          el("div", { class: "title" }, [
            el("div", { class: "t", text: t.title }),
            el("div", { class: "sub" }, [idb].concat(sub))
          ])
        ]));
      });
    });
  }

  function render() { renderChips(); renderList(); }

  load();
  document.getElementById("h1").textContent = "Tasks" + (D.vault ? "" : "");
  document.getElementById("group").value = state.group;
  document.getElementById("group").addEventListener("change", function (e) { state.group = e.target.value; save(); render(); });
  document.getElementById("q").addEventListener("input", function (e) { state.q = e.target.value; renderList(); renderChips(); });
  document.getElementById("clear").addEventListener("click", function () {
    Object.keys(state.sel).forEach(function (k) { state.sel[k] = {}; });
    state.q = ""; document.getElementById("q").value = ""; save(); render();
  });
  document.getElementById("reload").addEventListener("click", function () { location.reload(); });
  document.getElementById("theme").addEventListener("click", function () {
    var root = document.documentElement;
    var dark = root.getAttribute("data-theme") === "dark" ||
      (!root.getAttribute("data-theme") && window.matchMedia("(prefers-color-scheme: dark)").matches);
    root.setAttribute("data-theme", dark ? "light" : "dark");
  });
  document.addEventListener("keydown", function (e) {
    if (e.key === "/" && document.activeElement.tagName !== "INPUT") { e.preventDefault(); document.getElementById("q").focus(); }
  });
  renderToday();
  render();
})();
</script>
</main>
</body>
</html>
]==]

local out = opts.out and opts.out ~= "" and opts.out or "tasks-overview.html"
local html = TEMPLATE:gsub("__DATA__", function()
  return json
end)
local fh, err = io.open(out, "wb")
if not fh then
  io.stderr:write("error: cannot write " .. out .. ": " .. tostring(err) .. "\n")
  os.exit(1)
end
fh:write(html)
fh:close()
io.stdout:write(
  ("wrote %s (%d tasks, %d bytes)\n"):format(
    vim.fs.normalize(vim.fn.fnamemodify(out, ":p")),
    #tasks,
    #html
  )
)
os.exit(0)
