-- Checks lua/rex_reviewer/status.lua, the watcher's status records. It needs
-- no Rex: run it with any Lua 5.1, such as `luajit tests/status.lua`.

local ROOT = debug.getinfo(1, "S").source:gsub("^@", ""):match("^(.*)/tests/[^/]+$") or "."
package.path = ROOT .. "/lua/?.lua;" .. package.path
local status = require("rex_reviewer.status")

local count = { pass = 0, fail = 0 }
local function check(name, got, want)
  if got == want then
    count.pass = count.pass + 1
  else
    count.fail = count.fail + 1
    print(string.format("FAIL %s\n  got:  %s\n  want: %s", name, tostring(got), tostring(want)))
  end
end

local function b64dec(s)
  local B = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
  s = s:gsub("[^%w+/=]", "")
  return (s:gsub(".", function(x)
    if x == "=" then
      return ""
    end
    local r, f = "", (B:find(x) - 1)
    for i = 6, 1, -1 do
      r = r .. (f % 2 ^ i - f % 2 ^ (i - 1) > 0 and "1" or "0")
    end
    return r
  end):gsub("%d%d%d?%d?%d?%d?%d?%d?", function(x)
    if #x ~= 8 then
      return ""
    end
    local c = 0
    for i = 1, 8 do
      c = c + (x:sub(i, i) == "1" and 2 ^ (8 - i) or 0)
    end
    return string.char(c)
  end))
end

-- Fields of one report, with title and msg decoded.
local function fields(report)
  local body = report:match("^\27%]7501;(.*)\27\\$")
  local out = {}
  for pair in (body or ""):gmatch("[^:]+") do
    local k, v = pair:match("^([a-z]+)=(.*)$")
    if k == "title" or k == "msg" then
      v = b64dec(v)
    end
    out[k] = v
  end
  return out
end

-- base64
check("b64 empty", status.b64(""), "")
check("b64 one", status.b64("f"), "Zg==")
check("b64 two", status.b64("fo"), "Zm8=")
check("b64 three", status.b64("foo"), "Zm9v")
check("b64 utf-8", status.b64("ü→"), "w7zihpI=")

-- ids
check("id", status.item_id("acme/api", 12, 2), "pr/acme/api/12/2")
check("id dots", status.item_id("acme/web.app", 7, 1), "pr/acme/web.app/7/1")
local long = "a-very-long-repository-name-that-goes-on-and-on"
check("id long segment", status.item_id("acme/" .. long, 3, 1), "pr/acme/" .. long:sub(1, 32) .. "/3/1")

local repos = { { slug = "acme/api" }, { slug = "acme/web" } }
local repo, pr, round = status.resolve("pr/acme/web/7/3", repos)
check("resolve repo", repo, "acme/web")
check("resolve pr", pr, 7)
check("resolve round", round, 3)
check("resolve unknown", select(2, pcall(status.resolve, "pr/other/x/1/1", repos)), "pr/other/x/1/1 names no configured repo")
check("resolve malformed", (select(2, pcall(status.resolve, "acme/api#12", repos)) or ""):match("isn't a rex%-reviewer item") ~= nil, true)
local twins = { { slug = "acme/" .. long .. "-1" }, { slug = "acme/" .. long .. "-2" } }
check("resolve ambiguous", (select(2, pcall(status.resolve, status.item_id(twins[1].slug, 1, 1), twins)) or ""):match("more than one repo") ~= nil, true)

-- lines
check("line control chars", status.line("a\nb\tc", 50), "a b c")
check("line cut", status.line("abcdefghij", 8), "abcde...")
check("line cut before a character", status.line("aaaébbb", 6), "aaa...")
check("line never splits a character", status.line("aaébbbb", 6), "aa...")

-- records
local ready = fields(status.report(status.record({
  repo = "acme/api", pr = 12, round = 2, kind = "ready", text = "the checked review is ready to post",
  title = "Retry webhooks",
  draft = { event = "REQUEST_CHANGES", blocking = 2, non_blocking = 1, verdict = "The retry loop never stops." },
})))
check("ready state", ready.state, "blocked")
check("ready kind", ready.kind, "permission")
check("ready id", ready.id, "pr/acme/api/12/2")
check("ready app", ready.app, "rex-reviewer")
check("ready title", ready.title, "api#12 Retry webhooks")
check("ready msg", ready.msg, "Ready to post: Request changes (2 blocking, 1 non-blocking). The retry loop never stops.")

local approve = fields(status.report(status.record({
  repo = "acme/api", pr = 12, round = 1, kind = "ready", draft = { event = "APPROVE", blocking = 0, non_blocking = 0 },
})))
check("approve msg", approve.msg, "Ready to post: Approve")
check("approve title without PR title", approve.title, "api#12")
check("ready without draft", fields(status.report(status.record({ repo = "a/b", pr = 1, round = 1, kind = "ready" }))).msg, "The checked review is ready to post")

local blocked = fields(status.report(status.record({ repo = "acme/api", pr = 12, round = 2, kind = "blocked", text = "claude: needs Docker" })))
check("blocked state", blocked.state, "blocked")
check("blocked has no kind", blocked.kind, nil)
check("blocked msg", blocked.msg, "claude: needs Docker")
check("start-failed is an error", fields(status.report(status.record({ repo = "a/b", pr = 1, round = 0, kind = "start-failed", text = "x" }))).state, "error")

-- root
check("root idle", status.report(status.root({})), "\27]7501;state=idle:app=rex-reviewer\27\\")
check("root paused", fields(status.report(status.root({ paused = true }))).msg, "Paused")
check("root error", fields(status.report(status.root({ error = "GitHub check failed: 502" }))).state, "error")
check("root has no id", fields(status.report(status.root({}))).id, nil)

-- sync
local shown = {}
local a1 = { repo = "acme/api", pr = 12, round = 2, kind = "ready" }
local a2 = { repo = "acme/web", pr = 7, round = 1, kind = "blocked", text = "stopped" }
local out = status.sync(shown, status.root({}), { a1, a2 })
check("sync first sends all", #out, 3)
out = status.sync(shown, status.root({}), { a1, a2 })
check("sync unchanged sends none", #out, 0)
out = status.sync(shown, status.root({}), { a1 })
check("sync clears the one that left", #out, 1)
check("sync clear report", out[1], "\27]7501;state=clear:id=pr/acme/web/7/1\27\\")
out = status.sync(shown, status.root({ error = "boom" }), { a1 })
check("sync root change only", #out, 1)
check("sync root change is the root", fields(out[1]).id, nil)
out = status.sync(shown, status.root({}), {})
check("sync clears all items, keeps the root", #out, 2)
check("sync never clears the root", shown[""] ~= nil, true)
local dup = status.sync({}, status.root({}), { a1, a1 })
check("sync sends a duplicate item once", #dup, 2)

-- limits from the protocol: a title of 192 bytes, a sequence of 4096
local huge = status.report(status.record({
  repo = "acme/api", pr = 1, round = 1, kind = "blocked", title = string.rep("t", 500), text = string.rep("m", 5000),
}))
check("report under 4096 bytes", #huge < 4096, true)
check("title under 192 bytes", #fields(huge).title <= 192, true)

print(string.format("%d passed, %d failed", count.pass, count.fail))
os.exit(count.fail == 0 and 0 or 1)
