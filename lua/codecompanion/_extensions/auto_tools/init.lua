---@module "codecompanion"

local log = require("codecompanion.utils.log")

---@class CodeCompanionMcpManager.ToolOpts
---@field requires_approval? boolean Deprecated: use `require_approval_before` instead
---@field require_approval_before? boolean|fun(self: table, tools: table): boolean Ask for user approval before the tool runs
---@field no_approval_for? string[] Glob patterns of tool/group names that bypass approval for this tool only
---@field visible? boolean Show the tool in the `@` completion menu (solo attach). Defaults to `false`

---@class CodeCompanionMcpManager.Opts
---@field tool_opts? table<string, CodeCompanionMcpManager.ToolOpts> Per-tool options, keyed by tool name
---@field collapse_tools? boolean Collapse the tools into a single group in the chat buffer
---@field individual_tools? string[] Glob patterns of individual tools that may be enabled on their own
---@field deny_groups? string[] Glob patterns of tool groups that are hidden and blocked in every operation
---@field no_approval_for? string[] Glob patterns of tool/group names that bypass approval for every name-based tool

---@type CodeCompanionMcpManager.Opts
local current_opts = {
	tool_opts = {
		list_tools = {},
		enable_tool = {},
		disable_tool = {},
	},
	collapse_tools = true,
	individual_tools = {},
	deny_groups = {},
	no_approval_for = {},
}

local Extension = {}

---The currently resolved options. Used by the tools module (and the approval
---gate) to read the allow/deny lists at call time.
---@return CodeCompanionMcpManager.Opts
function Extension.opts()
	return current_opts
end

---@param opts CodeCompanionMcpManager.Opts|{}|nil
function Extension.setup(opts)
	current_opts = vim.tbl_deep_extend("force", current_opts, opts or {})

	local has_mcp, mcp = pcall(require, "codecompanion.mcp")
	if not has_mcp or mcp == nil then
		log:warn("[auto_tools] MCP support was not found in CodeCompanion; the `auto_tools` tools were not registered")
		return
	end

	local tools = require("codecompanion._extensions.auto_tools.tools")
	local tools_config = require("codecompanion.config").interactions.chat.tools

	-- Tools that take a `name` argument (a group or individual tool name) and
	-- therefore respect the `no_approval_for` allow-list.
	local NAME_BASED_TOOLS = {
		enable_tool = true,
		disable_tool = true,
	}

	---Resolve the set of glob patterns that should bypass approval for a given tool.
	---The per-tool `no_approval_for` list is merged on top of the top-level one.
	---@param per_tool_opts table
	---@return string[] patterns
	local function resolve_no_approval(per_tool_opts)
		local patterns = {}
		for _, pattern in ipairs(current_opts.no_approval_for or {}) do
			table.insert(patterns, pattern)
		end
		if per_tool_opts and per_tool_opts.no_approval_for then
			for _, pattern in ipairs(per_tool_opts.no_approval_for) do
				table.insert(patterns, pattern)
			end
		end
		return patterns
	end

	local tool_group = {}

	for tool_name, tool_opts in pairs(current_opts.tool_opts) do
		if tool_opts and tools[tool_name] then
			-- NOTE: The config key must match the tool's schema name. The LLM calls
			-- tools by their schema name and CodeCompanion resolves the tool by
			-- looking up that name in the tools config.
			local full_tool_name = tool_name

			local base_require_approval = tool_opts.requires_approval or tool_opts.require_approval_before

			if tool_opts.requires_approval ~= nil then
				vim.deprecate(
					"requires_approval",
					"require_approval_before",
					"v18.0.0",
					"codecompanion-mcp-manager.nvim",
					false
				)
			end

			-- When a `no_approval_for` allow-list is in effect, wrap the approval
			-- gate in a function that inspects the `name` argument the LLM passed
			-- and skips approval for whitelisted names (globs supported). Names
			-- that are not in the list fall back to the per-tool
			-- `require_approval_before` rule.
			local require_approval_before = base_require_approval
			if NAME_BASED_TOOLS[tool_name] then
				local no_approval_patterns = resolve_no_approval(tool_opts)
				if next(no_approval_patterns) ~= nil then
					local matches_pattern = tools.matches_pattern
					require_approval_before = function(tool, tools_obj)
						local name = tool and tool.args and tool.args.name
						if name and matches_pattern(name, no_approval_patterns) then
							return false
						end
						if type(base_require_approval) == "function" then
							return base_require_approval(tool, tools_obj)
						end
						return base_require_approval
					end
				end
			end

			tools_config[full_tool_name] = {
				description = string.format("Tool group management `%s` tool", tool_name),
				-- `callback` must be a factory function that returns the tool definition
				callback = tools[tool_name],
				-- Tools are hidden from `@` completions so that users attach the
				-- `auto_tools` group instead. Per-tool override:
				-- `tool_opts[<tool>].visible = true`
				visible = tool_opts.visible == true,
				opts = {
					require_approval_before = require_approval_before,
				},
			}
			table.insert(tool_group, full_tool_name)
		end
	end

	tools_config.groups["auto_tools"] = {
		opts = { collapse_tools = current_opts.collapse_tools },
		tools = tool_group,
		description = "Tools that let the LLM inspect and manage tool groups and individual tools in the current chat.",
	}
end

return Extension
