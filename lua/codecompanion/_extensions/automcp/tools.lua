local log = require("codecompanion.utils.log")

local fmt = string.format

local M = {}

local function has_mcp_config(name)
	local config = require("codecompanion.config")
	return config.mcp and config.mcp.servers and config.mcp.servers[name] ~= nil
end

---Merge an MCP server's freshly-loaded tools & group descriptor into the global tools config
---@param tools_config table
---@param group_name string
---@param mcp_group table|nil Group descriptor produced by `tool_bridge.build`
---@param mcp_tools table<string, table>|nil Tools keyed by their final name
---@return nil
local function merge_mcp_into_config(tools_config, group_name, mcp_group, mcp_tools)
	if not tools_config.groups then
		tools_config.groups = {}
	end

	if not tools_config.groups[group_name] then
		if mcp_group then
			tools_config.groups[group_name] = vim.deepcopy(mcp_group)
		else
			local tool_names = {}
			for tool_name, _ in pairs(mcp_tools or {}) do
				table.insert(tool_names, tool_name)
			end
			table.sort(tool_names)
			tools_config.groups[group_name] = {
				description = fmt("Tools from MCP server `%s`", group_name:sub(#"mcp:" + 1)),
				tools = tool_names,
				opts = { collapse_tools = true },
			}
		end
	end

	for tool_name, tool_config in pairs(mcp_tools or {}) do
		if not tools_config[tool_name] then
			tools_config[tool_name] = tool_config
		end
	end
end

---Attach a freshly-loaded MCP server's tools to the current chat
---@param chat CodeCompanion.Chat
---@param server_name string
---@return boolean ok
local function attach_mcp_group(chat, server_name)
	local mcp = require("codecompanion.mcp")
	local config = require("codecompanion.config")

	local tools_config = config.interactions.chat.tools
	local group_name = mcp.tool_prefix() .. server_name

	local all_tools, all_groups = mcp.get_registered_tools()
	merge_mcp_into_config(tools_config, group_name, all_groups and all_groups[group_name], all_tools)

	local added = chat.tool_registry:add_group(group_name, { config = tools_config })
	log:debug("[mcp_manager] attached group `%s` to chat %s", group_name, tostring(chat.id))
	return added ~= nil
end

---Detach an MCP group's tools from the current chat
---@param chat CodeCompanion.Chat
---@param server_name string
---@return boolean removed
local function detach_mcp_group(chat, server_name)
	local mcp = require("codecompanion.mcp")
	local group_name = mcp.tool_prefix() .. server_name
	if not chat.tool_registry.groups[group_name] then
		return false
	end
	chat.tool_registry:remove_group(group_name)
	log:debug("[mcp_manager] detached group `%s` from chat %s", group_name, tostring(chat.id))
	return true
end

---Build the server list payload as a markdown table for the LLM
---@param status table<string, table>
---@return string
local function format_server_list(status)
	local rows = { { "name", "started", "ready", "tools", "default" } }
	local names = vim.tbl_keys(status)
	table.sort(names)
	for _, name in ipairs(names) do
		local s = status[name]
		table.insert(rows, {
			name,
			tostring(s.started or false),
			tostring(s.ready or false),
			tostring(s.tool_count or 0),
			tostring(s.default or false),
		})
	end
	local widths = {}
	for _, row in ipairs(rows) do
		for i, cell in ipairs(row) do
			widths[i] = math.max(widths[i] or 0, #cell)
		end
	end
	local lines = {}
	for r, row in ipairs(rows) do
		local cells = {}
		for i, cell in ipairs(row) do
			table.insert(cells, cell .. string.rep(" ", widths[i] - #cell))
		end
		table.insert(lines, "| " .. table.concat(cells, " | ") .. " |")
		if r == 1 then
			local sep = {}
			for i = 1, #widths do
				table.insert(sep, string.rep("-", widths[i]))
			end
			table.insert(lines, "| " .. table.concat(sep, " | ") .. " |")
		end
	end
	return table.concat(lines, "\n")
end

---@param name string
local function tool_display_name(name)
	return "`" .. name .. "`"
end

M.mcp_list_servers = {
	name = "mcp_list_servers",
	cmds = {
		function(self, _args, _input)
			local mcp = require("codecompanion.mcp")
			local status = mcp.get_status() or {}
			if vim.tbl_isempty(status) then
				return { status = "success", data = "No MCP servers are configured." }
			end
			return { status = "success", data = format_server_list(status) }
		end,
	},
	schema = {
		type = "function",
		["function"] = {
			name = "mcp_list_servers",
			description = "List all configured MCP servers with their status. Returns one row per server with `name`, `started` (process running), `ready` (initialized), `tools` (count of tools provided), and `default` (auto-started if none are explicitly enabled). Call this before `mcp_enable_server` or `mcp_disable_server` to discover valid server names.",
			parameters = {
				type = "object",
				properties = {},
				required = {},
				additionalProperties = false,
			},
			strict = true,
		},
	},
	output = {
		prompt = function(_self, _meta)
			return "List MCP servers?"
		end,
		success = function(self, stdout, meta)
			local chat = meta.tools.chat
			local llm_output = vim.iter(stdout or {}):flatten():join("\n")
			chat:add_tool_output(self, llm_output, "MCP servers listed")
		end,
		error = function(self, stderr, meta)
			local chat = meta.tools.chat
			local err = vim.iter(stderr or {}):flatten():join("\n")
			chat:add_tool_output(self, err or "Unknown error while listing MCP servers")
		end,
	},
}

M.mcp_enable_server = {
	name = "mcp_enable_server",
	cmds = {
		function(self, args, _input)
			local name = args and args.name
			if not name or name == "" then
				return { status = "error", data = "The `name` argument is required." }
			end
			if not has_mcp_config(name) then
				return {
					status = "error",
					data = fmt(
						"MCP server %s is not configured. Call `mcp_list_servers` to see available servers.",
						tool_display_name(name)
					),
				}
			end

			local mcp = require("codecompanion.mcp")
			local chat = self.chat

			local ok, message = mcp.enable_server(name, {
				on_tools_loaded = function()
					if chat then
						pcall(attach_mcp_group, chat, name)
					end
				end,
			})

			if not ok then
				return { status = "error", data = tostring(message) }
			end

			-- If the server was already started, the lifecycle guard short-circuits `Client:start`
			-- and never fires `on_tools_loaded`. Attach synchronously instead.
			if chat then
				local status = mcp.get_status() and mcp.get_status()[name]
				if
					status
					and status.ready
					and (not chat.tool_registry.groups or not chat.tool_registry.groups[mcp.tool_prefix() .. name])
				then
					pcall(attach_mcp_group, chat, name)
				end
			end

			local chat_note
			if chat then
				chat_note =
					" The server's tools are now registered into this chat and become callable on the next turn."
			else
				chat_note = " No active chat buffer was detected, so the server's tools were not attached anywhere."
			end

			return {
				status = "success",
				data = fmt("MCP server %s enabled.%s", tool_display_name(name), chat_note),
			}
		end,
	},
	schema = {
		type = "function",
		["function"] = {
			name = "mcp_enable_server",
			description = "Enable a configured MCP server by name. Starts the server process if it is not already running and registers the server's tools into the current chat. The newly registered tools appear in the system prompt and become callable on the LLM's next turn; do not try to invoke them in the same response.",
			parameters = {
				type = "object",
				properties = {
					name = {
						type = "string",
						description = "The name of the MCP server to enable. Must be one of the names returned by `mcp_list_servers`.",
					},
				},
				required = { "name" },
				additionalProperties = false,
			},
			strict = true,
		},
	},
	output = {
		prompt = function(self, _meta)
			return fmt("Enable MCP server %s?", tool_display_name(self.args.name or "?"))
		end,
		success = function(self, stdout, meta)
			local chat = meta.tools.chat
			local llm_output = vim.iter(stdout or {}):flatten():join("\n")
			chat:add_tool_output(
				self,
				llm_output,
				fmt("MCP server %s enabled", tool_display_name(self.args.name or "?"))
			)
		end,
		error = function(self, stderr, meta)
			local chat = meta.tools.chat
			local err = vim.iter(stderr or {}):flatten():join("\n")
			chat:add_tool_output(
				self,
				err or fmt("Unknown error while enabling %s", tool_display_name(self.args.name or "?"))
			)
		end,
	},
}

M.mcp_disable_server = {
	name = "mcp_disable_server",
	cmds = {
		function(self, args, _input)
			local name = args and args.name
			if not name or name == "" then
				return { status = "error", data = "The `name` argument is required." }
			end
			if not has_mcp_config(name) then
				return {
					status = "error",
					data = fmt("MCP server %s is not configured.", tool_display_name(name)),
				}
			end

			local mcp = require("codecompanion.mcp")
			local chat = self.chat

			local removed = false
			if chat then
				removed = detach_mcp_group(chat, name)
			end

			local ok, message = mcp.disable_server(name)
			if not ok then
				return { status = "error", data = tostring(message) }
			end

			local note = removed and " Its tools have been removed from this chat and will no longer be callable."
				or " No active chat was found, so no tool group was removed."

			return {
				status = "success",
				data = fmt("MCP server %s disabled.%s", tool_display_name(name), note),
			}
		end,
	},
	schema = {
		type = "function",
		["function"] = {
			name = "mcp_disable_server",
			description = "Disable an MCP server by name. Stops the server process and removes its tool group from the current chat. After disabling, none of the server's tools will be callable for the rest of this chat. Use only after you are sure no further tool calls from this server are needed.",
			parameters = {
				type = "object",
				properties = {
					name = {
						type = "string",
						description = "The name of the MCP server to disable. Must be one of the names returned by `mcp_list_servers`.",
					},
				},
				required = { "name" },
				additionalProperties = false,
			},
			strict = true,
		},
	},
	output = {
		prompt = function(self, _meta)
			return fmt("Disable MCP server %s?", tool_display_name(self.args.name or "?"))
		end,
		success = function(self, stdout, meta)
			local chat = meta.tools.chat
			local llm_output = vim.iter(stdout or {}):flatten():join("\n")
			chat:add_tool_output(
				self,
				llm_output,
				fmt("MCP server %s disabled", tool_display_name(self.args.name or "?"))
			)
		end,
		error = function(self, stderr, meta)
			local chat = meta.tools.chat
			local err = vim.iter(stderr or {}):flatten():join("\n")
			chat:add_tool_output(
				self,
				err or fmt("Unknown error while disabling %s", tool_display_name(self.args.name or "?"))
			)
		end,
	},
}

return M
