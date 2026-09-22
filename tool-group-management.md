---
name: tool-group-management
description: |
  Manage the capabilities available to a CodeCompanion chat.
  Discover, enable and disable tool groups and individual tools so the LLM can
  dynamically choose which capabilities a conversation needs.
  Triggers on: managing tools, enabling/disabling tools or tool groups,
  attaching/detaching capabilities, asking what tools are available.
---

# Tool Group Management

## Overview

A CodeCompanion chat exposes capabilities, and each capability is either a
**tool group** (a bundle of related tools) or an **individual tool**. Both are
enabled in exactly the same way, by name. You do not need to know which is
which — but you must understand **what a capability gives you** before enabling
it, so you enable it for the right reason.

| Tool           | Purpose                                                                  |
| -------------- | ------------------------------------------------------------------------ |
| `list_tools`   | List all capabilities with their `type`, `attached` and `description`    |
| `search_tools` | Search groups and tools by name (first word of `query`, substring match) |
| `enable_tool`  | Enable a capability (group or individual tool)                           |
| `disable_tool` | Disable a tool group (individual tools stay enabled)                     |

## Workflow

Always follow the same three steps:

1. **Discover.** Call `list_tools` to see what exists and what is already
   enabled — or `search_tools` when you already know part of a tool or group
   name and only need the matching capabilities.
2. **Decide.** Read the `description` (and `type`) of each candidate and pick
   the capability that matches the task at hand. Prefer the narrowest
   capability that covers what you need.
3. **Act.** Call `enable_tool` (or `disable_tool`) with the exact `name` you
   read from the listing.

Never guess a name. Never enable a capability you have not seen in `list_tools`
or `search_tools`.

## `list_tools`

- **No parameters.**
- Returns one block per capability:

  ```
  ---
  name: agent
  type: group
  attached: false
  description: Agent - Can run code, edit code and modify files on your behalf
  tools:
  - create_file
  - read_file
  ...
  ```

  Individual tools have `type: tool` and no `tools:` list.

- `attached: true` means the capability is already enabled in this chat — there
  is no need to enable it again.
- The `description` explains **what the capability is for**. Use it to decide
  which one to enable for a given task.
- Some capabilities are **hidden by configuration** and will never appear here:
  restricted groups and tools that are not allowed to be used on their own.
  A name that is absent is therefore not necessarily "unknown" — it may simply
  be unavailable to you.

## `search_tools`

- **Parameters:** `query` (string, required) — a free-form query.
- Only the **first word** of `query` is used. It is matched as a
  case-insensitive **substring** against:
  - tool group names,
  - the names of the tools inside each group,
  - allow-listed individual tool names.
- Returns one block per match, in the same format as `list_tools`
  (`name`, `type`, `attached`, `description`). For a group matched by its own
  name the `tools:` section lists **all of its member tools**; for a group
  matched only via its members it lists **only the member tools that
  matched**, not the whole group.
- If nothing matches, the result says so and suggests `list_tools`.
- After a match, enable the capability with `enable_tool` using the `name`
  from the result block.

## `enable_tool`

- **Parameters:** `name` (string, required) — a `name` from `list_tools` or
  `search_tools`.
- Enables the capability in the current chat.
- If it is already enabled, returns success with "already enabled".
- **The capability's tools become callable on your next turn.** Do not try to
  call them in the same response.

## `disable_tool`

- **Parameters:** `name` (string, required) — a `name` from `list_tools` or
  `search_tools`.
- Disables a **tool group**; its tools are no longer callable.
- **Individual tools cannot be disabled.** The call returns success with an
  explanation that the tool stays enabled. This is final — do not retry.

## Scenarios

### Choosing what to enable

The user asks you to do something that needs a capability you do not have yet.

```
→ list_tools()                      → inspect `description` of each candidate
→ enable_tool("<best match>")       → enable the narrowest capability that fits
→ (next turn) use its tools
```

Explain briefly why that capability fits the task.

### Discovery

User asks: "What tools do I have?"

```
→ list_tools()   → all capabilities with type, attachment and description
```

Report what is already enabled, what is available, and what each one provides.

### Targeted discovery

User asks for a specific capability and you know part of its name, e.g. "I
need the Jira tools."

```
→ search_tools("jira")               → matching group(s) + the member tools that matched
→ enable_tool("<capability name>")   → enable the capability from the result block
```

Prefer `search_tools` over `list_tools` when the query is narrow; use
`list_tools` when you need the full picture.

### Enabling a group or a tool

User says: "Attach the `neovim` tools."

```
→ list_tools()            → confirm "neovim" exists and note its `type`
→ enable_tool("neovim")   → enables it in the chat
```

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

Tell the user that individual tools cannot be detached and remain available.
Do not retry the call.

### Name not found / not available

User asks to enable something that is not listed.

```
→ list_tools()                 → the name is not listed
→ enable_tool("foobar")        → returns "not available"
```

Report the error and list the valid names. Do not guess alternative names.

## Constraints

1. **Always discover before acting.** Call `list_tools` (or `search_tools`
   when you know part of a name) before `enable_tool` or `disable_tool`.
   Never guess names.

2. **Enable for a reason.** Pick the capability whose `description` matches the
   task. Do not enable capabilities "just in case".

3. **Capabilities are not callable in the same turn.** Newly enabled tools
   become available only on your **next turn**.

4. **Do not re-enable.** If `attached: true`, the capability is already enabled.

5. **Individual tools cannot be disabled.** `disable_tool` on an individual tool
   succeeds but leaves it enabled; do not retry.

6. **Disabling a group is reversible.** A disabled group can be re-enabled at
   any time with `enable_tool`. Previous tool call results in the conversation
   history are preserved.
