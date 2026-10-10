-- TESTS/tasks_html_spec.lua -- scripts/tasks-html.lua (a real child Neovim): the one-file overview of the vault.

return function(H)
  local eq, ok, has, lacks = H.eq, H.ok, H.has, H.lacks
  local F = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/fixture.lua")

  local root = F.vault(H)
  local hostile = "</script><img src=x onerror=alert(1)> Tom & Jerry"
  F.task(
    H,
    root,
    "lib.nvim",
    "plain",
    F.meta("A plain task", "open", { { "prio", "1" }, { "effort", "S" } })
  )
  F.task(H, root, "lib.nvim", "evil", F.meta('"' .. hostile .. '"', "doing", { { "prio", "2" } }))
  F.task(H, root, "cascade.nvim", "later", F.meta("Parked for later", "parked"))

  local script = vim.fs.normalize(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h"))
    .. "/scripts/tasks-html.lua"
  ok(H.exists(script), "scripts/tasks-html.lua exists: " .. script)

  --- Run the script in a child Neovim.
  ---@param argv string[]
  ---@return { code: integer, stdout: string, stderr: string }
  local function child(argv)
    local cmd = { vim.v.progpath, "-n", "-i", "NONE", "--headless", "-u", "NONE", "-l", script }
    vim.list_extend(cmd, argv)
    return vim
      .system(cmd, {
        text = true,
        env = { NVIM = vim.NIL, NVIM_LISTEN_ADDRESS = vim.NIL },
      })
      :wait(60000)
  end

  local out = H.tmpdir() .. "/overview.html"
  local r = child({ "--vault=" .. root, "--out=" .. out })
  eq(r.code, 0, "exit code; stderr: " .. tostring(r.stderr))
  has(r.stdout, "wrote ")
  ok(H.exists(out), "the file is written")

  local html = H.read(out)
  has(html, "<!doctype html>")
  has(html, 'id="data"')
  has(html, "lib.nvim/plain", "a task of the vault is in the data")
  has(html, "cascade.nvim/later", "a parked task is in the data")
  lacks(html, "__DATA__", "the placeholder is replaced")
  lacks(html, ".innerHTML", "the page builds its DOM with textContent only")

  -- The data block is JSON, and a title cannot close it.
  local data_block = html:match('<script type="application/json" id="data">(.-)</script>')
  ok(data_block ~= nil, "the data block is closed by its own </script>")
  lacks(data_block, "<", "every < in the data is escaped")
  local data = vim.json.decode(data_block)
  eq(#data.tasks, 3, "three open tasks")
  local titles = {}
  for _, t in ipairs(data.tasks) do
    titles[t.id] = t.title
  end
  has(titles["lib.nvim/evil"], hostile, "the hostile title survives intact in the data")
  eq(titles["lib.nvim/plain"], "A plain task")

  -- --area narrows the listing; a bad argument is a usage error.
  local out2 = H.tmpdir() .. "/cascade.html"
  r = child({ "--vault=" .. root, "--out=" .. out2, "--area=cascade.nvim" })
  eq(r.code, 0, "area run; stderr: " .. tostring(r.stderr))
  local d2 =
    vim.json.decode(H.read(out2):match('<script type="application/json" id="data">(.-)</script>'))
  eq(#d2.tasks, 1, "only the cascade.nvim task")
  r = child({ "--nope" })
  eq(r.code, 2, "an argument without a value is refused")
  has(r.stderr, "unknown argument")

  -- an area that could pass for an option, a list or a path is refused before any command runs
  for _, bad in ipairs({ "--x", "@list", "a/b", "..", "-" }) do
    r = child({ "--vault=" .. root, "--out=" .. out, "--area=" .. bad })
    eq(r.code, 2, "area " .. bad)
    has(r.stderr, "unusable value")
  end

  -- --exclude leaves an area out everywhere, and the file never names the vault's folder
  local out3 = H.tmpdir() .. "/excluded.html"
  r = child({ "--vault=" .. root, "--out=" .. out3, "--exclude=cascade.nvim" })
  eq(r.code, 0, "exclude run; stderr: " .. tostring(r.stderr))
  local text3 = H.read(out3)
  local d3 = vim.json.decode(text3:match('<script type="application/json" id="data">(.-)</script>'))
  eq(#d3.tasks, 2, "the cascade.nvim task is gone")
  lacks(text3, "cascade.nvim", "... from the Today card and every other place")
  lacks(text3, root, "the file holds no path of this machine")
  lacks(text3, vim.fs.normalize(root), "... in either spelling")
  r = child({ "--vault=" .. root, "--out=" .. out3, "--exclude=a,../b" })
  eq(r.code, 2, "a bad name in --exclude is refused")
end
