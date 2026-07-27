# codecompanion-mcp-manager.nvim

Расширение для [codecompanion.nvim](https://github.com/olimorris/codecompanion.nvim),
регистрировающее группу тулов `auto_mcp`, которые позволяют LLM самостоятельно
управлять MCP-серверами и тул-группами в чате: включать/отключать серверы,
а также аттачить/детачить группы тулов.

## Установка

Добавьте репозиторий в `runtimepath` и подключите расширение в `setup`:

````lua
require("codecompanion").setup({
  extensions = {
    automcp = {
      collapse_tools = true,
      -- см. опции ниже
    },
  },
})
````

## Параметры

| Параметр | Тип | По умолчанию | Описание |
|---|---|---|---|
| `collapse_tools` | `boolean` | `true` | Свернуть все тулы в одну группу `auto_mcp` в буфере чата. |
| `no_approval_for` | `string[]` | `{}` | Имена MCP-серверов и тул-групп, которые LLM может включать/отключать **без подтверждения**. Применяется ко всем name-based тулам. |
| `tool_opts` | `table<string, ToolOpts>` | `{}` | Настройки отдельных тулов. Ключ — имя toolа без префикса `mcp_`. |

### `ToolOpts`

| Параметр | Тип | Описание |
|---|---|---|
| `require_approval_before` | `boolean \| fun(self, tools): boolean` | Запрашивать подтверждение пользователя перед запуском toolа. Может быть функцией, чтобы решать динамически. |
| `requires_approval` | `boolean` | **Устарел** — используйте `require_approval_before`. |
| `no_approval_for` | `string[]` | Имена серверов/групп, обходящие подтверждение **только для этого toolа**. Merджится поверх верхнего `no_approval_for`. |

## Подтверждение и `no_approval_for`

По умолчанию тулы следуют правилу `require_approval_before`, заданному
для каждого toolа (или устаревшему `requires_approval`). Параметр
`no_approval_for` позволяет разрешить LLM включать и отключать
**конкретные** MCP-серверы или тул-группы без запроса подтверждения,
в то время как все остальные имена продолжают следовать
`require_approval_before`.

Список задаётся на двух уровнях:

- **Верхний** (`opts.no_approval_for`) — применяется ко всем name-based
  тулам: `mcp_enable_server`, `mcp_disable_server`,
  `mcp_enable_tool_group`, `mcp_disable_tool_group`.
- **На tool** (`opts.tool_opts[<tool>].no_approval_for`) — тот же список,
  но scoped на один tool. Merджится **поверх** верхнего, так что имя,
  указанное в любом из них, обходит подтверждение для этого toolа.

Для имени из белого списка approval short-circuit-ит и tool запускается
сразу. Для любого другого имени (или когда `name` отсутствует) действует
обычное правило `require_approval_before` этого toolа.

> **Примечание:** `mcp_list_servers` и `mcp_list_tool_groups` не принимают
> аргумент `name`, поэтому `no_approval_for` на них никак не влияет — их
> подтверждение регулируется только `require_approval_before`.

## Пример

````lua
require("codecompanion").setup({
  extensions = {
    automcp = {
      -- LLM может включать/отключать эти серверы и группы без подтверждения
      no_approval_for = { "filesystem", "git", "mcp:context7" },
      tool_opts = {
        enable_server = {
          require_approval_before = true, -- но спрашивать перед любым другим сервером
          no_approval_for = { "safe-server" }, -- per-tool добавление в белый список
        },
        disable_server = {
          require_approval_before = true,
        },
        enable_tool_group = {}, -- без базового подтверждения
        disable_tool_group = {},
      },
    },
  },
})
````

С конфигурацией выше:

- `mcp_enable_server("filesystem")` → запускается без подтверждения.
- `mcp_enable_server("safe-server")` → без подтверждения (per-tool).
- `mcp_enable_server("random-server")` → запрашивает подтверждение (базовое правило).
- `mcp_disable_server("git")` → без подтверждения (верхний список).
- `mcp_enable_tool_group("mcp:context7")` → без подтверждения.
- `mcp_list_servers()` / `mcp_list_tool_groups()` → не зависят от списка.

## Тесты

````sh
nvim --headless --noplugin -u NONE -c "set rtp+=." -c "luafile tests/test_automcp.lua" -c "qa!"
````
