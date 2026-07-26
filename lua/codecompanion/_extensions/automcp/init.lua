---@module "codecompanion"

local log = require("codecompanion.utils.log")

---@class CodeCompanionMcpManager.ToolOpts
---@field requires_approval? boolean Deprecated: use `require_approval_before` instead
---@field require_approval_before? boolean Ask for user approval before the tool runs

---@class CodeCompanionMcpManager.Opts
---@field tool_opts? table<string, CodeCompanionMcpManager.ToolOpts> Per-tool options, keyed by tool name without the `mcp_` prefix
---@field collapse_tools? boolean Collapse the tools into a single group in the chat buffer

---@type CodeCompanionMcpManager.Opts
local current_opts = {
	tool_opts = {
		list_servers = {},
		enable_server = {},
		disable_server = {},
	},
	collapse_tools = true,
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

	local tool_group = {}

	for tool_name, tool_opts in pairs(current_opts.tool_opts) do
		if tool_opts and tools[tool_name] then
			-- NOTE: The config key must match the tool's schema name. The LLM calls
			-- tools by their schema name and CodeCompanion resolves the tool by
			-- looking up that name in the tools config.
			local full_tool_name = "mcp_" .. tool_name

			local require_approval = tool_opts.requires_approval or tool_opts.require_approval_before

			if tool_opts.requires_approval ~= nil then
				vim.deprecate(
					"requires_approval",
					"require_approval_before",
					"v18.0.0",
					"codecompanion-mcp-manager.nvim",
					false
				)
			end

			tools_config[full_tool_name] = {
				description = string.format("MCP manager `%s` tool", tool_name),
				-- `callback` must be a factory function that returns the tool definition
				callback = tools[tool_name],
				opts = {
					require_approval_before = require_approval,
				},
			}
			table.insert(tool_group, full_tool_name)
		end
	end

	tools_config.groups["auto_mcp"] = {
		opts = { collapse_tools = current_opts.collapse_tools },
		tools = tool_group,
		description = "Tools that expose the MCP server lifecycle to the LLM.",
	}
end

return Extension
