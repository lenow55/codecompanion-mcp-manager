local log = require("codecompanion.utils.log")

local fmt = string.format

local M = {}

---Collect all tool *groups* (as opposed to bare tools) that are available in
---the global CodeCompanion tools config. A group is identified by an entry in
---`tools.groups`; the value is a table with a `tools` array of tool names.
---@param tools_config table
---@return table<string, { tools: string[], description?: string }> groups
local function get_available_groups(tools_config)
	local groups = {}
	if not tools_config.groups then
		return groups
	end
	for name, group_config in pairs(tools_config.groups) do
		if type(group_config) == "table" and group_config.tools then
			groups[name] = {
				tools = group_config.tools,
				description = group_config.description,
			}
		end
	end
	return groups
end

---Check that an MCP server is present in the user's CodeCompanion config
---@param name string
---@return boolean
local function has_mcp_config(name)
	local config = require("codecompanion.config")
	return config.mcp and config.mcp.servers and config.mcp.servers[name] ~= nil
end

---Attach a freshly-loaded MCP server's tools to the current chat.
---Mirrors CodeCompanion's own MCP integration: refreshing the chat's tools
---picks up the server's tools through the tools filter, then the group is
---added to the chat's tool registry.
---@param chat CodeCompanion.Chat
---@param server_name string
---@return boolean ok
local function attach_mcp_group(chat, server_name)
	if not (chat.tools and chat.tool_registry) then
		return false
	end
	local mcp = require("codecompanion.mcp")
	chat.tools:refresh({ adapter = chat.adapter })
	local group_name = mcp.tool_prefix() .. server_name
	local added = chat.tool_registry:add(group_name, { config = chat.tools.tools_config })
	log:debug("[mcp_manager] attached group `%s` to chat %s", group_name, tostring(chat.id))
	return added ~= nil
end

---Detach an MCP group's tools from the current chat
---@param chat CodeCompanion.Chat
---@param server_name string
---@return boolean removed
local function detach_mcp_group(chat, server_name)
	if not chat.tool_registry then
		return false
	end
	local mcp = require("codecompanion.mcp")
	local group_name = mcp.tool_prefix() .. server_name
	if not chat.tool_registry.groups[group_name] then
		return false
	end
	chat.tool_registry:remove_group(group_name)
	if chat.tools then
		chat.tools:refresh({ adapter = chat.adapter })
	end
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

