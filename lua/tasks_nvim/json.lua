---@module 'tasks_nvim.json'
---@brief The canonical JSON encoder of the contract documents: same value, same bytes, on every machine.
---@description
--- `vim.json.encode` is not good enough for a contract: it writes `{}` as `[]` (an empty Lua table has no type), the
--- order of object keys is whatever `pairs` gives, a float is cut to 16 digits, and `NaN` is an error only some of the
--- time. A document that is hashed (`digest`, `etag`, golden files) needs a writer with rules:
---
---  - object keys sorted by byte value; an object that may be empty is made with `M.object({})`, an array that may be
---    empty is just `{}` (the default for an empty table) or `M.array({})`; `vim.NIL` is `null`
---  - numbers: a whole number below 2^53 is written without a fraction, any other number with the fewest digits that
---    read back as the same number; `NaN`, `inf` and a whole number of 2^53 or more are an ERROR (a silent loss of
---    digits is the worst answer a contract can give); `-0` is `0`
---  - strings: valid UTF-8 (a bad byte becomes U+FFFD), every control byte, `"`, `\`, U+2028, U+2029 and `<` escaped:
---    the text can sit inside a `<script>` block as it is
---  - no whitespace (the form that is hashed); `indent` gives the same document readable (golden files)
---  - a table that is neither a list nor an object (holes, mixed keys) is an error that names the path
---
--- Not its job: what a document contains (`contract`), reading JSON (`vim.json.decode` is fine for that).

local M = {}

---Marks a table as a JSON object even when it is empty or has no string keys yet.
local OBJECT = { "tasks_nvim.json.object" }
local ARRAY = { "tasks_nvim.json.array" }

---A table that is an OBJECT, empty or not.
---@generic T: table
---@param t? T
---@return T
function M.object(t)
  return setmetatable(t or {}, OBJECT)
end

---A table that is an ARRAY, empty or not (an empty unmarked table is one too).
---@generic T: table
---@param t? T
---@return T
function M.array(t)
  return setmetatable(t or {}, ARRAY)
end

---Most nesting we accept: a cycle in the data must fail, not hang.
local MAX_DEPTH = 64

---Whole numbers at or above this cannot be told apart from their neighbours in a double.
local MAX_SAFE = 2 ^ 53

---@param n number
---@return string
local function number(n, path)
  if n ~= n or n == math.huge or n == -math.huge then
    error(("json: %s is %s; a contract has no NaN or inf"):format(path, tostring(n)), 0)
  end
  if n == math.floor(n) then
    if math.abs(n) >= MAX_SAFE then
      error(
        ("json: %s is %s, a whole number of 2^53 or more (digits would be lost)"):format(
          path,
          ("%.0f"):format(n)
        ),
        0
      )
    end
    return ("%d"):format(n) -- also turns -0 into 0
  end
  for digits = 15, 17 do
    local text = ("%." .. digits .. "g"):format(n)
    if tonumber(text) == n then
      return text
    end
  end
  return ("%.17g"):format(n)
end

local ESCAPES = {
  ['"'] = '\\"',
  ["\\"] = "\\\\",
  ["\b"] = "\\b",
  ["\f"] = "\\f",
  ["\n"] = "\\n",
  ["\r"] = "\\r",
  ["\t"] = "\\t",
  ["<"] = "\\u003c",
  ["\127"] = "\\u007f",
}

---Valid UTF-8 or the same text with every bad byte replaced by U+FFFD.
---@param s string
---@return string
local function scrub(s)
  if not s:find("[\128-\255]") then
    return s
  end
  local out, i, n = {}, 1, #s
  while i <= n do
    local b = s:byte(i)
    local len = 0
    if b < 0x80 then
      len = 1
    elseif b >= 0xC2 and b <= 0xDF then
      len = 2
    elseif b >= 0xE0 and b <= 0xEF then
      len = 3
    elseif b >= 0xF0 and b <= 0xF4 then
      len = 4
    end
    local ok = len > 0 and i + len - 1 <= n
    if ok and len > 1 then
      for j = 1, len - 1 do
        local c = s:byte(i + j)
        if c < 0x80 or c > 0xBF then
          ok = false
          break
        end
      end
      if ok then
        local c1 = s:byte(i + 1)
        -- overlong forms, surrogates and everything above U+10FFFF
        if
          (b == 0xE0 and c1 < 0xA0)
          or (b == 0xED and c1 > 0x9F)
          or (b == 0xF0 and c1 < 0x90)
          or (b == 0xF4 and c1 > 0x8F)
        then
          ok = false
        end
      end
    end
    if ok then
      out[#out + 1] = s:sub(i, i + len - 1)
      i = i + len
    else
      out[#out + 1] = "\239\191\189"
      i = i + 1
    end
  end
  return table.concat(out)
end

---@param s string
---@return string
local function string_(s)
  s = scrub(s)
  s = s:gsub('[%c"\\<\127]', function(c)
    return ESCAPES[c] or ("\\u%04x"):format(c:byte())
  end)
  s = s:gsub("\226\128[\168\169]", function(c)
    return c:byte(3) == 168 and "\\u2028" or "\\u2029"
  end)
  return '"' .. s .. '"'
end

---Object, list or error: what a table is, and its keys in the order they are written.
---@param t table
---@param path string
---@return "object"|"array"
---@return (string|integer)[] keys
local function shape(t, path)
  local mt = getmetatable(t)
  local count, max, strings = 0, 0, 0
  for k in pairs(t) do
    count = count + 1
    if type(k) == "number" and k >= 1 and k == math.floor(k) then
      if k > max then
        max = k
      end
    elseif type(k) == "string" then
      strings = strings + 1
    else
      error(("json: %s has a key of type %s"):format(path, type(k)), 0)
    end
  end
  if mt == OBJECT or (mt ~= ARRAY and strings > 0) then
    if count ~= strings then
      error(("json: %s mixes list and object keys"):format(path), 0)
    end
    local keys = {}
    for k in pairs(t) do
      keys[#keys + 1] = k
    end
    table.sort(keys)
    return "object", keys
  end
  if strings > 0 or max ~= count then
    error(
      ("json: %s is not a list (holes or a string key); mark it with json.object if it is an object"):format(
        path
      ),
      0
    )
  end
  local keys = {}
  for i = 1, count do
    keys[i] = i
  end
  return "array", keys
end

---@class Tasks.JsonOpts
---@field indent? integer  # Spaces per level: the readable form (golden files). Default: compact, the form that is hashed.

---@param value any
---@param opts? Tasks.JsonOpts
---@return string
function M.encode(value, opts)
  local indent = opts and opts.indent
  local out = {}
  local function put(v, depth, path)
    local ty = type(v)
    if v == nil or v == vim.NIL then
      out[#out + 1] = "null"
    elseif ty == "boolean" then
      out[#out + 1] = v and "true" or "false"
    elseif ty == "number" then
      out[#out + 1] = number(v, path)
    elseif ty == "string" then
      out[#out + 1] = string_(v)
    elseif ty == "table" then
      if depth > MAX_DEPTH then
        error(("json: %s is nested deeper than %d levels (a cycle?)"):format(path, MAX_DEPTH), 0)
      end
      local kind, keys = shape(v, path)
      local open, close = "[", "]"
      if kind == "object" then
        open, close = "{", "}"
      end
      if #keys == 0 then
        out[#out + 1] = open .. close
        return
      end
      out[#out + 1] = open
      local pad = indent and ("\n" .. string.rep(" ", indent * (depth + 1))) or ""
      for i, k in ipairs(keys) do
        if i > 1 then
          out[#out + 1] = ","
        end
        out[#out + 1] = pad
        if kind == "object" then
          out[#out + 1] = string_(k) .. (indent and ": " or ":")
          put(v[k], depth + 1, path .. "." .. k)
        else
          put(v[k], depth + 1, path .. "[" .. k .. "]")
        end
      end
      out[#out + 1] = (indent and ("\n" .. string.rep(" ", indent * depth)) or "") .. close
    else
      error(("json: %s is a %s, which JSON cannot hold"):format(path, ty), 0)
    end
  end
  put(value, 0, "$")
  return table.concat(out)
end

return M
