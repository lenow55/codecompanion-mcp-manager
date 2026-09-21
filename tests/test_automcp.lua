-- Standalone smoke test for the automcp extension.
--
-- Run from the project root:
--   nvim --headless --noplugin -u NONE -c "set rtp+=." -c "luafile tests/test_automcp.lua" -c "qa!"
--
-- The test mocks the required CodeCompanion modules (config, log, mcp) and
-- verifies that:
--   1. `setup()` registers all tools under neutral names matching their schema names
--   2. each `callback` is a factory returning a valid tool definition
--   3. the `auto_tools` group is created with the registered tools
--   4. per-tool `require_approval_before` options are applied
--   5. the tool `cmds` behave correctly (validation + success paths)
--   6. `individual_tools` (globs) gate which tools may be enabled on their own
--   7. `deny_groups` (globs) hides and blocks groups in every operation
--   8. individual tools cannot be disabled and stay enabled

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
					secrets = {
						tools = { "vault" },
						description = "A denied group",
					},
				},
				-- Individual tools in the global config
				subagents_research = {
					description = "Delegates a research subtask to a subagent",
					callback = function()
						return { name = "subagents_research" }
					end,
				},
				other_tool = {
					description = "A tool that is not allow-listed for solo use",
					callback = function()
						return { name = "other_tool" }
					end,
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
ext.setup({
	individual_tools = { "subagents_*" },
	deny_groups = { "secret*" },
	tool_opts = { enable_tool = { require_approval_before = true } },
})

-- 2. Verify tools were registered under names matching their schema names -----

local tools_config = config_store.interactions.chat.tools
for _, name in ipairs({
	"list_tools",
	"enable_tool",
	"disable_tool",
}) do
	local cfg = tools_config[name]
	assert(cfg, "tool not registered: " .. name)
	assert(cfg.visible == false, "tool must be hidden from `@` completions: " .. name)
	assert(type(cfg.callback) == "function", "callback must be a factory function for: " .. name)
	local tool = cfg.callback()
	assert(tool.schema["function"].name == name, "schema name must equal config key: " .. name)
	assert(type(tool.cmds[1]) == "function", "tool must have cmds: " .. name)
	assert(type(tool.output.success) == "function", "tool must have output.success: " .. name)
	assert(type(tool.output.error) == "function", "tool must have output.error: " .. name)
	assert(type(tool.output.prompt) == "function", "tool must have output.prompt: " .. name)
end
assert(tools_config.enable_tool.opts.require_approval_before == true, "approval opt not applied")
assert(tools_config.list_tools.opts.require_approval_before == nil, "approval should be unset by default")

-- 3. Verify group --------------------------------------------------------------

local group = tools_config.groups.auto_tools
assert(group, "auto_tools group missing")
assert(#group.tools == 3, "group should contain 3 tools")
assert(group.opts.collapse_tools == true, "group collapse_tools")

-- Mock chat ------------------------------------------------------------------

---@param state { groups?: table<string, true>, in_use?: table<string, true> }
local function mock_chat(state)
	state = state or {}
	local added = {}
	local removed = {}
	local added_tools = {}
	return {
		id = 42,
		tool_registry = {
			groups = vim.deepcopy(state.groups or {}),
			in_use = vim.deepcopy(state.in_use or {}),
			add_group = function(_, name, _opts)
				added[name] = true
				return true
			end,
			add_single_tool = function(_, name, _opts)
				added_tools[name] = true
				return true
			end,
			remove_group = function(_, name)
				removed[name] = true
				return true
			end,
			_in_added = added,
			_in_removed = removed,
			_in_added_tools = added_tools,
		},
		tools = {},
	}
end

-- 4. list_tools cmd -------------------------------------------------------------

local list_tools = tools_config.list_tools.callback()

-- No active chat -> still succeeds, attached is false everywhere
local lt_nochat = list_tools.cmds[1]({ chat = nil }, {}, {})
assert(lt_nochat.status == "success", "list_tools should succeed without chat")
assert(lt_nochat.data:match("testgroup"), "list_tools should list testgroup")
assert(lt_nochat.data:match("auto_tools"), "list_tools should list the auto_tools group")
assert(lt_nochat.data:match("type: group"), "list_tools should report group type")
assert(lt_nochat.data:match("subagents_research"), "list_tools should list allow-listed individual tools")
assert(lt_nochat.data:match("type: tool"), "list_tools should report tool type")

-- Denied groups are hidden entirely
assert(not lt_nochat.data:match("secrets"), "list_tools must hide denied groups")

-- Non allow-listed tools are hidden from solo listing
assert(not lt_nochat.data:match("other_tool"), "list_tools must hide non allow-listed tools")

-- Attached status for a group
local chat_attached = mock_chat({ groups = { testgroup = true } })
local lt_attached = list_tools.cmds[1]({ chat = chat_attached }, {}, {})
assert(lt_attached.status == "success", "list_tools should succeed with chat")
assert(lt_attached.data:match("attached: true"), "list_tools should show attached groups")

-- 5. enable_tool cmd (groups) ---------------------------------------------------

local enable_tool = tools_config.enable_tool.callback()

local et_missing = enable_tool.cmds[1]({ chat = chat_attached }, {}, {})
assert(et_missing.status == "error", "enable_tool should require `name`")

local et_unknown = enable_tool.cmds[1]({ chat = chat_attached }, { name = "nope" }, {})
assert(et_unknown.status == "error", "enable_tool should reject unknown names")
assert(et_unknown.data:match("not available"), "unknown name should be reported as not available")

local et_nochat = enable_tool.cmds[1]({ chat = nil }, { name = "testgroup" }, {})
assert(et_nochat.status == "error", "enable_tool should error without active chat")

local et_already = enable_tool.cmds[1]({ chat = chat_attached }, { name = "testgroup" }, {})
assert(
	et_already.status == "success" and et_already.data:match("already enabled"),
	"enable_tool should report already-enabled"
)

local chat_clean = mock_chat({})
local et_good = enable_tool.cmds[1]({ chat = chat_clean }, { name = "testgroup" }, {})
assert(et_good.status == "success" and et_good.data:match("enabled"), "enable_tool should enable a group")
assert(chat_clean.tool_registry._in_added["testgroup"], "add_group should have been called for testgroup")

-- add_group may fail (return nil) without throwing; this must surface as an error
local chat_add_fails = mock_chat({})
chat_add_fails.tool_registry.add_group = function()
	return nil
end
local et_add_failed = enable_tool.cmds[1]({ chat = chat_add_fails }, { name = "testgroup" }, {})
assert(et_add_failed.status == "error", "enable_tool should error when add_group fails")
assert(et_add_failed.data:match("Failed to enable"), "enable_tool should report the failure")

-- Denied group: cannot be enabled, and the error looks like an unknown name
local et_denied = enable_tool.cmds[1]({ chat = chat_clean }, { name = "secrets" }, {})
assert(et_denied.status == "error", "denied group must not be enabled")
assert(et_denied.data:match("not available"), "denied group must be indistinguishable from an unknown name")

-- 6. enable_tool cmd (individual tools) ----------------------------------------

-- Allow-listed tool (glob) can be enabled individually
local et_tool = enable_tool.cmds[1]({ chat = chat_clean }, { name = "subagents_research" }, {})
assert(et_tool.status == "success", "allow-listed individual tool should be enabled")
assert(chat_clean.tool_registry._in_added_tools["subagents_research"], "add_single_tool should have been called")

-- Non allow-listed tool cannot be enabled
local et_tool_denied = enable_tool.cmds[1]({ chat = chat_clean }, { name = "other_tool" }, {})
assert(et_tool_denied.status == "error", "non allow-listed tool must not be enabled")
assert(et_tool_denied.data:match("not available"), "non allow-listed tool must be reported as not available")

-- Collision: a group and a tool share a name -> the group wins
config_store.interactions.chat.tools.groups["other_tool"] = { tools = {}, description = "group vs tool" }
local et_collision = enable_tool.cmds[1]({ chat = mock_chat({}) }, { name = "other_tool" }, {})
assert(et_collision.status == "success", "collision should resolve to the group and succeed")

-- 7. disable_tool cmd -----------------------------------------------------------

local disable_tool = tools_config.disable_tool.callback()

local dt_missing = disable_tool.cmds[1]({ chat = chat_attached }, {}, {})
assert(dt_missing.status == "error", "disable_tool should require `name`")

local dt_nochat = disable_tool.cmds[1]({ chat = nil }, { name = "testgroup" }, {})
assert(dt_nochat.status == "error", "disable_tool should error without active chat")

local dt_not_attached = disable_tool.cmds[1]({ chat = chat_clean }, { name = "testgroup" }, {})
assert(dt_not_attached.status == "error", "disable_tool should error for an unattached group")

local dt_good = disable_tool.cmds[1]({ chat = chat_attached }, { name = "testgroup" }, {})
assert(dt_good.status == "success" and dt_good.data:match("disabled"), "disable_tool should disable a group")
assert(chat_attached.tool_registry._in_removed["testgroup"], "remove_group should have been called")

-- Denied group cannot be disabled either (all operations blocked)
local dt_denied = disable_tool.cmds[1]({ chat = chat_attached }, { name = "secrets" }, {})
assert(dt_denied.status == "error", "denied group must not be disabled")
assert(dt_denied.data:match("not available"), "denied disable must look like an unknown name")

-- Individual tools cannot be disabled; they stay enabled
local chat_tool_on = mock_chat({ in_use = { subagents_research = true } })
local dt_tool = disable_tool.cmds[1]({ chat = chat_tool_on }, { name = "subagents_research" }, {})
assert(dt_tool.status == "success", "disabling an individual tool should not error")
assert(dt_tool.data:match("cannot be disabled"), "disabling an individual tool should explain it stays enabled")
assert(chat_tool_on.tool_registry.in_use["subagents_research"] == true, "individual tool must stay enabled")

-- Disabling a tool that is not enabled -> error
local dt_tool_off = disable_tool.cmds[1]({ chat = mock_chat({}) }, { name = "subagents_research" }, {})
assert(dt_tool_off.status == "error", "disabling a tool that is not enabled should error")

-- 8. no_approval_for allow-list --------------------------------------------------

-- Re-require the extension to reset module-level `current_opts`.
package.loaded["codecompanion._extensions.automcp"] = nil
local ext2 = require("codecompanion._extensions.automcp")

ext2.setup({
	individual_tools = { "subagents_*" },
	deny_groups = { "secret*" },
	-- Global allow-list applies to every name-based tool; globs are supported.
	no_approval_for = { "testgroup", "sub*" },
	tool_opts = {
		enable_tool = {
			require_approval_before = true,
			-- Per-tool allow-list is merged on top of the global one.
			no_approval_for = { "safe-group" },
		},
		disable_tool = {
			require_approval_before = true,
		},
	},
})

local tools_config2 = config_store.interactions.chat.tools

assert(
	type(tools_config2.enable_tool.opts.require_approval_before) == "function",
	"enable_tool should wrap approval in a function when no_approval_for is set"
)
assert(
	type(tools_config2.disable_tool.opts.require_approval_before) == "function",
	"disable_tool should wrap approval in a function when no_approval_for is set"
)
assert(
	tools_config2.list_tools.opts.require_approval_before == nil,
	"list_tools should be unaffected by no_approval_for"
)

local function call_approval(tool_cfg, name)
	return tool_cfg.opts.require_approval_before({ args = name and { name = name } or {} }, nil)
end

local et2 = tools_config2.enable_tool
assert(call_approval(et2, "testgroup") == false, "global no_approval_for should bypass testgroup")
assert(call_approval(et2, "subagents_research") == false, "glob pattern should bypass subagents_research")
assert(call_approval(et2, "safe-group") == false, "per-tool no_approval_for should bypass safe-group")
assert(call_approval(et2, "other") == true, "non-whitelisted name should fall back to base approval")
assert(call_approval(et2, nil) == true, "missing name should fall back to base approval")

local dt2 = tools_config2.disable_tool
assert(call_approval(dt2, "testgroup") == false, "global no_approval_for should bypass testgroup for disable_tool")
assert(call_approval(dt2, "other") == true, "non-whitelisted name should require approval for disable_tool")

print("ALL TESTS PASSED")