---@return CodeCompanion.Tools.Tool
function M.list_servers()
	return {
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
end

---@return CodeCompanion.Tools.Tool
function M.enable_server()
	return {
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
				if chat and chat.tool_registry then
					local status = mcp.get_status()
					local server_status = status and status[name]
					if
						server_status
						and server_status.ready
						and not chat.tool_registry.groups[mcp.tool_prefix() .. name]
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
end

---@return CodeCompanion.Tools.Tool
function M.disable_server()
	return {
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
end

---Attach a tool group to the current chat's tool_registry.
---@param chat CodeCompanion.Chat
---@param group_name string
---@return boolean ok
local function attach_tool_group(chat, group_name)
	if not (chat.tools and chat.tool_registry) then
		return false
	end
	local config = require("codecompanion.config")
	local tools_config = config.interactions.chat.tools
	local group_config = tools_config.groups and tools_config.groups[group_name]
	if not group_config or not group_config.tools then
		return false
	end
	local added = chat.tool_registry:add_group(group_name, { config = tools_config })
	log:debug("[automcp] attached tool group `%s` to chat %s", group_name, tostring(chat.id))
	return added ~= nil
end

---Detach a tool group from the current chat's tool_registry.
---@param chat CodeCompanion.Chat
---@param group_name string
---@return boolean removed
local function detach_tool_group(chat, group_name)
	if not chat.tool_registry then
		return false
	end
	if not chat.tool_registry.groups[group_name] then
		return false
	end
	chat.tool_registry:remove_group(group_name)
	log:debug("[automcp] detached tool group `%s` from chat %s", group_name, tostring(chat.id))
	return true
end

---@return CodeCompanion.Tools.Tool
function M.list_tool_groups()
	return {
		name = "mcp_list_tool_groups",
		cmds = {
			function(self, _args, _input)
				local config = require("codecompanion.config")
				local tools_config = config.interactions.chat.tools
				local groups = get_available_groups(tools_config)
				if vim.tbl_isempty(groups) then
					return { status = "success", data = "No tool groups are configured." }
				end
				-- Mark which groups are already attached to the current chat
				local chat = self.chat
				if chat and chat.tool_registry then
					for name, g in pairs(groups) do
						g.attached = chat.tool_registry.groups[name] ~= nil
					end
				end
				local rows = { { "group", "tools", "attached", "description" } }
				local names = vim.tbl_keys(groups)
				table.sort(names)
				for _, name in ipairs(names) do
					local g = groups[name]
					local tool_names = g.tools or {}
					table.sort(tool_names)
					table.insert(rows, {
						name,
						tostring(#tool_names),
						tostring(g.attached or false),
						g.description or "",
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
				return { status = "success", data = table.concat(lines, "\n") }
			end,
		},
		schema = {
			type = "function",
			["function"] = {
				name = "mcp_list_tool_groups",
				description = "List all tool groups available in the CodeCompanion config. Returns one row per group with `group` (name), `tools` (count of tools in the group), `attached` (whether the group is currently attached to this chat), and `description`. Call this before `mcp_enable_tool_group` or `mcp_disable_tool_group` to discover valid group names.",
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
				return "List tool groups?"
			end,
			success = function(self, stdout, meta)
				local chat = meta.tools.chat
				local llm_output = vim.iter(stdout or {}):flatten():join("\n")
				chat:add_tool_output(self, llm_output, "Tool groups listed")
			end,
			error = function(self, stderr, meta)
				local chat = meta.tools.chat
				local err = vim.iter(stderr or {}):flatten():join("\n")
				chat:add_tool_output(self, err or "Unknown error while listing tool groups")
			end,
		},
	}
end

---@return CodeCompanion.Tools.Tool
function M.enable_tool_group()
	return {
		name = "mcp_enable_tool_group",
		cmds = {
			function(self, args, _input)
				local name = args and args.name
				if not name or name == "" then
					return { status = "error", data = "The `name` argument is required." }
				end

				local config = require("codecompanion.config")
				local tools_config = config.interactions.chat.tools
				local group_config = tools_config.groups and tools_config.groups[name]
				if not group_config or not group_config.tools then
					return {
						status = "error",
						data = fmt(
							"Tool group %s is not configured. Call `mcp_list_tool_groups` to see available groups.",
							tool_display_name(name)
						),
					}
				end

				local chat = self.chat
				if not chat or not chat.tool_registry then
					return { status = "error", data = "No active chat buffer was detected." }
				end

				-- Already attached?
				if chat.tool_registry.groups[name] then
					return {
						status = "success",
						data = fmt("Tool group %s is already attached to this chat.", tool_display_name(name)),
					}
				end

				local ok = pcall(attach_tool_group, chat, name)
				if not ok then
					return {
						status = "error",
						data = fmt("Failed to attach tool group %s.", tool_display_name(name)),
					}
				end

				return {
					status = "success",
					data = fmt(
						"Tool group %s attached to this chat. Its tools are now registered and become callable on the next turn.",
						tool_display_name(name)
					),
				}
			end,
		},
		schema = {
			type = "function",
			["function"] = {
				name = "mcp_enable_tool_group",
				description = "Attach a tool group to the current chat by name. The group's tools become registered in the chat and callable on the LLM's next turn; do not try to invoke them in the same response. Use `mcp_list_tool_groups` first to discover valid group names.",
				parameters = {
					type = "object",
					properties = {
						name = {
							type = "string",
							description = "The name of the tool group to attach. Must be one of the names returned by `mcp_list_tool_groups`.",
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
				return fmt("Attach tool group %s?", tool_display_name(self.args.name or "?"))
			end,
			success = function(self, stdout, meta)
				local chat = meta.tools.chat
				local llm_output = vim.iter(stdout or {}):flatten():join("\n")
				chat:add_tool_output(
					self,
					llm_output,
					fmt("Tool group %s attached", tool_display_name(self.args.name or "?"))
				)
			end,
			error = function(self, stderr, meta)
				local chat = meta.tools.chat
				local err = vim.iter(stderr or {}):flatten():join("\n")
				chat:add_tool_output(
					self,
					err or fmt("Unknown error while attaching %s", tool_display_name(self.args.name or "?"))
				)
			end,
		},
	}
end

---@return CodeCompanion.Tools.Tool
function M.disable_tool_group()
	return {
		name = "mcp_disable_tool_group",
		cmds = {
			function(self, args, _input)
				local name = args and args.name
				if not name or name == "" then
					return { status = "error", data = "The `name` argument is required." }
				end

				local chat = self.chat
				if not chat or not chat.tool_registry then
					return { status = "error", data = "No active chat buffer was detected." }
				end

				if not chat.tool_registry.groups[name] then
					return {
						status = "error",
						data = fmt(
							"Tool group %s is not attached to this chat. Call `mcp_list_tool_groups` to see attached groups.",
							tool_display_name(name)
						),
					}
				end

				local removed = detach_tool_group(chat, name)
				if not removed then
					return {
						status = "error",
						data = fmt("Failed to detach tool group %s.", tool_display_name(name)),
					}
				end

				return {
					status = "success",
					data = fmt(
						"Tool group %s detached from this chat. Its tools are no longer callable.",
						tool_display_name(name)
					),
				}
			end,
		},
		schema = {
			type = "function",
			["function"] = {
				name = "mcp_disable_tool_group",
				description = "Detach a tool group from the current chat by name. After detaching, none of the group's tools will be callable for the rest of this chat. Use `mcp_list_tool_groups` first to discover which groups are currently attached.",
				parameters = {
					type = "object",
					properties = {
						name = {
							type = "string",
							description = "The name of the tool group to detach. Must be one of the names returned by `mcp_list_tool_groups`.",
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
				return fmt("Detach tool group %s?", tool_display_name(self.args.name or "?"))
			end,
			success = function(self, stdout, meta)
				local chat = meta.tools.chat
				local llm_output = vim.iter(stdout or {}):flatten():join("\n")
				chat:add_tool_output(
					self,
					llm_output,
					fmt("Tool group %s detached", tool_display_name(self.args.name or "?"))
				)
			end,
			error = function(self, stderr, meta)
				local chat = meta.tools.chat
				local err = vim.iter(stderr or {}):flatten():join("\n")
				chat:add_tool_output(
					self,
					err or fmt("Unknown error while detaching %s", tool_display_name(self.args.name or "?"))
				)
			end,
		},
	}
end

return M
