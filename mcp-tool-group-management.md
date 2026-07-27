---
name: mcp-tool-group-management
description: |
  Manage MCP server tool groups attached to CodeCompanion chats.
  Attach, detach, and list tool groups so the LLM can dynamically choose
  which MCP server capabilities are available for a given conversation.
  Triggers on: managing tool groups, attaching/detaching MCP tools,
  enabling/disabling groups in chat, checking what groups are available.
---

# MCP Tool Group Management

## Overview

CodeCompanion allows tools to be organized into **groups**. Each MCP server
that CodeCompanion connects to registers its tools under a group with the
name `mcp:<server_name>` (produced by `mcp.tool_prefix() .. server_name`).
Additionally, this extension registers its own group `auto_mcp` containing
the lifecycle management tools themselves (`mcp_list_servers`,
`mcp_enable_server`, `mcp_disable_server`, `mcp_list_tool_groups`,
`mcp_enable_tool_group`, `mcp_disable_tool_group`).

A group can be **attached** to a specific chat buffer via the chat's
`tool_registry`. Once attached, all tools within the group become callable
by the LLM on the next turn. Detaching a group removes all its tools from
the chat.

The six tools are organized into two categories:

| Category                  | Tools                                                                     |
| ------------------------- | ------------------------------------------------------------------------- |
| **MCP server lifecycle**  | `mcp_list_servers`, `mcp_enable_server`, `mcp_disable_server`             |
| **Tool group management** | `mcp_list_tool_groups`, `mcp_enable_tool_group`, `mcp_disable_tool_group` |

The server lifecycle tools start/stop MCP server **processes** and
automatically attach/detach the server's tool group. The group management
tools operate purely on the **chat's tool registry** — they attach or detach
existing groups without starting or stopping any server process.

## Available Tools

### `mcp_list_servers`

- **No parameters.**
- Returns a markdown table: `name | started | ready | tools | default`.
- Always call this first to discover valid server names before using
  `mcp_enable_server` or `mcp_disable_server`.

### `mcp_enable_server`

- **Parameters:** `name` (string, required).
- Starts the MCP server process if not already running.
- Registers the server's tools into the current chat via `tool_registry:add_group`.
- **Important:** Newly registered tools appear in the system prompt and
  become callable on the LLM's **next turn**. Do not attempt to invoke them
  in the same response.

### `mcp_disable_server`

- **Parameters:** `name` (string, required).
- Stops the MCP server process.
- Removes the server's tool group from the current chat via `tool_registry:remove_group`.
- After disabling, none of the server's tools will be callable for the rest
  of this chat.

### `mcp_list_tool_groups`

- **No parameters.**
- Returns a markdown table: `group | tools | attached | description`.
- Lists **all** groups configured in `config.interactions.chat.tools.groups`,
  including both MCP server groups (`mcp:<name>`) and custom groups (like
  `auto_mcp`).
- The `attached` column shows `true`/`false` depending on whether the group
  is currently attached to **this** chat.
- Always call this first to discover valid group names and their attachment
  status before using `mcp_enable_tool_group` or `mcp_disable_tool_group`.

### `mcp_enable_tool_group`

- **Parameters:** `name` (string, required).
- Attaches an existing tool group to the current chat via
  `tool_registry:add_group`.
- Does **not** start any MCP server process — it only registers tools that
  are already available in the global config.
- If the group is already attached, returns success with "already attached"
  message.
- **Important:** Newly attached tools become callable on the LLM's **next
  turn**. Do not attempt to invoke them in the same response.

### `mcp_disable_tool_group`

- **Parameters:** `name` (string, required).
- Detaches a tool group from the current chat via
  `tool_registry:remove_group`.
- Does **not** stop any MCP server process — it only removes the group from
  this chat's tool registry.
- After detaching, none of the group's tools will be callable for the rest
  of this chat.

## Triggers

Use these tools when the user asks to:

1. **"What MCP tools/groups do I have?" / "What tools are available?"**
   → Call `mcp_list_tool_groups` (and optionally `mcp_list_servers`).

