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
