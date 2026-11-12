-- rex-reviewer: Rex actions for agent PR reviews.
--
-- Load it from ~/.config/rex/init.lua:
--
--   dofile(os.getenv("HOME") .. "/path/to/rex-reviewer/init.lua")
--
-- The actions read ~/.config/rex-reviewer/config.lua when they run, so a bad
-- config shows up as an action error, and `rex do reviewer_doctor` says what's
-- wrong. lua/rex_reviewer/actions.lua defines them; on Herdr, the same
-- actions run under LuaJIT instead (scripts/cli.lua).

local ROOT = debug.getinfo(1, "S").source:gsub("^@", ""):match("^(.*)/[^/]+$")
package.path = ROOT .. "/lua/?.lua;" .. package.path

local config = require("rex_reviewer.config")
config.set_root(ROOT)
local actions = require("rex_reviewer.actions")

for _, a in ipairs(actions.list) do
  if a.rex then
    rex.action({
      name = a.name,
      title = "Rex Reviewer: " .. a.title,
      args = a.args,
      run = function(_, args)
        return a.run(args or {})
      end,
    })
  end
end

-- Starting a round takes longer than Rex allows an action (30 s), so it's a
-- script: rex do <rex-reviewer>/scripts/start.lua pr=<n>
