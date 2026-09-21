---
name: mcp-tool-group-management
description: |
  Manage capabilities attached to CodeCompanion chats.
  Enable, disable, and list tool groups and individual tools so the LLM can
  dynamically choose which capabilities are available for a given conversation.
  Triggers on: managing tool groups, enabling/disabling tools,
  attaching/detaching groups in chat, checking what groups are available.
---

# Tool Group Management

## Overview

CodeCompanion organizes capabilities into **tool groups** and **individual
tools**. Both can be **enabled** in a chat to make their tools callable by the
LLM. Disabling a group removes its tools from the chat.

You do not need to care whether a capability is a group or an individual tool:
call the same tools by name. `list_tools` tells you the `type` and the
`description` so you can pick the right capability for the task.

| Tool            | Purpose                                                    |
| --------------- | ---------------------------------------------------------- |
| `list_tools`    | List all capabilities with type, attachment and description |
| `enable_tool`   | Enable a capability (group or individual tool)             |
| `disable_tool`  | Disable a tool group (individual tools stay enabled)       |

## Available Tools

### `list_tools`

- **No parameters.**
- Returns one block per capability with `name`, `type` (`group` or `tool`),
  `attached`, `description`, and, for groups, a `tools` list of member names.
- Call this first to discover valid names, what each capability does, and its
  attachment status.
- Some capabilities may be **hidden** by configuration: denied groups and tools
  that may not be used on their own never appear here.

### `enable_tool`

- **Parameters:** `name` (string, required).
- Enables a capability in the current chat.
- If it is already enabled, returns success with "already enabled".
- **Capabilities become callable on the LLM's next turn** — do not invoke them
  in the same response.

### `disable_tool`

- **Parameters:** `name` (string, required).
- Disables a **tool group**; its tools are no longer callable.
- **Individual tools cannot be disabled.** The call returns success with an
  explanation that the tool stays enabled. Do not retry — repeating it is
  pointless.

## Triggers

1. **"What tools do I have?" / "What groups are available?"**
   → `list_tools`

2. **"Attach/add `<name>` tools"**
   → `list_tools` to verify the name, then `enable_tool`

3. **"Detach/remove `<name>` tools"**
   → `list_tools` to confirm it's attached, then `disable_tool`

4. **"I don't need `<name>` anymore"**
   → `disable_tool` for each unwanted group.

## Scenarios

### Discovery

User asks: "What tools do I have?"

```
→ list_tools()   → all capabilities with type, attachment and description
```

Report which are enabled, which are available, and what each provides.

### Enabling a capability

User says: "Attach the `neovim` tools."

```
→ list_tools()            → confirm "neovim" exists (note its `type`)
→ enable_tool("neovim")   → enables it in the chat
```

Capabilities become available on the next turn.

### Disabling a group

User says: "Remove the `neovim` tools from this chat."

```
→ list_tools()             → confirm "neovim" is attached and is a group
→ disable_tool("neovim")   → disables the group
```

### Trying to disable an individual tool

User says: "Remove the `subagents_research` tool."

```
→ list_tools()                       → confirm it is `type: tool`
→ disable_tool("subagents_research") → success, but it stays enabled
```

Explain that individual tools cannot be detached and remain available. Do not
retry.

### Name not found / not allowed

User asks to enable a capability that isn't listed.

```
→ list_tools()                    → the name is not listed
→ enable_tool("foobar")           → returns "not available"
```

Report the error and list valid capability names. A capability may be absent
either because it does not exist or because it is restricted by configuration —
both look identical, so do not guess names.

## Constraints

1. **Always discover before acting.** Call `list_tools` before enable/disable.
   Never guess names.

2. **Capabilities are not callable in the same turn.** Newly enabled tools
   become available only on the LLM's **next turn**.

3. **Individual tools cannot be disabled.** `disable_tool` on an individual tool
   succeeds but leaves it enabled; do not retry.

4. **Disabling a group is reversible.** A disabled group can be re-enabled at
   any time with `enable_tool`. Previous tool call results in the conversation
   history are preserved.
