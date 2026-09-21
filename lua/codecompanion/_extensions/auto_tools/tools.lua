local log = require("codecompanion.utils.log")

local fmt = string.format

local M = {}

-- Glob helpers ---------------------------------------------------------------

local pattern_cache = {}

---Compile a glob pattern to an lpeg pattern, caching the result.
---@param pattern string
---@return userdata|false
local function compile_pattern(pattern)
	local cached = pattern_cache[pattern]
	if cached ~= nil then
		return cached
	end

	local compiled = false
	if vim.glob and vim.glob.to_lpeg then
		local ok, result = pcall(vim.glob.to_lpeg, pattern)
		if ok and result then
			compiled = result
		end
	end

	pattern_cache[pattern] = compiled
	return compiled
end

---Whether a compiled pattern matches the *whole* string.
---@param compiled userdata
---@param name string
---@return boolean
local function glob_matches(compiled, name)
	local ok_lpeg, lpeg = pcall(require, "lpeg")
	if not ok_lpeg or not lpeg then
		return false
	end

	-- `compiled * -P(1)` requires the match to consume the entire subject.
	local ok, result = pcall(function()
		return lpeg.match(compiled * -lpeg.P(1), name)
	end)
	return ok and result ~= nil
end

---Whether `name` matches any of the glob `patterns`.
---@param name string
---@param patterns? string[]
---@return boolean
local function matches_any(name, patterns)
	for _, pattern in ipairs(patterns or {}) do
		local compiled = compile_pattern(pattern)
		if compiled and glob_matches(compiled, name) then
			return true
		end
	end
	return false
end

