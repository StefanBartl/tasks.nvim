-- TESTS/tasks_usrcmds_help_style_spec.lua -- the option texts of `:Tasks` (and of the nested routes a host mounts under
-- its own verb) have the shape lib.nvim's option float expects: present, one line, no closing full stop, 12 to 80
-- characters; an `enum_desc` names only values the option has.
--
-- This reads the route tree (`tasks_nvim.ui.routes`) and the registered argument types only, so it runs on any lib.nvim.
-- The question "which option shows up as a bare row" needs `composer.help.undocumented`, which an older lib.nvim lacks:
-- that is tasks_usrcmds_help_spec.lua, which skips there. Keeping the two apart matters because testing.nvim turns a
-- printed `skip` line into a SKIP only for a spec that has asserted nothing -- this one must not be switched off with it.

return function(H)
  local ok = H.ok

  local routes = require("tasks_nvim.ui.routes")
  -- TASK_AREA and TASK_ID carry the fallback text of an argument without a `desc` of its own
  routes.register_types()

  -- The float shows one line per option: no line break, no closing full stop, nothing absurdly long; an
  -- `enum_desc` only for values the option really has, and only where the float would show it (flags: `enum`).
  local seen = 0
  ---@param label string
  ---@param text string
  local function check_style(label, text)
    ok(not text:find("[\r\n]"), label .. ": the desc is one line")
    ok(not text:find("%.$"), label .. ": the desc has no closing full stop")
    ok(#text >= 12 and #text <= 80, ("%s: the desc is %d characters long"):format(label, #text))
    seen = seen + 1
  end
  ---@param label string
  ---@param text any
  local function check_text(label, text)
    ok(type(text) == "string" and text ~= "", label .. " has a desc of its own")
    if type(text) == "string" then
      check_style(label, text)
    end
  end
  ---@param label string
  ---@param values string[]|nil
  ---@param enum_desc table<string, string>|nil
  local function check_enum_desc(label, values, enum_desc)
    for value, text in pairs(enum_desc or {}) do
      ok(
        vim.tbl_contains(values or {}, value),
        ("%s: enum_desc names '%s', which is not one of its values"):format(label, value)
      )
      ok(
        not text:find("%.$") and not text:find("[\r\n]"),
        label .. ": enum_desc '" .. value .. "' is one line"
      )
    end
  end
  for _, route in ipairs(routes.routes({ flat = true })) do
    for _, flag in ipairs(route.flags or {}) do
      local label = ("%s --%s"):format(table.concat(route.path, " "), flag.name)
      check_text(label, flag.desc)
      -- a completion-only `values` list is not shown with its texts, so a text there would never appear
      ok(
        flag.enum_desc == nil or flag.enum ~= nil,
        label .. ": enum_desc needs an enum to be shown"
      )
      check_enum_desc(label, flag.enum, flag.enum_desc)
    end
    for _, kv in ipairs(route.kv or {}) do
      local label = ("%s %s="):format(table.concat(route.path, " "), kv.key)
      check_text(label, kv.desc)
      check_enum_desc(label, kv.enum or kv.values, kv.enum_desc)
    end
  end
  -- the check above must not pass for the wrong reason (a route table without options)
  ok(seen >= 100, "the route tree carries the options of all subcommands, saw " .. seen)

  -- Positional arguments: the text is the argument's own `desc`, else the one of its (custom) type. A built-in type
  -- (`FILE`) explains itself, so a text there is optional -- but if there is one it has the same shape.
  local types_ok, argtypes = pcall(require, "lib.nvim.bindings.usercmd.composer.argtypes")
  ok(types_ok, "the composer argument types load")
  local args_seen = 0
  for _, route in ipairs(routes.routes({ flat = true })) do
    for _, arg in ipairs(route.args or {}) do
      local label = ("%s <%s>"):format(table.concat(route.path, " "), arg.name)
      local def = arg.type and argtypes.get(arg.type) or nil
      local text = arg.desc or (def and def.desc)
      if text ~= nil then
        check_text(label, text)
        args_seen = args_seen + 1
      end
      -- shown by the float for `enum` and `values` alike
      check_enum_desc(label, arg.enum or arg.values, arg.enum_desc)
    end
  end
  ok(args_seen >= 15, "the route tree carries the arguments of all subcommands, saw " .. args_seen)

  -- the two types the arguments share say what they are once, for every argument without a text of its own
  for _, name in ipairs({ "TASK_AREA", "TASK_ID" }) do
    check_text("type " .. name, argtypes.get(name).desc)
  end
end
