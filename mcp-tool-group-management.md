---
name: mcp-tool-group-management
description: |
  Manage tool groups attached to CodeCompanion chats.
  Attach, detach, and list tool groups so the LLM can dynamically choose
  which capabilities are available for a given conversation.
  Triggers on: managing tool groups, attaching/detaching tools,
  enabling/disabling groups in chat, checking what groups are available.
---

# MCP Tool Group Management

## Overview

CodeCompanion organizes tools into **groups**. A group can be **attached**
to a chat to make its tools callable by the LLM. Detaching a group removes
its tools from the chat.

The three available tools:

| Tool                     | Purpose                                      |
| ------------------------ | -------------------------------------------- |
| `mcp_list_tool_groups`   | List all groups with attachment status       |
| `mcp_enable_tool_group`  | Attach a group to the current chat           |
| `mcp_disable_tool_group` | Detach a group from the current chat         |

## Available Tools

### `mcp_list_tool_groups`

- **No parameters.**
- Returns one block per group with `name`, `attached`, `description`, and a
  `tools` list of tool names.
- Call this first to discover valid group names and their attachment status.

### `mcp_enable_tool_group`

- **Parameters:** `name` (string, required).
- Attaches a tool group to the current chat.
- If the group is already attached, returns success with "already attached".
- **Tools become callable on the LLM's next turn** — do not invoke them
  in the same response.

### `mcp_disable_tool_group`

- **Parameters:** `name` (string, required).
- Detaches a tool group from the current chat.
- After detaching, the group's tools are no longer callable for this chat.

## Triggers

1. **"What tools do I have?" / "What groups are available?"**
   → `mcp_list_tool_groups`

2. **"Attach/add `<name>` tools"**
   → `mcp_list_tool_groups` to verify the name, then `mcp_enable_tool_group`

3. **"Detach/remove `<name>` tools"**
   → `mcp_list_tool_groups` to confirm it's attached, then `mcp_disable_tool_group`

4. **"I don't need `<name>` anymore"**
   → `mcp_disable_tool_group` for each unwanted group.

## Scenarios

### Discovery

User asks: "What tools do I have?"

```
→ mcp_list_tool_groups()   → list of all groups with attachment status
```

Report which groups are attached and which are available.

### Attaching a group

User says: "Attach the `neovim` group."

```
→ mcp_list_tool_groups()           → confirm "neovim" exists
→ mcp_enable_tool_group("neovim")  → attaches to chat
```

Tools become available on the next turn.

### Detaching a group

User says: "Remove the `neovim` tools from this chat."

```
→ mcp_list_tool_groups()            → confirm "neovim" is attached
→ mcp_disable_tool_group("neovim")  → detaches from chat
```

### Group not found

User asks to enable a group that doesn't exist.

```
→ mcp_list_tool_groups()               → group "foobar" not listed
→ mcp_enable_tool_group("foobar")      → returns error
```

Report the error and list valid group names.

## Constraints

1. **Always discover before acting.** Call `mcp_list_tool_groups` before
   enable/disable. Never guess group names.

2. **Tools are not callable in the same turn.** Newly attached tools become
   available only on the LLM's **next turn**.

3. **Detaching is reversible.** A detached group can be re-attached at any
   time with `mcp_enable_tool_group`. Previous tool call results in the
   conversation history are preserved.