2. **"Enable/attach the `<name>` tools" / "Add `<name>` tools to this chat"**
   → If `<name>` is an MCP server: use `mcp_enable_server` (starts process +
   attaches group).
   → If `<name>` is a configured group: use `mcp_enable_tool_group` (attaches
   group only, no process management).
   → When unsure which to use: call `mcp_list_tool_groups` first to check
   options.

3. **"Disable/detach the `<name>` tools" / "Remove `<name>` tools from chat"**
   → If the user wants to stop the server entirely: use `mcp_disable_server`.
   → If the user only wants to remove the group from one chat: use
   `mcp_disable_tool_group`.

4. **"Which MCP servers are running?" / "Status of MCP servers?"**
   → Call `mcp_list_servers`.

5. **"I don't need `<name>` anymore" / "Clean up unused tools"**
   → Call `mcp_disable_tool_group` for each unwanted group, then
   `mcp_disable_server` if the server process should also be stopped.

## Scenarios

### Scenario 1: Discovery

The user opens a chat and asks "What tools do I have?"

```
→ mcp_list_servers()        → table of servers, their status, tool counts
→ mcp_list_tool_groups()    → table of all groups with attachment status
```

Present both results to the user. Mention which groups are already attached
to the current chat and which are available but not yet attached.

### Scenario 2: Attaching a specific server's tools

The user says: "Enable the filesystem server."

```
→ mcp_list_servers()            → confirm "filesystem" exists and is valid
→ mcp_enable_server("filesystem") → starts process, attaches group
```

Tell the user the tools are registered and will be callable on the next
turn. Do **not** try to call any filesystem tool in the same response.

### Scenario 3: Attaching a group without starting a process

The user says: "Attach the `auto_mcp` group" or "I want the MCP manager
tools in this chat."

```
→ mcp_list_tool_groups()              → confirm "auto_mcp" exists
→ mcp_enable_tool_group("auto_mcp")   → attaches group to chat
```

The group's tools become available on the next turn.

### Scenario 4: Detaching a group but keeping the server running

The user says: "Remove the git tools from this chat, but don't stop the
server."

```
→ mcp_list_tool_groups()             → confirm "mcp:git" is attached
→ mcp_disable_tool_group("mcp:git")  → detaches from chat only
```

The server process keeps running. If the user later wants the tools back,
`mcp_enable_tool_group("mcp:git")` will re-attach them without restarting.

### Scenario 5: Full cleanup

The user says: "I'm done with the git server, stop it completely."

```
→ mcp_list_tool_groups()        → confirm "mcp:git" group exists
→ mcp_disable_tool_group("mcp:git")  → remove from chat first
→ mcp_disable_server("git")     → stop the server process
```

Or simply:

```
→ mcp_disable_server("git")     → stops process AND removes group from chat
```

### Scenario 6: Group not found

The user asks to enable a group that doesn't exist.

```
→ mcp_list_tool_groups()                    → group "foobar" is not listed
→ mcp_enable_tool_group("foobar")           → returns error:
  "Tool group `foobar` is not configured. Call `mcp_list_tool_groups`
   to see available groups."
```

Report the error to the user and list the valid group names.

## Constraints

1. **Always discover before acting.** Call `mcp_list_tool_groups` (for group
   operations) or `mcp_list_servers` (for server operations) before calling
   enable/disable. Never guess group or server names.

2. **Tools are not callable in the same turn.** When you attach or enable a
   group, the tools become available to the LLM only on the **next turn**.
   Never attempt to call a newly attached tool in the same response.

3. **Group management vs. server lifecycle.** The tool group tools
   (`mcp_enable_tool_group` / `mcp_disable_tool_group`) do **not** start or
   stop server processes. They only manage what's in the chat's
   `tool_registry`. If the server process is stopped, its group config may
   still exist but the tools won't function when called.

4. **No duplicate attachment.** If a group is already attached,
   `mcp_enable_tool_group` returns a success message ("already attached")
   rather than an error. Similarly, `mcp_enable_server` checks if the group
   is already registered before attaching.

5. **Detaching is irreversible within a chat session.** Once detached, the
   group's tools are immediately removed from the chat. Previous tool call
   results in the conversation history are preserved, but the tools can no
   longer be invoked unless re-attached.
