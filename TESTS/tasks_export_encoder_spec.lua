-- TESTS/tasks_export_encoder_spec.lua -- what a client of `tasks-export/1` can rely on from the encoder.
--
-- The encoder is `lib.nvim.json.canonical` (through `contract.encode`) and has its own specs in lib.nvim; this spec
-- stays here because the contract promises these bytes to apps outside both repositories (the goldens pin whole
-- documents, this pins the rules one by one): an empty container keeps its kind, a number that JSON cannot hold
-- is an error and not a wrong digit, and a document is safe inside a <script> block and a JavaScript string.

return function(H)
  local eq, ok, has = H.eq, H.ok, H.has
  local contract = require("tasks_nvim.contract")
  local json = require("lib.nvim.json.canonical")

  ---@param value any
  ---@return string text
  local function bytes(value)
    local text, err = contract.encode(value)
    ok(text, "expected bytes, got " .. vim.inspect(err))
    return text
  end

  ---@param value any
  ---@return string message
  local function refused(value)
    local text, err = contract.encode(value)
    eq(text, nil, "expected an error")
    eq(err.code, "internal", "a value JSON cannot hold is an internal error, never a document")
    return err.message
  end

  -- ── empty object versus empty array ──
  eq(bytes({ list = {} }), '{"list":[]}', "an empty table is an array")
  eq(bytes({ meta = json.object({}) }), '{"meta":{}}', "an object that is empty stays an object")
  eq(
    bytes({ meta = json.object({}), tags = {} }),
    '{"meta":{},"tags":[]}',
    "the two kinds side by side, keys in byte order"
  )
  eq(
    bytes(contract.error_doc({ code = "x", message = "m", details = {} }, nil)):match(
      '"details":(%b{})'
    ),
    "{}",
    "an error document with empty details writes an object"
  )

  -- ── numbers ──
  eq(bytes({ 16, 16.0, 0, -0.0 }), "[16,16,0,0]", "a whole number has no fraction, -0 is 0")
  eq(bytes({ 2 ^ 53 - 1 }), "[9007199254740991]", "the largest whole number that is exact")
  has(refused({ 2 ^ 53 }), "2^53", "a whole number that would lose digits")
  has(refused({ 0 / 0 }), "no NaN or inf", "NaN")
  has(refused({ math.huge }), "no NaN or inf", "inf")
  has(refused({ -math.huge }), "no NaN or inf", "-inf")
  has(refused({ a = { b = { 0 / 0 } } }), "$.a.b[1]", "the error names the place in the document")

  -- ── escaping ──
  eq(
    bytes({ "</script><!--" }),
    '["\\u003c/script>\\u003c!--"]',
    "< is escaped: safe in a <script> block"
  )
  eq(
    bytes({ "a\226\128\168b\226\128\169" }),
    '["a\\u2028b\\u2029"]',
    "U+2028 and U+2029 are escaped: safe in a JavaScript string"
  )
  eq(bytes({ 'a"b\\c' }), '["a\\"b\\\\c"]', "quote and backslash")
  eq(bytes({ "\1\31" }), '["\\u0001\\u001f"]', "control bytes")
  eq(
    bytes({ "Gr\195\182\195\159e \230\151\165" }),
    '["Gr\195\182\195\159e \230\151\165"]',
    "valid UTF-8 is kept as it is"
  )
  eq(
    bytes({ "a\255b" }),
    '["a\239\191\189b"]',
    "a bad byte becomes U+FFFD, the document stays valid JSON"
  )
end
