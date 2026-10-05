-- TESTS/tasks_config_spec.lua -- tasks_nvim.config (validation, merge) and the health check.

return function(H)
  local eq, ok = H.eq, H.ok
  local config = require("tasks_nvim.config")

  eq(config.validate(nil), {}, "nil is no options")
  eq(config.validate("x"), {}, "a non-table is ignored")
  eq(
    config.validate({ vault = 3, extra_areas = "A", nope = true }),
    {},
    "wrong types and unknown keys are dropped"
  )
  eq(config.validate({ extra_areas = { "A", 2 } }), {}, "a list with a non-string is dropped")
  eq(
    config.validate({ extra_areas = { "A", "B" } }).extra_areas,
    { "A", "B" },
    "a string list passes"
  )
  eq(config.validate({ vault = "/x/y/" }).vault, "/x/y", "the vault path is normalised")

  local before = vim.deepcopy(config.get())
  config.merge({ extra_areas = { "Z" } })
  eq(config.get().extra_areas, { "Z" }, "merge keeps what passed")
  config.merge({ extra_areas = 5 })
  eq(config.get().extra_areas, { "Z" }, "a bad value does not overwrite a good one")
  config.merge(before)

  -- sections: checked key by key, merged key by key
  eq(
    config.validate({ dashboard = { watch = false, debounce_ms = 100 } }).dashboard,
    { watch = false, debounce_ms = 100 },
    "a valid section passes"
  )
  eq(
    config.validate({ dashboard = { watch = "no", debounce_ms = -5, nope = 1 } }).dashboard,
    {},
    "wrong types, a non-positive number and unknown sub-keys are dropped, the section stays"
  )
  eq(config.validate({ dashboard = 5 }).dashboard, nil, "a section that is no table is dropped")
  eq(config.validate({ ci = { lint_timeout_ms = 1.5 } }).ci, {}, "a timeout must be a whole number")
  eq(
    config.validate({ staleness = { repo_bases = { "/r" } } }).staleness.repo_bases,
    { "/r" },
    "repo_bases is a string list"
  )
  config.merge({ dashboard = { watch = false } })
  eq(config.get().dashboard, { watch = false, debounce_ms = 250 }, "a section merges key by key")
  config.merge({ dashboard = { watch = true } })
  eq(config.get().dashboard.watch, true)
  ok(#config.ignored() >= 1, "problems stay listed for :checkhealth")
  eq(require("tasks_nvim.config.DEFAULTS").ci.lint_timeout_ms, 120000, "defaults are data")

  -- keys: an action name maps to a key or to false; unknown actions are reported, not bound
  local kv = config.validate({ keys = { form = { submit = "<C-g>", cancel = false, nope = "x" } } })
  eq(
    kv.keys.form,
    { submit = "<C-g>", cancel = false },
    "known actions pass, `false` is kept, unknown ones go"
  )
  eq(
    config.validate({ keys = { form = { submit = 5 } } }).keys,
    {},
    "a key that is no string or false is dropped"
  )
  eq(config.validate({ keys = { nowhere = {} } }).keys, {}, "an unknown key section is dropped")
  eq(config.get().keys.form.submit, "<C-s>", "the defaults are the documented keys")

  -- the form binds what the configuration says
  local form_ui = require("tasks_nvim.ui.form")
  local function map_of(lhs)
    return vim.fn.maparg(lhs, "n", false, true)
  end
  config.merge({ keys = { form = { submit = "<C-g>", cancel = false } } })
  local fbuf = form_ui.open({
    areas = { "a" },
    on_submit = function() end,
  })
  ok(map_of("<C-g>").buffer == 1, "the configured submit key is bound in the form")
  ok(next(map_of("q")) == nil, "`false` leaves the action unbound")
  ok(map_of("<C-s>").buffer ~= 1, "and the default key is not bound when it was replaced")
  form_ui.close(fbuf)
  config.merge({ keys = { form = { submit = "<C-s>", cancel = "q" } } })

  -- the health check reads only; it must not throw with or without a vault
  local vault = require("tasks_nvim.vault")
  vault.set_root(nil)
  local saved = vim.env.TASKS_VAULT
  vim.env.TASKS_VAULT = nil
  local called = {}
  local real_health = vim.health
  vim.health = setmetatable({
    start = function(m)
      called[#called + 1] = m
    end,
  }, {
    __index = function()
      return function() end
    end,
  })
  local ran, err = pcall(require("tasks_nvim.health").check)
  vim.health = real_health
  vim.env.TASKS_VAULT = saved
  ok(ran, "health.check does not throw: " .. tostring(err))
  ok(#called >= 1, "health.check reports sections")
end
