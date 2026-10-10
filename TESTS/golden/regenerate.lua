-- Regenerates the golden files of the contract from the synthetic fixture vault.
--
--   nvim --headless -u NONE -l TESTS/golden/regenerate.lua
--
-- A golden file is what a client of `tasks-export/1` can rely on byte for byte: a change of one is a change of the
-- contract. Run this on purpose, read `git diff TESTS/golden`, and commit the files together with the code change.

local here = vim.fs.dirname(debug.getinfo(1, "S").source:sub(2))
local plugin_root = vim.fs.dirname(vim.fs.dirname(here))
vim.opt.rtp:prepend(plugin_root)

-- lib.nvim: $LIB_NVIM_DIR, else $REPOS_DIR/lib.nvim, else a sibling checkout
for _, dir in ipairs({
  vim.env.LIB_NVIM_DIR,
  vim.env.REPOS_DIR and (vim.env.REPOS_DIR .. "/lib.nvim"),
  vim.fs.dirname(plugin_root) .. "/lib.nvim",
}) do
  if dir and vim.fn.isdirectory(dir .. "/lua/lib/nvim") == 1 then
    vim.opt.rtp:append(dir)
    break
  end
end

-- the little of the spec harness the fixture builders use
local base = vim.fn.tempname()
vim.fn.mkdir(base, "p")
local counter = 0
local H = {}
function H.tmpdir()
  counter = counter + 1
  local dir = ("%s/%d"):format(base, counter)
  vim.fn.mkdir(dir, "p")
  return dir
end
function H.write(path, content)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local fh = assert(io.open(path, "wb"))
  fh:write(content)
  fh:close()
end

local fixture = dofile(here .. "/../contract_fixture.lua")
local golden = dofile(here .. "/../contract_golden.lua")
local root = fixture.build(H)

vim.fn.mkdir(golden.dir, "p")
for _, case in ipairs(golden.cases) do
  local text = golden.render(root, case)
  H.write(golden.dir .. "/" .. case.name .. ".json", text)
  io.stdout:write(("wrote %s (%d bytes)\n"):format(case.name, #text))
end
vim.fn.delete(base, "rf")
os.exit(0)
