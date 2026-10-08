-- TESTS/tasks_usrcmds_help_spec.lua -- every flag, key=value pair and positional argument of :Tasks, and of the
-- nested routes a host mounts under its own verb (`:MyPlugins tasks|task|open ...`), has a line in lib.nvim's option
-- float.
--
-- The text is the `desc` of each FlagSpec / KvSpec / ArgSpec in `tasks_nvim.ui.routes` (a few values carry an
-- `enum_desc`); an argument without a `desc` of its own gets the one of its type (`register_type`). An option without
-- one shows up as a bare row in the cheatsheet, so this fails until it is described. The same word means different
-- things on different routes (`to`, `format`, `status`, `actor`, `area`, ...): `undocumented` is asked per route, so
-- each route needs its own, correct text.
--
-- The shape of the texts (one line, no closing full stop, length, `enum_desc` keys) is tasks_usrcmds_help_style_spec.lua,
-- which needs no `undocumented` and so always runs; this file skips on a lib.nvim that cannot answer the question.

return function(H)
  local ok, eq = H.ok, H.eq

  local loaded, composer = pcall(require, "lib.nvim.bindings.usercmd.composer")
  -- A lib.nvim older than `help.undocumented` cannot answer the question; that is a missing feature of the
  -- dependency, not a defect of this plugin. Older still, `composer.help` does not exist at all, and where the module
  -- is gone the lazy `composer.help` raises on the first key: ask through pcall. A composer that does not load at all
  -- is no skip, it fails below.
  local asked, undocumented = pcall(function()
    return composer.help.undocumented
  end)
  if loaded and (not asked or type(undocumented) ~= "function") then
    -- This sits before the first assertion on purpose: testing.nvim turns a printed `skip` line into a SKIP only for a
    -- spec that has asserted nothing (a spec that asserted first keeps its verdict, a green PASS).
    io.stdout:write(
      "skip  tasks_usrcmds_help_spec.lua: lib.nvim has no composer.help.undocumented\n"
    )
    return
  end
  ok(loaded, "the composer loads")

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

  pcall(vim.api.nvim_del_user_command, "TaskHelpNested")
end
