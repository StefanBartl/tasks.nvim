-- TESTS/fixture.lua -- builds a throwaway vault for the task-engine specs.
-- Never touches the real vault: every spec works on `H.tmpdir()`.

local F = {}

--- The fixed "today" the specs use, so dates in output are reproducible.
F.TODAY = "2026-10-03"

---@param path string
local function mkdir(path)
  vim.fn.mkdir(path, "p")
end

--- The Backlog README skeleton every area carries (`_noch leer_` in both sections).
F.EMPTY_BACKLOG_README = table.concat({
  "# X — Backlog",
  "",
  "Erledigtes Material und Nachweise zu diesem Bereich.",
  "",
  "## FEATURES (0)",
  "",
  "_noch leer_",
  "",
  "## TASKS (0)",
  "",
  "_noch leer_",
  "",
}, "\n")

--- Build a vault under a fresh temp dir.
---
--- Areas: `lib.nvim` and `cascade.nvim` (ROADMAP + Backlog + README), `ALL` and
--- `nvim-config` (Backlog only), `migrate.nvim` (empty, an "extra" area),
--- `filetreepicker.nvim` (empty, NOT an area), plus `_Telemetry`, `TEMPLATES`,
--- `TOOLS` (never areas).
---@param H table
---@return string root
function F.vault(H)
  local root = H.tmpdir() .. "/vault"
  for _, area in ipairs({ "lib.nvim", "cascade.nvim" }) do
    mkdir(root .. "/" .. area .. "/ROADMAP")
    mkdir(root .. "/" .. area .. "/Backlog/FEATURES")
    mkdir(root .. "/" .. area .. "/Backlog/TASKS")
    H.write(root .. "/" .. area .. "/Backlog/README.md", F.EMPTY_BACKLOG_README)
  end
  for _, area in ipairs({ "ALL", "nvim-config" }) do
    mkdir(root .. "/" .. area .. "/Backlog/FEATURES")
    mkdir(root .. "/" .. area .. "/Backlog/TASKS")
    H.write(root .. "/" .. area .. "/Backlog/README.md", F.EMPTY_BACKLOG_README)
  end
  mkdir(root .. "/migrate.nvim")
  mkdir(root .. "/filetreepicker.nvim")
  mkdir(root .. "/_Telemetry/ROADMAP")
  mkdir(root .. "/TEMPLATES/ROADMAP")
  mkdir(root .. "/TOOLS/Backlog")
  -- No built-in extras any more: the fixture names the three it relies on.
  require("tasks_nvim.vault").configure({
    extra_areas = { "ALL", "nvim-config", "docmap-desktop", "migrate.nvim" },
  })
  return root
end

--- A task file text. `meta` is an ordered list of `{ key, rawvalue }` lines
--- (raw, so a spec can write a bad value on purpose); `body` follows the block.
---@param meta table[]
---@param body? string
---@return string
function F.text(meta, body)
  local lines = { "---" }
  for _, kv in ipairs(meta) do
    lines[#lines + 1] = kv[1] .. ": " .. kv[2]
  end
  lines[#lines + 1] = "---"
  return table.concat(lines, "\n") .. "\n" .. (body or "\nA summary line.\n")
end

--- Write a task file `<root>/<area>/ROADMAP/tasks/<slug>.md`.
---@param H table
---@param root string
---@param area string
---@param slug string
---@param meta table[]
---@param body? string
---@return string path
function F.task(H, root, area, slug, meta, body)
  local path = root .. "/" .. area .. "/ROADMAP/tasks/" .. slug .. ".md"
  H.write(path, F.text(meta, body))
  return path
end

--- Standard meta: title, status, plus extras.
---@param title string
---@param status string
---@param extra? table[]
---@return table[]
function F.meta(title, status, extra)
  local meta = { { "title", title }, { "status", status } }
  for _, kv in ipairs(extra or {}) do
    meta[#meta + 1] = kv
  end
  return meta
end

return F
