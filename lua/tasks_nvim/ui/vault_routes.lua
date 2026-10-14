---@module 'tasks_nvim.ui.vault_routes'
---@brief The composer routes and the argument type of `:TasksVault`.
---@description
--- Grammar (verb-first, like `:Tasks`: the composer has no dynamic first segment):
---  - `open|clipboard|paste|link|find|grep|tree|cdx [<area>|<part>] [<part>]` + `--rel` `--file` where they apply
---  - `new feature|task <title...> [--area=<area>]`
---  - `create [<dir>] [<area>...] [--force]`
---  - `status` (also the bare `:TasksVault`)
---
--- Argument type registered here:
---  - `VAULT_AREA`: an area of the vault, or a part word; read from the vault on every call, fails soft
---    (no vault means no candidates). It accepts any word: the handler resolves a prefix (`lib` for `lib.nvim`),
---    reports an ambiguous one with the candidates, and says "no vault" once instead of a parse error.
---
--- Not its job: running anything (`ui/vault_cmd`), the paths (`vault_ops`).

local composer = require("lib.nvim.bindings.usercmd.composer")

local ops = require("tasks_nvim.vault_ops")
local vault = require("tasks_nvim.vault")

local M = {}

---@return table
local function cmd()
  return require("tasks_nvim.ui.vault_cmd")
end

---@param candidates string[]
---@param lead string
---@return string[]
local function prefix_ci(candidates, lead)
  local out, low = {}, lead:lower()
  for _, c in ipairs(candidates) do
    if c:lower():sub(1, #low) == low then
      out[#out + 1] = c
    end
  end
  return out
end

---@return string[]
local function area_names()
  local root = vault.root()
  if not root then
    return {}
  end
  local ok, names = pcall(vault.area_names, root)
  return ok and names or {}
end

---Register `VAULT_AREA`. Safe to call twice.
---@return nil
function M.register_types()
  composer.register_type("VAULT_AREA", {
    desc = "Area of the vault (a prefix such as lib is enough), or a part of it",
    validate = function(raw)
      return true, raw, nil
    end,
    complete = function(arg_lead, spec)
      local names = area_names()
      if not (spec and spec.areas_only) then
        vim.list_extend(names, ops.PART_NAMES)
      end
      return prefix_ci(names, arg_lead)
    end,
  })
end

local TARGET = {
  name = "target",
  type = "VAULT_AREA",
  optional = true,
  desc = "Area (default: the area of this buffer); a part word alone also works",
}

local PART = {
  name = "part",
  type = "STRING",
  enum = ops.PART_NAMES,
  optional = true,
  desc = "Part of the area (default: backlog)",
  enum_desc = {
    backlog = "the Backlog folder with its README index",
    features = "Backlog/FEATURES, concepts and build plans",
    tasks = "Backlog/TASKS, audits and chores",
    roadmap = "ROADMAP, the open work",
    all = "the whole area folder",
  },
}

local REL = {
  name = "rel",
  bool = true,
  desc = "Write the path relative to the current file instead of absolute",
}

local FILE = {
  name = "file",
  bool = true,
  desc = "Use the index file of the part (Backlog/README.md) instead of its folder",
}

---@param verb string
---@param desc string
---@param run string  function name of `vault_cmd`
---@param flags? table[]
---@return table route
local function target_route(verb, desc, run, flags)
  return {
    path = { verb },
    args = { TARGET, PART },
    flags = flags,
    desc = desc,
    run = function(ctx)
      cmd()[run](ctx)
    end,
  }
end

---The route list of `:TasksVault`.
---@return table[] routes
function M.routes()
  return {
    target_route(
      "open",
      "Open the index of an area's Backlog (or features|tasks|roadmap|all) in a buffer, else its folder in the explorer",
      "open"
    ),
    target_route(
      "clipboard",
      "Copy the path of an area's Backlog folder (or features|tasks|roadmap|all) to the + register",
      "clipboard",
      { REL, FILE }
    ),
    target_route(
      "paste",
      "Insert the path of an area's Backlog folder (or features|tasks|roadmap|all) at the cursor",
      "paste",
      { REL, FILE }
    ),
    target_route(
      "link",
      "Insert a Markdown link to the Backlog of an area at the cursor, relative to the current file",
      "link"
    ),
    target_route(
      "find",
      "Pick a file by name in the folder of an area's Backlog (or features|tasks|roadmap|all) through pickers.nvim",
      "find"
    ),
    target_route(
      "grep",
      "Search the content of the files in the folder of an area's Backlog through pickers.nvim",
      "grep"
    ),
    target_route(
      "tree",
      "Show the folder of an area's Backlog (or features|tasks|roadmap|all) in the file explorer",
      "tree"
    ),
    target_route(
      "cdx",
      "Copy a prompt for Claude Code that names the folder of an area's Backlog to the + register",
      "cdx",
      { REL, FILE }
    ),
    {
      path = { "new" },
      args = {
        {
          name = "kind",
          type = "STRING",
          enum = { "feature", "task" },
          desc = "Kind of note: it goes to Backlog/FEATURES or Backlog/TASKS",
          enum_desc = {
            feature = "a concept, build plan or feature analysis (Backlog/FEATURES)",
            task = "an audit, sweep or chore (Backlog/TASKS)",
          },
        },
      },
      flags = {
        {
          name = "area",
          type = "VAULT_AREA",
          areas_only = true,
          desc = "Area to write the note in (default: the area of this buffer)",
        },
      },
      desc = "Create a dated note in Backlog/FEATURES or Backlog/TASKS of an area, add its README row and open it; the words after the kind are the title",
      run = function(ctx)
        cmd().new(ctx)
      end,
    },
    {
      path = { "create" },
      args = {
        {
          name = "dir",
          type = "PATH",
          optional = true,
          desc = "Folder of the new vault (asked for when missing); more words are areas to make",
        },
      },
      flags = {
        {
          name = "force",
          bool = true,
          desc = "Make and use another vault although one is in use",
        },
        { name = "yes", bool = true, desc = "Skip the question that lists what will happen" },
      },
      desc = "Create a vault folder (with the areas named after it): lists what happens and the setup() step that is left to you, then uses it for this session",
      run = function(ctx)
        cmd().create(ctx)
      end,
    },
    {
      path = { "status" },
      desc = "Show the vault in use, its number of areas and the area of this buffer",
      run = function(ctx)
        cmd().status(ctx)
      end,
    },
  }
end

return M
