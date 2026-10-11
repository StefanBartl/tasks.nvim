---@module 'tasks_nvim.errors'
---@brief The error vocabulary of the machine contract: a stable code, a message, whether asking again can help.
---@description
--- The engine's functions answer `nil, "text"` and, where a caller has to act on the reason, a third value
--- `{ code = ..., ... }` (`mutate.set`: `conflict`, `locked`, `forbidden`; `fsio.with_lock`: `locked`, `lock_stuck`).
--- `classify` turns whatever came back into the error a document carries. An error string with no code is matched
--- against a short list of patterns: the one fragile spot, until the code is given at every source.
---
--- Codes: `invalid_argument` (the request or a value is wrong), `not_found` (id, area, method, vault), `conflict` (the
--- file is not the version the caller saw), `exists` (the slug is taken), `forbidden` (a link in the vault), `locked`
--- (another writer holds it right now; `retryable`), `lock_stuck` (a lock nobody will release), `unsupported_schema`,
--- `payload_too_large`, `rollback_incomplete` (a failed write could not be fully undone: the message names the files),
--- `io`, `internal`.

local M = {}

---@class Tasks.ContractError
---@field code string
---@field message string
---@field retryable boolean
---@field details? table

---@param code string
---@param message string
---@param retryable? boolean
---@return Tasks.ContractError
function M.fail(code, message, retryable)
  return { code = code, message = message, retryable = retryable == true }
end

---What a reader may learn from `info` besides the code: ids, keys and values, never a path.
local DETAIL_KEYS = { "id", "key", "expected", "actual", "written", "writes" }

---An error from below the contract, as the error a document carries.
---@param err any                    # the message (or already an error table)
---@param info? table                # the third value some functions give: `{ code, retryable?, ... }`
---@return Tasks.ContractError
function M.classify(err, info)
  if type(err) == "table" and err.code then
    return err
  end
  local text = tostring(err)
  if info and info.code then
    local details = {}
    for _, key in ipairs(DETAIL_KEYS) do
      if info[key] ~= nil then
        details[key] = info[key]
      end
    end
    return {
      code = info.code,
      message = text,
      retryable = info.retryable == true or info.code == "locked",
      details = next(details) ~= nil and details or nil,
    }
  end
  local code = "internal"
  if
    text:find("vault not found", 1, true)
    or text:find("is not a directory", 1, true)
    or text:find("no such", 1, true)
    or text:find("unknown area", 1, true)
  then
    code = "not_found"
  elseif
    text:find("expected <area>/<slug>", 1, true)
    or text:find("invalid area name", 1, true)
    or text:find("nothing to set", 1, true)
  then
    code = "invalid_argument"
  elseif text:find("already exists", 1, true) then
    code = "exists"
  elseif text:find("rollback incomplete", 1, true) then
    code = "rollback_incomplete"
  elseif
    text:find("cannot list", 1, true)
    or text:find("cannot read", 1, true)
    or text:find("cannot write", 1, true)
    or text:find("cannot create", 1, true)
    or text:find("cannot update", 1, true)
    or text:find("cannot lock", 1, true)
    or text:find("permission", 1, true)
  then
    code = "io"
  elseif text:find("is being written", 1, true) then
    return M.fail("locked", text, true)
  elseif text:find("remove it by hand", 1, true) then
    return M.fail("lock_stuck", text, false)
  end
  return M.fail(code, text, false)
end

return M
