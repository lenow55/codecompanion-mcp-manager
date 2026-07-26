-- Standalone smoke test for the automcp extension.
--
-- Run from the project root:
--   nvim --headless --noplugin -u NONE -c "set rtp+=." -c "luafile tests/test_automcp.lua" -c "qa!"
--
-- The test mocks the required CodeCompanion modules (config, log, mcp) and
-- verifies that:
--   1. `setup()` registers all three tools under keys matching their schema names
--   2. each `callback` is a factory returning a valid tool definition
--   3. the `auto_mcp` group is created with the registered tools
--   4. per-tool `require_approval_before` options are applied
--   5. the tool `cmds` behave correctly (validation + success paths)

-- Mock codecompanion modules -------------------------------------------------

local config_store = {
	interactions = { chat = { tools = { groups = {} } } },
	mcp = { servers = { testserver = { cmd = { "echo" } } } },
}

package.preload["codecompanion.config"] = function()
	return setmetatable({}, {
		__index = function(_, k)
			return config_store[k]
		end,
	})
end

package.preload["codecompanion.utils.log"] = function()
	return setmetatable({}, {
		__index = function()
			return function(...) end
		end,
	})
end

package.preload["codecompanion.utils"] = function()
	return { fire = function() end }
end

package.preload["codecompanion.mcp"] = function()
	return {
		tool_prefix = function()
			return "mcp:"
		end,
		get_status = function()
			return { testserver = { started = false, ready = false, tool_count = 0, default = false } }
		end,
		enable_server = function(name, opts)
			return true, true
		end,
		disable_server = function(name)
			return true, false
		end,
	}
end

-- 1. Load extension and run setup --------------------------------------------

local ext = require("codecompanion._extensions.automcp")
assert(type(ext) == "table" and type(ext.setup) == "function", "extension must expose setup()")
ext.setup({ tool_opts = { enable_server = { require_approval_before = true } } })

-- 2. Verify tools were registered under names matching their schema names -----

local tools_config = config_store.interactions.chat.tools
for _, name in ipairs({ "mcp_list_servers", "mcp_enable_server", "mcp_disable_server" }) do
	local cfg = tools_config[name]
	assert(cfg, "tool not registered: " .. name)
	assert(type(cfg.callback) == "function", "callback must be a factory function for: " .. name)
	local tool = cfg.callback()
	assert(tool.schema["function"].name == name, "schema name must equal config key: " .. name)
	assert(type(tool.cmds[1]) == "function", "tool must have cmds: " .. name)
	assert(type(tool.output.success) == "function", "tool must have output.success: " .. name)
	assert(type(tool.output.error) == "function", "tool must have output.error: " .. name)
	assert(type(tool.output.prompt) == "function", "tool must have output.prompt: " .. name)
end
assert(tools_config.mcp_enable_server.opts.require_approval_before == true, "approval opt not applied")
assert(tools_config.mcp_list_servers.opts.require_approval_before == nil, "approval should be unset by default")

-- 3. Verify group --------------------------------------------------------------

local group = tools_config.groups.auto_mcp
assert(group, "auto_mcp group missing")
assert(#group.tools == 3, "group should contain 3 tools")
assert(group.opts.collapse_tools == true, "group collapse_tools")

-- 4. Run list_servers cmd with a mocked Tools object ----------------------------

local tool = tools_config.mcp_list_servers.callback()
local result = tool.cmds[1]({ chat = nil }, {}, {})
assert(result.status == "success" and result.data:match("testserver"), "list_servers should return a server table")

-- 5. Run enable_server cmd (validation path + success path) ---------------------

local enable = tools_config.mcp_enable_server.callback()
local bad = enable.cmds[1]({ chat = nil }, { name = "nope" }, {})
assert(bad.status == "error", "enable_server should reject unknown servers")
local missing = enable.cmds[1]({ chat = nil }, {}, {})
assert(missing.status == "error", "enable_server should require the `name` argument")
local good = enable.cmds[1]({ chat = nil }, { name = "testserver" }, {})
assert(good.status == "success" and good.data:match("enabled"), "enable_server should succeed")

-- 6. Run disable_server cmd ------------------------------------------------------

local disable = tools_config.mcp_disable_server.callback()
local dis_bad = disable.cmds[1]({ chat = nil }, { name = "nope" }, {})
assert(dis_bad.status == "error", "disable_server should reject unknown servers")
local dis = disable.cmds[1]({ chat = nil }, { name = "testserver" }, {})
assert(dis.status == "success" and dis.data:match("disabled"), "disable_server should succeed")

print("ALL TESTS PASSED")
