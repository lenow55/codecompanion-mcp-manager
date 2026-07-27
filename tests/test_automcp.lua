-- Standalone smoke test for the automcp extension.
--
-- Run from the project root:
--   nvim --headless --noplugin -u NONE -c "set rtp+=." -c "luafile tests/test_automcp.lua" -c "qa!"
--
-- The test mocks the required CodeCompanion modules (config, log, mcp) and
-- verifies that:
--   1. `setup()` registers all tool group tools under keys matching their schema names
--   2. each `callback` is a factory returning a valid tool definition
--   3. the `auto_mcp` group is created with the registered tools
--   4. per-tool `require_approval_before` options are applied
--   5. the tool `cmds` behave correctly (validation + success paths)

-- Mock codecompanion modules -------------------------------------------------

local config_store = {
	interactions = {
		chat = {
			tools = {
				groups = {
					testgroup = {
						tools = { "tool_a", "tool_b" },
						description = "A test group",
					},
					empty_group = {
						tools = {},
						description = "An empty group",
					},
				},
			},
		},
	},
	mcp = { servers = {} },
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
	}
end

-- 1. Load extension and run setup --------------------------------------------

local ext = require("codecompanion._extensions.automcp")
assert(type(ext) == "table" and type(ext.setup) == "function", "extension must expose setup()")
ext.setup({ tool_opts = { enable_tool_group = { require_approval_before = true } } })

-- 2. Verify tools were registered under names matching their schema names -----

local tools_config = config_store.interactions.chat.tools
for _, name in ipairs({
	"mcp_list_tool_groups",
	"mcp_enable_tool_group",
	"mcp_disable_tool_group",
}) do
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
assert(tools_config.mcp_enable_tool_group.opts.require_approval_before == true, "approval opt not applied")
assert(tools_config.mcp_list_tool_groups.opts.require_approval_before == nil, "approval should be unset by default")

-- 3. Verify group --------------------------------------------------------------

