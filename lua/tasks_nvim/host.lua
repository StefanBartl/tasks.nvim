---@module 'tasks_nvim.host'
---@brief The persistent engine process: the machine contract over a line protocol on stdin and stdout.
---@description
--- `nvim --headless -u NONE -l scripts/tasks-host.lua` does what `tasks call <method>` does, many times in one
--- process: the modules are loaded once and a scan of a vault that did not change is answered from the parse cache
--- (`model`, keyed by size and modification time, with the racy-file rule), so a question costs milliseconds and not
--- a process start. Nothing else changes: the answers are the documents of `tasks_nvim.api`, byte for byte.
---
--- The protocol, one line each way, UTF-8, `\t` separates the fields, a line ends with `\n`:
---
---     host -> client   `ready\t1`                      once, when the modules are loaded
---     client -> host   `<id>\t<method>\t<params>`      `<id>` digits; `<params>` is the JSON of the request
---                                                      (empty: none); no line break may be in it
---     host -> client   `<id>\t<document>`              the document `api.call` answers, on one line
---
--- The host ends when its stdin ends. A request is answered completely before the next is read (the engine's lock
--- is not re-entrant, and the client keeps one question in flight). A line that is not a request is told on stderr
--- and skipped; a method or parameter that the dispatcher does not accept is the dispatcher's own error document.
---
--- Not its job: finding the vault or lib.nvim (`scripts/tasks-host.lua`), the document (`api`, `contract`).

local api = require("tasks_nvim.api")

local M = {}

---The version of the line protocol (the number after `ready`).
M.PROTOCOL = 1

---The longest line that is read: a request is at most `api.MAX_REQUEST_BYTES`, plus the id and the method.
M.MAX_LINE_BYTES = api.MAX_REQUEST_BYTES + 256

---Answer one request line.
---@param line string
---@return string|nil reply   # `<id>\t<document>`, or nil for a line that is not a request.
function M.handle(line)
  line = line:gsub("\r$", "")
  local id, method, params = line:match("^(%d+)\t([%w_]+)\t?(.*)$")
  if not id or #id > 15 then
    return nil
  end
  local request = nil
  if params ~= "" then
    local def = api.METHODS[method]
    -- `ops` carries its fields at the top of the request; the read methods carry theirs under `params`
    request = (def and def.flat) and params or ('{"params":' .. params .. "}")
  end
  local ok, text = pcall(api.call, method, request, {})
  if not ok then
    text =
      '{"code":"internal","kind":"tasks.error","message":"the host failed on this request","plugin":"tasks.nvim","retryable":false,"schema":1}'
  end
  -- A document is one line: a line break in it could only be whitespace between tokens.
  text = text:gsub("[\r\n]", " ")
  return id .. "\t" .. text
end

---Serve until `input` ends.
---@param input file*   # Lines in (`io.stdin`).
---@param output file*  # Lines out (`io.stdout`).
---@param warn? fun(text: string)
function M.serve(input, output, warn)
  warn = warn or function(text)
    io.stderr:write(text .. "\n")
  end
  output:write("ready\t" .. M.PROTOCOL .. "\n")
  output:flush()
  while true do
    local line = input:read("l")
    if line == nil then
      return
    end
    if #line > M.MAX_LINE_BYTES then
      warn("host: a line of " .. #line .. " bytes is skipped")
    else
      local reply = M.handle(line)
      if reply then
        output:write(reply .. "\n")
        output:flush()
      elseif line ~= "" then
        warn("host: a line that is not a request is skipped")
      end
    end
  end
end

return M
