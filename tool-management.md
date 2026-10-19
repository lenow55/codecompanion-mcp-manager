---
name: tool-management
description: |
  Manage the capabilities available to a CodeCompanion chat.
  Discover, enable and disable tool groups and individual tools so the LLM can
  dynamically choose which capabilities a conversation needs.
  Triggers on: managing tools, enabling/disabling tools or tool groups,
  attaching/detaching capabilities, asking what tools are available.
---

# Tool Management

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

When you need to enable or disable a capability, follow this order:

1. **Search first.** Pick one keyword from the task — the most specific noun
   the user used (`jira`, `neovim`, `pdf`, …) — and call
   `search_tools("<keyword>")`. Only the first word of `query` is matched, so
   pass a single word. Searching first returns a small, targeted result
   instead of the whole catalog. If no specific keyword stands out in the
   task, skip the search and go straight to step 2.
2. **Fall back to the full list.** If the search returns no match, call
   `list_tools` and inspect everything. The search only matches names, so a
   capability whose name does not contain the keyword is invisible to it —
   the listing is the only way to find it (unless hidden by configuration).
3. **Decide.** Read the `description` (and `type`) of each candidate and pick
   the capability that matches the task. Prefer the narrowest capability that
   covers what you need.
4. **Act.** Call `enable_tool` (or `disable_tool`) with the exact `name` you
   read from the search or the listing.

Only use a `name` you actually saw in a `search_tools` or `list_tools` result.
Do not invent or guess names.

Exception: if the user asks for the full picture ("What tools do I have?"),
go straight to `list_tools` — a search would not answer that.

## `search_tools`

- **Parameters:** `query` (string, required) — pass a single keyword; only the
  **first word** is used. It is matched as a case-insensitive **substring**
  against:
  - tool group names,
  - the names of the tools inside each group,
  - allow-listed individual tool names.
- Returns one block per match, in the same format as `list_tools`
  (`name`, `type`, `attached`, `description`). For a group matched by its own
  name the `tools:` section lists **all of its member tools**; for a group
  matched only via its members it lists **only the member tools that
  matched**, not the whole group.
- If nothing matches, the result says so — that is the signal to fall back to
  `list_tools`.
- After a match, enable the capability with `enable_tool` using the `name`
  from the result block.

## `list_tools`

- **No parameters.** Use it as the fallback when `search_tools` finds nothing,
  or whenever the user wants the full picture.
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
  A name that is absent from both the search and the listing is therefore not
  necessarily "unknown" — it may simply be unavailable to you.

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

The user asks for something that needs a capability you do not have yet.

```
→ search_tools("<keyword from task>")   → candidate(s) with `description`
→ (no match) list_tools()               → inspect all capabilities
→ enable_tool("<best match>")           → narrowest capability that fits
→ (next turn) use its tools
```

Explain briefly why that capability fits the task.

### Discovery

User asks: "What tools do I have?"

```
→ list_tools()   → all capabilities with type, attachment and description
```

No search step — the user wants the full picture. Report what is already
enabled, what is available, and what each one provides.

### Targeted discovery

User asks for a specific capability and you know part of its name, e.g. "I
need the Jira tools."

```
→ search_tools("jira")                → matching group(s) + the member tools that matched
→ enable_tool("<capability name>")    → enable the capability from the result block
→ (no match) list_tools()             → check for a capability named differently
```

### Enabling a group or a tool

User says: "Attach the `neovim` tools."

```
→ search_tools("neovim")   → confirm it exists and note its `type`
→ (no match) list_tools()  → confirm it is really not available
→ enable_tool("neovim")
```

### Disabling a group

User says: "Remove the `neovim` tools from this chat."

```
→ search_tools("neovim")    → confirm it is attached and is a group
→ (no match) list_tools()
→ disable_tool("neovim")    → disables the group
```

### Trying to disable an individual tool

User says: "Remove the `subagents_research` tool."

```
→ search_tools("subagents_research")  → confirm it is `type: tool`
→ disable_tool("subagents_research")  → success, but it stays enabled
```

Tell the user that individual tools cannot be detached and remain available.
Do not retry the call.

### Name not found / not available

User asks to enable something that is not listed.

```
→ search_tools("foobar")    → no match
→ list_tools()              → the name is still not listed
```

Report that the capability is not available and list the valid names. Do not
call `enable_tool` with a name you have not seen, and do not guess
alternative names.

## Constraints

1. **Search before acting.** Call `search_tools` with a keyword from the task
   before any `enable_tool` or `disable_tool`; fall back to `list_tools` only
   if the search finds nothing. Search results are smaller and on-point, so
   fewer irrelevant capabilities end up in context.

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