local group = tools_config.groups.auto_mcp
assert(group, "auto_mcp group missing")
assert(#group.tools == 3, "group should contain 3 tools")
assert(group.opts.collapse_tools == true, "group collapse_tools")

-- 4. Run list_tool_groups cmd ---------------------------------------------------

---@param attached_groups table<string, true> Group names already in tool_registry
local function mock_chat_with_registry(attached_groups)
	local added = {}
	local removed = {}
	return {
		id = 42,
		tool_registry = {
			groups = vim.deepcopy(attached_groups or {}),
			add_group = function(_, name, _opts)
				added[name] = true
				return true
			end,
			remove_group = function(_, name)
				removed[name] = true
				return true
			end,
			_in_added = added,
			_in_removed = removed,
		},
		tools = {},
	}
end

local list_tool_groups = tools_config.mcp_list_tool_groups.callback()

-- No active chat → should still return data (attached column omitted via self.chat == nil)
local ltg_nochat = list_tool_groups.cmds[1]({ chat = nil }, {}, {})
assert(ltg_nochat.status == "success", "list_tool_groups should succeed without chat")
assert(ltg_nochat.data:match("testgroup"), "list_tool_groups should list testgroup")
assert(ltg_nochat.data:match("empty_group"), "list_tool_groups should list empty_group")
assert(ltg_nochat.data:match("auto_mcp"), "list_tool_groups should list auto_mcp group added by setup")

-- With chat → attached column reflects tool_registry state
local chat_attached = mock_chat_with_registry({ testgroup = true })
local ltg_attached = list_tool_groups.cmds[1]({ chat = chat_attached }, {}, {})
assert(ltg_attached.status == "success", "list_tool_groups should succeed with chat")
assert(ltg_attached.data:match("true"), "list_tool_groups should show true for attached testgroup")

-- 5. Run enable_tool_group cmd (validation + success + already-attached) ---------

local enable_tg = tools_config.mcp_enable_tool_group.callback()

local etg_missing = enable_tg.cmds[1]({ chat = chat_attached }, {}, {})
assert(etg_missing.status == "error", "enable_tool_group should require `name`")

local etg_unknown = enable_tg.cmds[1]({ chat = chat_attached }, { name = "nope" }, {})
assert(etg_unknown.status == "error", "enable_tool_group should reject unknown groups")

local etg_nochat = enable_tg.cmds[1]({ chat = nil }, { name = "testgroup" }, {})
assert(etg_nochat.status == "error", "enable_tool_group should error without active chat")

local etg_already = enable_tg.cmds[1]({ chat = chat_attached }, { name = "testgroup" }, {})
assert(
	etg_already.status == "success" and etg_already.data:match("already attached"),
	"enable_tool_group should report already-attached"
)

local chat_clean = mock_chat_with_registry({})
local etg_good = enable_tg.cmds[1]({ chat = chat_clean }, { name = "testgroup" }, {})
assert(etg_good.status == "success" and etg_good.data:match("attached"), "enable_tool_group should succeed and attach")
assert(chat_clean.tool_registry._in_added["testgroup"], "add_group should have been called for testgroup")

-- 6. Run disable_tool_group cmd (validation + success) ---------------------------

local disable_tg = tools_config.mcp_disable_tool_group.callback()

local dtg_missing = disable_tg.cmds[1]({ chat = chat_attached }, {}, {})
assert(dtg_missing.status == "error", "disable_tool_group should require `name`")

local dtg_nochat = disable_tg.cmds[1]({ chat = nil }, { name = "testgroup" }, {})
assert(dtg_nochat.status == "error", "disable_tool_group should error without active chat")

local dtg_not_attached = disable_tg.cmds[1]({ chat = chat_clean }, { name = "testgroup" }, {})
assert(dtg_not_attached.status == "error", "disable_tool_group should error for unattached group")

local dtg_good = disable_tg.cmds[1]({ chat = chat_attached }, { name = "testgroup" }, {})
assert(dtg_good.status == "success" and dtg_good.data:match("detached"), "disable_tool_group should succeed and detach")
assert(chat_attached.tool_registry._in_removed["testgroup"], "remove_group should have been called for testgroup")

-- 7. no_approval_for allow-list --------------------------------------------------

-- Re-require the extension to reset module-level `current_opts` so the
-- second setup() starts from defaults rather than merging on top of the
-- first call's options.
package.loaded["codecompanion._extensions.automcp"] = nil
local ext2 = require("codecompanion._extensions.automcp")

ext2.setup({
	-- Global allow-list applies to every name-based group tool.
	no_approval_for = { "testgroup" },
	tool_opts = {
		enable_tool_group = {
			require_approval_before = true,
			-- Per-tool allow-list is merged on top of the global one.
			no_approval_for = { "safe-group" },
		},
		disable_tool_group = {
			require_approval_before = true,
		},
	},
})

local tools_config2 = config_store.interactions.chat.tools

-- Name-based tools get a function gate when an allow-list is in effect.
assert(
	type(tools_config2.mcp_enable_tool_group.opts.require_approval_before) == "function",
	"enable_tool_group should wrap approval in a function when no_approval_for is set"
)
assert(
	type(tools_config2.mcp_disable_tool_group.opts.require_approval_before) == "function",
	"disable_tool_group should wrap approval in a function when no_approval_for is set"
)

-- Non-name-based tools are unaffected by the allow-list and keep their base
-- value (nil here → no approval).
assert(
	tools_config2.mcp_list_tool_groups.opts.require_approval_before == nil,
	"list_tool_groups should be unaffected by no_approval_for"
)

local function call_approval(tool_cfg, name)
	return tool_cfg.opts.require_approval_before({ args = name and { name = name } or {} }, nil)
end

local etg = tools_config2.mcp_enable_tool_group
assert(call_approval(etg, "testgroup") == false, "global no_approval_for should bypass testgroup")
assert(call_approval(etg, "safe-group") == false, "per-tool no_approval_for should bypass safe-group")
assert(call_approval(etg, "other") == true, "non-whitelisted name should fall back to base require_approval_before")
assert(call_approval(etg, nil) == true, "missing name should fall back to base require_approval_before")

local dtg2 = tools_config2.mcp_disable_tool_group
assert(call_approval(dtg2, "testgroup") == false, "global no_approval_for should bypass testgroup for disable_tool_group")
assert(call_approval(dtg2, "other") == true, "non-whitelisted name should require approval for disable_tool_group")

print("ALL TESTS PASSED")
