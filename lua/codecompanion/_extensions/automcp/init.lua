---@module "codecompanion"

local log = require("codecompanion.utils.log")

---@class CodeCompanionMcpManager.ToolOpts
---@field requires_approval? boolean Deprecated: use `require_approval_before` instead
---@field require_approval_before? boolean|fun(self: table, tools: table): boolean Ask for user approval before the tool runs
---@field no_approval_for? string[] Names of MCP servers or tool groups that bypass approval for this tool only

---@class CodeCompanionMcpManager.Opts
---@field tool_opts? table<string, CodeCompanionMcpManager.ToolOpts> Per-tool options, keyed by tool name without the `mcp_` prefix
---@field collapse_tools? boolean Collapse the tools into a single group in the chat buffer
---@field no_approval_for? string[] Names of MCP servers or tool groups that bypass approval for every name-based lifecycle/group tool

---@type CodeCompanionMcpManager.Opts
local current_opts = {
	tool_opts = {
		list_servers = {},
		enable_server = {},
		disable_server = {},
		list_tool_groups = {},
		enable_tool_group = {},
		disable_tool_group = {},
	},
	collapse_tools = true,
	no_approval_for = {},
}

local Extension = {}

---@param opts CodeCompanionMcpManager.Opts|{}|nil
function Extension.setup(opts)
	current_opts = vim.tbl_deep_extend("force", current_opts, opts or {})

	local has_mcp, mcp = pcall(require, "codecompanion.mcp")
	if not has_mcp or mcp == nil then
		log:warn("[automcp] MCP support was not found in CodeCompanion; the `auto_mcp` tools were not registered")
		return
	end

	local tools = require("codecompanion._extensions.automcp.tools")
	local tools_config = require("codecompanion.config").interactions.chat.tools

	-- Tools that take a `name` argument (an MCP server or tool group name) and
	-- therefore respect the `no_approval_for` allow-list.
	local NAME_BASED_TOOLS = {
		enable_server = true,
		disable_server = true,
		enable_tool_group = true,
		disable_tool_group = true,
	}

	---Resolve the set of names that should bypass approval for a given tool.
	---The per-tool `no_approval_for` list is merged on top of the top-level one.
	---@param per_tool_opts table
	---@return table<string, true> lookup
	local function resolve_no_approval(per_tool_opts)
		local lookup = {}
		for _, name in ipairs(current_opts.no_approval_for or {}) do
			lookup[name] = true
		end
		if per_tool_opts and per_tool_opts.no_approval_for then
			for _, name in ipairs(per_tool_opts.no_approval_for) do
				lookup[name] = true
			end
		end
		return lookup
	end

	local tool_group = {}

	for tool_name, tool_opts in pairs(current_opts.tool_opts) do
		if tool_opts and tools[tool_name] then
			-- NOTE: The config key must match the tool's schema name. The LLM calls
			-- tools by their schema name and CodeCompanion resolves the tool by
			-- looking up that name in the tools config.
			local full_tool_name = "mcp_" .. tool_name

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
			-- and skips approval for whitelisted servers/groups. Names that are not
			-- in the list fall back to the per-tool `require_approval_before` rule.
			local require_approval_before = base_require_approval
			if NAME_BASED_TOOLS[tool_name] then
				local no_approval_lookup = resolve_no_approval(tool_opts)
				if next(no_approval_lookup) ~= nil then
					require_approval_before = function(tool, tools_obj)
						local name = tool and tool.args and tool.args.name
						if name and no_approval_lookup[name] then
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
				description = string.format("MCP manager `%s` tool", tool_name),
				-- `callback` must be a factory function that returns the tool definition
				callback = tools[tool_name],
				opts = {
					require_approval_before = require_approval_before,
				},
			}
			table.insert(tool_group, full_tool_name)
		end
	end

	tools_config.groups["auto_mcp"] = {
		opts = { collapse_tools = current_opts.collapse_tools },
		tools = tool_group,
		description = "Tools that expose the MCP server lifecycle and tool group management to the LLM.",
	}
end

return Extension
