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

---@param name string
local function tool_display_name(name)
	return "`" .. name .. "`"
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
