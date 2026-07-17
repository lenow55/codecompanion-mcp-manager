---@module "codecompanion"

---@class CodeCompanionMcpManager.ToolOpts
---@field requires_approval? boolean
---@field require_approval_before? boolean

---@class CodeCompanionMcpManager.Opts
---@field tool_opts table<string, CodeCompanionMcpManager.ToolOpts>
---@field collapse_tools boolean

---@type CodeCompanionMcpManager.Opts
local options = {
  tool_opts = {
    list_servers = {},
    enable_server = {},
    disable_server = {},
  },
  collapse_tools = true,
}

local Extension = {
  ---@param opts CodeCompanionMcpManager.Opts|{}|nil
  setup = function(opts)
    options = vim.tbl_deep_extend("force", options, opts or {})

    local has_mcp, mcp = pcall(require, "codecompanion.mcp")
    if not has_mcp or (mcp == nil) then
      error("Please enable the MCP support of CodeCompanion (config.mcp.servers)")
    end

    local tools = require("codecompanion._extensions.mcp_manager.tools")
    local config = require("codecompanion.config").config
    local tool_group = {}
    local interactions = config.strategies or config.interactions

    for tool_name, tool_opts in pairs(options.tool_opts) do
      if tool_opts then
        local full_tool_name = "auto_mcp_" .. tool_name

        local require_approval = tool_opts.requires_approval or tool_opts.require_approval_before

        if tool_opts.requires_approval then
          vim.deprecate(
            "requires_approval",
            "require_approval_before",
            "v18.0.0",
            "codecompanion-mcp-manager.nvim",
            false
          )
        end

        interactions.chat.tools[full_tool_name] = {
          description = string.format("MCP manager `%s` tool", tool_name),
          callback = tools[full_tool_name],
          opts = {
            requires_approval = require_approval,
            require_approval_before = require_approval,
          },
        }
        table.insert(tool_group, full_tool_name)
      end
    end

    interactions.chat.tools.groups["auto_mcp"] = {
      opts = { collapse_tools = options.collapse_tools },
      tools = tool_group,
      description = "Tools that expose the MCP server lifecycle to the LLM.",
    }
  end,
}

return Extension
