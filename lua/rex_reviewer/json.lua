-- JSON for Lua outside Rex, written to match rex.json byte for byte where
-- the ledger can tell: keys sorted, an empty table as {}, a table with keys
-- 1..n as an array and any other as an object, control characters as
-- \u00XX, and numbers in their shortest form that reads back the same.
-- null decodes to nil.

local M = {}

local ESCAPES = {
  ['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f",
  ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t",
}

local function quote(s)
  return '"' .. s:gsub('[%c"\\]', function(ch)
    return ESCAPES[ch] or (ch == "\127" and ch) or string.format("\\u%04x", ch:byte())
  end) .. '"'
end

local function number(n)
  if n ~= n or n == math.huge or n == -math.huge then
    error("JSON can't hold " .. tostring(n), 0)
  end
  if n == math.floor(n) and math.abs(n) < 2 ^ 63 then
    return string.format("%d", n)
  end
  for digits = 15, 17 do
    local s = string.format("%." .. digits .. "g", n)
    if tonumber(s) == n then
      return s
    end
  end
  return string.format("%.17g", n)
end

local function is_array(t)
  local n = 0
  for k in pairs(t) do
    if type(k) ~= "number" or k < 1 or k ~= math.floor(k) then
      return false
    end
    n = n + 1
  end
  for i = 1, n do
    if t[i] == nil then
      return false
    end
  end
  return n > 0, n
end

local encode

local function encode_table(t, seen)
  if seen[t] then
    error("JSON can't hold a table that contains itself", 0)
  end
  seen[t] = true
  local out = {}
  local array, n = is_array(t)
  if array then
    for i = 1, n do
      out[i] = encode(t[i], seen)
    end
    seen[t] = nil
    return "[" .. table.concat(out, ",") .. "]"
  end
  local keys = {}
  for k in pairs(t) do
    if type(k) ~= "string" and type(k) ~= "number" then
      error("JSON object keys must be strings or numbers, not " .. type(k), 0)
    end
    keys[#keys + 1] = tostring(k)
  end
  table.sort(keys)
  for i, k in ipairs(keys) do
    local v = t[k]
    if v == nil then
      v = t[tonumber(k)]
    end
    out[i] = quote(k) .. ":" .. encode(v, seen)
  end
  seen[t] = nil
  return "{" .. table.concat(out, ",") .. "}"
end

encode = function(v, seen)
  local kind = type(v)
  if kind == "nil" then
    return "null"
  elseif kind == "boolean" then
    return v and "true" or "false"
  elseif kind == "number" then
    return number(v)
  elseif kind == "string" then
    return quote(v)
  elseif kind == "table" then
    return encode_table(v, seen)
  end
  error("JSON can't hold a " .. kind, 0)
end

function M.encode(v)
  return encode(v, {})
end

---------------------------------------------------------------------------
-- Decoding

local function utf8_char(cp)
  if cp < 0x80 then
    return string.char(cp)
  elseif cp < 0x800 then
    return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40)
  elseif cp < 0x10000 then
    return string.char(0xE0 + math.floor(cp / 0x1000), 0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
  end
  return string.char(0xF0 + math.floor(cp / 0x40000), 0x80 + math.floor(cp / 0x1000) % 0x40,
    0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
end

local UNESCAPES = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }

local function fail(s, i, what)
  error(string.format("bad JSON at byte %d: %s", i, what), 0)
end

local function skip(s, i)
  return s:find("[^ \t\r\n]", i) or #s + 1
end

local value

local function string_at(s, i)
  local out, j = {}, i + 1
  while true do
    local k = s:find('["\\]', j)
    if not k then
      fail(s, i, "unterminated string")
    end
    out[#out + 1] = s:sub(j, k - 1)
    if s:sub(k, k) == '"' then
      return table.concat(out), k + 1
    end
    local esc = s:sub(k + 1, k + 1)
    if esc == "u" then
      local cp = tonumber(s:sub(k + 2, k + 5), 16)
      if not cp then
        fail(s, k, "bad \\u escape")
      end
      j = k + 6
      if cp >= 0xD800 and cp < 0xDC00 and s:sub(j, j + 1) == "\\u" then
        local lo = tonumber(s:sub(j + 2, j + 5), 16)
        if lo and lo >= 0xDC00 and lo < 0xE000 then
          cp = 0x10000 + (cp - 0xD800) * 0x400 + (lo - 0xDC00)
          j = j + 6
        end
      end
      out[#out + 1] = utf8_char(cp)
    elseif UNESCAPES[esc] then
      out[#out + 1] = UNESCAPES[esc]
      j = k + 2
    else
      fail(s, k, "bad escape")
    end
  end
end

value = function(s, i)
  i = skip(s, i)
  local ch = s:sub(i, i)
  if ch == "{" then
    local t = {}
    i = skip(s, i + 1)
    if s:sub(i, i) == "}" then
      return t, i + 1
    end
    while true do
      if s:sub(i, i) ~= '"' then
        fail(s, i, "expected a key")
      end
      local k
      k, i = string_at(s, i)
      i = skip(s, i)
      if s:sub(i, i) ~= ":" then
        fail(s, i, "expected :")
      end
      t[k], i = value(s, i + 1)
      i = skip(s, i)
      local sep = s:sub(i, i)
      if sep == "}" then
        return t, i + 1
      elseif sep ~= "," then
        fail(s, i, "expected , or }")
      end
      i = skip(s, i + 1)
    end
  elseif ch == "[" then
    local t, n = {}, 0
    i = skip(s, i + 1)
    if s:sub(i, i) == "]" then
      return t, i + 1
    end
    while true do
      n = n + 1
      t[n], i = value(s, i)
      i = skip(s, i)
      local sep = s:sub(i, i)
      if sep == "]" then
        return t, i + 1
      elseif sep ~= "," then
        fail(s, i, "expected , or ]")
      end
      i = i + 1
    end
  elseif ch == '"' then
    return string_at(s, i)
  elseif s:sub(i, i + 3) == "true" then
    return true, i + 4
  elseif s:sub(i, i + 4) == "false" then
    return false, i + 5
  elseif s:sub(i, i + 3) == "null" then
    return nil, i + 4
  end
  local num = s:match("^-?%d+%.?%d*[eE]?[-+]?%d*", i)
  if not num or num == "" or num == "-" then
    fail(s, i, "unexpected " .. (ch == "" and "end" or ch))
  end
  return tonumber(num), i + #num
end

function M.decode(s)
  if type(s) ~= "string" then
    error("JSON to decode must be a string", 0)
  end
  local v, i = value(s, 1)
  i = skip(s, i)
  if i <= #s then
    fail(s, i, "trailing text")
  end
  return v
end

return M
