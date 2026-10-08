-- TESTS/tasks_usrcmds_help_spec.lua -- every flag, key=value pair and positional argument of :Tasks, and of the
-- nested routes a host mounts under its own verb (`:MyPlugins tasks|task|open ...`), has a line in lib.nvim's option
-- float.
--
-- The text is the `desc` of each FlagSpec / KvSpec / ArgSpec in `tasks_nvim.ui.routes` (a few values carry an
-- `enum_desc`); an argument without a `desc` of its own gets the one of its type (`register_type`). An option without
-- one shows up as a bare row in the cheatsheet, so this fails until it is described. The same word means different
-- things on different routes (`to`, `format`, `status`, `actor`, `area`, ...): `undocumented` is asked per route, so
-- each route needs its own, correct text.

return function(H)
  local ok, eq = H.ok, H.eq

  local loaded, composer = pcall(require, "lib.nvim.bindings.usercmd.composer")
  ok(loaded, "the composer loads")

  -- A lib.nvim older than `help.undocumented` cannot answer the question; that is a missing feature of the
  -- dependency, not a defect of this plugin.
  if type(composer.help.undocumented) ~= "function" then
    return
  end

  local routes = require("tasks_nvim.ui.routes")
  local usrcmds = require("tasks_nvim.bindings.usrcmds")

  -- the real :Tasks (flat grammar), and a verb with the nested grammar `:MyPlugins` gets
  ok(usrcmds.register(), ":Tasks registers")
  ok(composer.registry().Tasks ~= nil, ":Tasks is registered through the composer")
  routes.register_types()
  composer.verb("TaskHelpNested", { routes = routes.routes() })

  for _, verb in ipairs({ "Tasks", "TaskHelpNested" }) do
    local missing = {}
    for _, m in ipairs(composer.help.undocumented(verb, { args = true })) do
      local option = m.name .. "="
      if m.kind == "flag" then
        option = "--" .. m.name
      elseif m.kind == "arg" then
        option = "<" .. m.name .. ">"
      end
      missing[#missing + 1] = ("%s %s"):format(m.route, option)
    end
    eq(
      #missing,
      0,
      ("every :%s option has a help text, missing: %s"):format(verb, table.concat(missing, ", "))
    )
  end

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

  pcall(vim.api.nvim_del_user_command, "TaskHelpNested")
end
