-- Checks lua/rex_reviewer/json.lua, the JSON rex-reviewer uses outside Rex,
-- against what rex.json writes for the same values. Run it with LuaJIT:
-- `luajit tests/json.lua`.

local ROOT = debug.getinfo(1, "S").source:gsub("^@", ""):match("^(.*)/tests/[^/]+$") or "."
package.path = ROOT .. "/lua/?.lua;" .. package.path
local json = require("rex_reviewer.json")

local count = { pass = 0, fail = 0 }
local function check(name, got, want)
  if got == want then
    count.pass = count.pass + 1
  else
    count.fail = count.fail + 1
    print(string.format("FAIL %s\n  got:  %s\n  want: %s", name, tostring(got), tostring(want)))
  end
end

-- What rex.json.encode wrote for each value, in Rex.
check("empty table", json.encode({}), "{}")
check("array", json.encode({ 1, 2, 3 }), "[1,2,3]")
check("object, sorted, nested", json.encode({ a = 1, b = 1.5, c = "x\ny/é\"", d = true, e = {}, f = { x = { 1 } } }),
  '{"a":1,"b":1.5,"c":"x\\ny/é\\"","d":true,"e":{},"f":{"x":[1]}}')
check("1e15", json.encode(1e15), "1000000000000000")
check("2^53", json.encode(2 ^ 53), "9007199254740992")
check("-0.1", json.encode(-0.1), "-0.1")
check("sparse array", json.encode({ [1] = "a", [3] = "c" }), '{"1":"a","3":"c"}')
check("control characters", json.encode("\1\127"), '"\\u0001\127"')
check("key order", json.encode({ z = 1, a = 2, m = 3 }), '{"a":2,"m":3,"z":1}')
check("a third", json.encode(1 / 3), "0.3333333333333333")

-- What rex.json.decode read.
local d = json.decode('{"a":null,"b":[1,null,3],"c":"\\u00e9\\ud83d\\ude00","n":10,"f":1.25,"big":12345678901234}')
check("null", d.a, nil)
check("null in an array", d.b[2], nil)
check("after null in an array", d.b[3], 3)
check("unicode escapes", d.c, "é😀")
check("integer", d.n, 10)
check("float", d.f, 1.25)
check("big integer", d.big, 12345678901234)

-- Round trips of what the ledger holds.
local entry = {
  repo = "acme/api", pr = 12, round = 2, state = "reviewing", phase = "awaiting",
  reviewers = { codex = { name = "codex", primary = true, session = "019a-…" } },
  history = { { round = 1, verdict = "REQUEST_CHANGES", blocking = 2, tokens = 123456 } },
  title = "Retry \"payments\" on\ttimeouts", empty = {},
}
check("round trip", json.encode(json.decode(json.encode(entry))), json.encode(entry))
check("whitespace", json.encode(json.decode(' { "a" : [ 1 , 2 ] , "b" : { } } ')), '{"a":[1,2],"b":{}}')
check("escapes", json.decode('"\\/\\b\\f\\n\\r\\t\\\\"'), "/\b\f\n\r\t\\")
check("negative exponent", json.decode("-1.5e-3"), -0.0015)
check("bad JSON", pcall(json.decode, '{"a":}'), false)
check("trailing text", pcall(json.decode, "{} x"), false)
check("a table in itself", (function()
  local t = {}
  t.t = t
  return pcall(json.encode, t)
end)(), false)

print(string.format("%d passed, %d failed", count.pass, count.fail))
os.exit(count.fail == 0 and 0 or 1)