---Public wrapper so other modules (e.g. the extension's `init`) can reuse the
---glob matching for approval allow-lists.
---@param name string
---@param patterns? string[]
---@return boolean
function M.matches_pattern(name, patterns)
	return matches_any(name, patterns)
end

-- Config helpers -------------------------------------------------------------

---@return table
local function get_opts()
	return require("codecompanion._extensions.auto_tools").opts()
end

---@return table
local function get_tools_config()
	return require("codecompanion.config").interactions.chat.tools
end

---Whether a config entry is an individual tool definition.
---A tool can be declared either as a factory (`path`/`callback`/`extends`) or as
---an inline definition (`schema`/`cmds`), the latter being how extensions such as
---`codecompanion-subagents.nvim` register their tools directly into the config.
---@param name string
---@param config any
---@return boolean
local function is_tool_config(name, config)
	if name == "opts" or name == "groups" then
		return false
	end
	if type(config) ~= "table" then
		return false
	end
	return config.path ~= nil
		or config.callback ~= nil
		or config.extends ~= nil
		or config.schema ~= nil
		or config.cmds ~= nil
end

---Collect all tool *groups* available in the tools config.
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

---Collect all individual tools available in the tools config.
---@param tools_config table
---@return table<string, table> tools
local function get_available_tools(tools_config)
	local tools = {}
	for name, tool_config in pairs(tools_config) do
		if is_tool_config(name, tool_config) then
			tools[name] = tool_config
		end
	end
	return tools
end

---Resolve a user-provided name to a group or an individual tool, honouring the
---deny-list and the individual-tools allow-list.
---Order: deny -> group -> individual tool.
---@param name string
---@param tools_config table
---@param opts table
---@return table|nil target { type: "group"|"tool", config: table }
local function resolve_target(name, tools_config, opts)
	if matches_any(name, opts.deny_groups) then
		return nil
	end

	local groups = tools_config.groups or {}
	if groups[name] then
		return { type = "group", config = groups[name] }
	end

	local tool_config = tools_config[name]
	if is_tool_config(name, tool_config) and matches_any(name, opts.individual_tools) then
		return { type = "tool", config = tool_config }
	end

	return nil
end

---A single, intentionally vague error used both for denied and unknown names so
---the LLM cannot tell a blocked group apart from a non-existent one.
---@param name string
---@return table
local function not_available(name)
	return {
		status = "error",
		data = fmt("`%s` is not available. Call `list_tools` to see what can be enabled.", name),
	}
end

-- Attach / detach ------------------------------------------------------------

---@param chat CodeCompanion.Chat
---@param group_name string
---@return boolean ok
local function attach_group(chat, group_name)
	if not (chat.tools and chat.tool_registry) then
		return false
	end
	local tools_config = get_tools_config()
	local group_config = tools_config.groups and tools_config.groups[group_name]
	if not group_config or not group_config.tools then
		return false
	end
	local added = chat.tool_registry:add_group(group_name, { config = tools_config })
	log:debug("[auto_tools] attached tool group `%s` to chat %s", group_name, tostring(chat.id))
	return added ~= nil
end

---@param chat CodeCompanion.Chat
---@param tool_name string
---@return boolean ok
local function attach_tool(chat, tool_name)
	if not chat.tool_registry then
		return false
	end
	local tools_config = get_tools_config()
	local added = chat.tool_registry:add_single_tool(tool_name, { config = tools_config[tool_name] })
	log:debug("[auto_tools] attached individual tool `%s` to chat %s", tool_name, tostring(chat.id))
	return added ~= nil
end

---@param chat CodeCompanion.Chat
---@param group_name string
---@return boolean removed
local function detach_group(chat, group_name)
	if not chat.tool_registry then
		return false
	end
	if not chat.tool_registry.groups[group_name] then
		return false
	end
	chat.tool_registry:remove_group(group_name)
	log:debug("[auto_tools] detached tool group `%s` from chat %s", group_name, tostring(chat.id))
	return true
end

-- Tools ----------------------------------------------------------------------

---@return CodeCompanion.Tools.Tool
function M.list_tools()
	return {
		name = "list_tools",
		cmds = {
			function(self, _args, _input)
				local tools_config = get_tools_config()
				local opts = get_opts()
				local chat = self.chat
				local registry = chat and chat.tool_registry or nil

				local entries = {}

				-- Groups first so that a name shared by a group and a tool resolves
				-- in favour of the group (matching `resolve_target`).
				for name, group in pairs(get_available_groups(tools_config)) do
					if not matches_any(name, opts.deny_groups) then
						entries[name] = {
							name = name,
							type = "group",
							description = group.description,
							tools = group.tools,
							attached = registry ~= nil and registry.groups[name] ~= nil,
						}
					end
				end

				for name, tool_config in pairs(get_available_tools(tools_config)) do
					if
						entries[name] == nil
						and not matches_any(name, opts.deny_groups)
						and matches_any(name, opts.individual_tools)
					then
						entries[name] = {
							name = name,
							type = "tool",
							-- Inline tools keep their description inside the schema.
							description = tool_config.description
								or vim.tbl_get(tool_config, "schema", "function", "description"),
							attached = registry ~= nil and registry.in_use[name] ~= nil,
						}
					end
				end

				if vim.tbl_isempty(entries) then
					return { status = "success", data = "No tools or tool groups are available." }
				end

				local names = vim.tbl_keys(entries)
				table.sort(names)

				local blocks = {}
				for _, name in ipairs(names) do
					local entry = entries[name]
					local lines = {
						"---",
						fmt("name: %s", entry.name),
						fmt("type: %s", entry.type),
						fmt("attached: %s", tostring(entry.attached)),
						fmt("description: %s", entry.description or ""),
					}
					if entry.type == "group" then
						local tool_names = vim.deepcopy(entry.tools or {})
						table.sort(tool_names)
						table.insert(lines, "tools:")
						for _, tool_name in ipairs(tool_names) do
							table.insert(lines, fmt("- %s", tool_name))
						end
					end
					table.insert(blocks, table.concat(lines, "\n"))
				end

				return { status = "success", data = table.concat(blocks, "\n") }
			end,
		},
		schema = {
			type = "function",
			["function"] = {
				name = "list_tools",
				description = "List every capability that can be enabled in this chat: tool groups and individual tools. Returns one block per capability with `name`, `type` (`group` or `tool`), `attached` (whether it is currently enabled in this chat), `description`, and, for groups, a `tools` list of member tool names. Call this before `enable_tool` or `disable_tool` to discover valid names.",
				parameters = {
					type = "object",
					properties = vim.empty_dict(),
					required = {},
					additionalProperties = false,
				},
				strict = true,
			},
		},
		output = {
			prompt = function(_self, _meta)
				return "List available tools?"
			end,
			success = function(self, stdout, meta)
				local chat = meta.tools.chat
				local llm_output = vim.iter(stdout or {}):flatten():join("\n")
				chat:add_tool_output(self, llm_output, "Tools listed")
			end,
			error = function(self, stderr, meta)
				local chat = meta.tools.chat
				local err = vim.iter(stderr or {}):flatten():join("\n")
				chat:add_tool_output(self, err or "Unknown error while listing tools")
			end,
		},
	}
end

---@return CodeCompanion.Tools.Tool
function M.enable_tool()
	return {
		name = "enable_tool",
		cmds = {
			function(self, args, _input)
				local name = args and args.name
				if not name or name == "" then
					return { status = "error", data = "The `name` argument is required." }
				end

				local tools_config = get_tools_config()
				local opts = get_opts()
				local target = resolve_target(name, tools_config, opts)
				if not target then
					return not_available(name)
				end

				local chat = self.chat
				if not chat or not chat.tool_registry then
					return { status = "error", data = "No active chat buffer was detected." }
				end

				if target.type == "group" then
					if chat.tool_registry.groups[name] then
						return { status = "success", data = fmt("`%s` is already enabled in this chat.", name) }
					end
					local ok, added = pcall(attach_group, chat, name)
					if not ok or not added then
						return { status = "error", data = fmt("Failed to enable `%s`.", name) }
					end
					return {
						status = "success",
						data = fmt("`%s` enabled. Its tools become callable on your next turn.", name),
					}
				end

				if chat.tool_registry.in_use[name] then
					return { status = "success", data = fmt("`%s` is already enabled in this chat.", name) }
				end
				local ok, added = pcall(attach_tool, chat, name)
				if not ok or not added then
					return { status = "error", data = fmt("Failed to enable `%s`.", name) }
				end
				return {
					status = "success",
					data = fmt("`%s` enabled. It becomes callable on your next turn.", name),
				}
			end,
		},
		schema = {
			type = "function",
			["function"] = {
				name = "enable_tool",
				description = "Enable a capability (a tool group or an individual tool) in the current chat by name. Its tools become callable on your next turn; do not try to invoke them in the same response. Use `list_tools` first to discover valid names and to understand what each capability provides.",
				parameters = {
					type = "object",
					properties = {
						name = {
							type = "string",
							description = "The name of the group or individual tool to enable. Must be one of the `name` values returned by `list_tools`.",
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
				return fmt("Enable `%s`?", self.args.name or "?")
			end,
			success = function(self, stdout, meta)
				local chat = meta.tools.chat
				local llm_output = vim.iter(stdout or {}):flatten():join("\n")
				chat:add_tool_output(self, llm_output, fmt("`%s` enabled", self.args.name or "?"))
			end,
			error = function(self, stderr, meta)
				local chat = meta.tools.chat
				local err = vim.iter(stderr or {}):flatten():join("\n")
				chat:add_tool_output(self, err or fmt("Unknown error while enabling `%s`", self.args.name or "?"))
			end,
		},
	}
end

---@return CodeCompanion.Tools.Tool
function M.disable_tool()
	return {
		name = "disable_tool",
		cmds = {
			function(self, args, _input)
				local name = args and args.name
				if not name or name == "" then
					return { status = "error", data = "The `name` argument is required." }
				end

				local tools_config = get_tools_config()
				local opts = get_opts()
				local target = resolve_target(name, tools_config, opts)
				if not target then
					return not_available(name)
				end

				local chat = self.chat
				if not chat or not chat.tool_registry then
					return { status = "error", data = "No active chat buffer was detected." }
				end

				if target.type == "group" then
					if not chat.tool_registry.groups[name] then
						return { status = "error", data = fmt("`%s` is not enabled in this chat.", name) }
					end
					local removed = detach_group(chat, name)
					if not removed then
						return { status = "error", data = fmt("Failed to disable `%s`.", name) }
					end
					return { status = "success", data = fmt("`%s` disabled. Its tools are no longer callable.", name) }
				end

				-- Individual tools are registered one-by-one and CodeCompanion's
				-- ToolRegistry has no per-tool removal. We refuse to detach them (we
				-- neither patch the core nor duplicate its bookkeeping) and leave the
				-- tool enabled. `status = "success"` is deliberate: an error would be
				-- fed back to the LLM (auto_submit_errors) and cause retry loops.
				if not chat.tool_registry.in_use[name] then
					return { status = "error", data = fmt("`%s` is not enabled in this chat.", name) }
				end

				log:warn("[auto_tools] cannot disable individual tool `%s`; leaving it enabled", name)
				vim.notify(
					fmt("Individual tool `%s` cannot be disabled and stays enabled in this chat.", name),
					vim.log.levels.WARN,
					{ title = "CodeCompanion" }
				)
				return {
					status = "success",
					data = fmt(
						"`%s` is an individual tool and cannot be disabled on its own; it stays enabled in this chat. Only tool groups can be disabled.",
						name
					),
				}
			end,
		},
		schema = {
			type = "function",
			["function"] = {
				name = "disable_tool",
				description = "Disable a capability (a tool group or an individual tool) in the current chat by name. Note: individual tools cannot be disabled on their own and remain enabled; only tool groups can be disabled. Use `list_tools` first to discover valid names.",
				parameters = {
					type = "object",
					properties = {
						name = {
							type = "string",
							description = "The name of the group or individual tool to disable. Must be one of the `name` values returned by `list_tools`.",
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
				return fmt("Disable `%s`?", self.args.name or "?")
			end,
			success = function(self, stdout, meta)
				local chat = meta.tools.chat
				local llm_output = vim.iter(stdout or {}):flatten():join("\n")
				chat:add_tool_output(self, llm_output, fmt("`%s` disabled", self.args.name or "?"))
			end,
			error = function(self, stderr, meta)
				local chat = meta.tools.chat
				local err = vim.iter(stderr or {}):flatten():join("\n")
				chat:add_tool_output(self, err or fmt("Unknown error while disabling `%s`", self.args.name or "?"))
			end,
		},
	}
end

return M
