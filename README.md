# codecompanion-mcp-manager.nvim

Расширение для [codecompanion.nvim](https://github.com/olimorris/codecompanion.nvim),
регистрирующее тул-группу `auto_tools`. Входящие в неё тулы позволяют LLM
самостоятельно управлять возможностями чата: посмотреть, что доступно, включить
и выключить — как тул-группы, так и отдельные тулы.

## Возможности

| Тул | Назначение |
| --- | --- |
| `list_tools` | Список всех доступных возможностей — тул-групп и отдельных тулов — со статусом `attached` |
| `enable_tool` | Включает группу или отдельный тул в текущем чате |
| `disable_tool` | Выключает тул-группу. Отдельные тулы выключить нельзя (см. ниже) |

Модели всё равно, группа это или отдельный тул: она вызывает один и тот же тул
по имени, а тип (`group` или `tool`) и описание читает из `list_tools`.

Подробнее о том, как LLM должен работать с этими тулами, — в
[`mcp-tool-group-management.md`](./mcp-tool-group-management.md) (skill для LLM).

## Установка

Добавьте репозиторий в зависимости и включите расширение в `setup`.
Все опции расширения передаются **внутри вложенной таблицы `opts`** — именно её
CodeCompanion передаёт в `setup()` расширения:

````lua
{
  "olimorris/codecompanion.nvim",
  dependencies = {
    "lenow55/codecompanion-mcp-manager",
  },
  opts = {
    extensions = {
      automcp = {
        opts = {
          collapse_tools = true,
          individual_tools = { "subagents_*" },
          deny_groups = { "secrets*" },
          no_approval_for = { "git", "context7" },
          tool_opts = {
            enable_tool = { require_approval_before = true },
          },
        },
      },
    },
  },
}
````

> **Важно:** опции без обёртки `opts` (например,
> `extensions = { automcp = { collapse_tools = true } }`) молча не применятся —
> `setup()` расширения получит пустую таблицу и будут использованы значения
> по умолчанию.

## Параметры

| Параметр | Тип | По умолчанию | Описание |
| --- | --- | --- | --- |
| `collapse_tools` | `boolean` | `true` | Свернуть все тулы в одну группу `auto_tools` в буфере чата: вместо отдельных строк контекста на каждый тул рисуется одна строка `<group>auto_tools</group>`. При `false` каждый тул получает свою строку контекста |
| `individual_tools` | `string[]` | `{}` | Glob-паттерны отдельных тулов, которые LLM может включать **по одному**. Тул, не попавший под эти паттерны, поодиночке не подключается и не показывается в `list_tools`. Поддерживается `*`, например `subagents_*` |
| `deny_groups` | `string[]` | `{}` | Glob-паттерны тул-групп, которые LLM **не видит и не может** включить/выключить — ни одной из функций. Поддерживается `*`, например `secrets*` |
| `no_approval_for` | `string[]` | `{}` | Glob-паттерны имён тул-групп **и** отдельных тулов, которые LLM может включать/выключать **без подтверждения**. Применяется ко всем name-based тулам (`enable_tool`, `disable_tool`) |
| `tool_opts` | `table<string, ToolOpts>` | `{}` | Настройки отдельных тулов. Ключ — имя тула (`list_tools`, `enable_tool`, `disable_tool`) |

### `ToolOpts`

| Параметр | Тип | Описание |
| --- | --- | --- |
| `require_approval_before` | `boolean \| fun(tool, tools): boolean` | Запрашивать подтверждение пользователя перед запуском тула. По умолчанию не задано — подтверждение не требуется. Может быть функцией, чтобы решать динамически |
| `no_approval_for` | `string[]` | Glob-паттерны имён, обходящие подтверждение **только для этого тула**. Мержится поверх верхнего `no_approval_for` |
| `visible` | `boolean` | Показывать тул в `@`-меню автокомплита (solo-аттач). По умолчанию `false` — тул доступен только через группу `auto_tools` |

## Единое пространство имён

`enable_tool` / `disable_tool` принимают одно имя, которое резолвится в таком порядке:

1. **deny**: имя попадает под `deny_groups` → отказ «not available» (текст неотличим от несуществующего имени — защита от угадывания).
2. **группа**: точное совпадение с ключом в `tools.groups` → тип `group`.
3. **отдельный тул**: ключ в `tools`, который попадает под `individual_tools` → тип `tool`.
4. Иначе → «not available».

Если имя совпадает и с группой, и с тулом, выигрывает **группа** (детерминированно).

### Включение

- `enable_tool("agent")` → `tool_registry:add_group("agent")`.
- `enable_tool("subagents_research")` → `tool_registry:add_single_tool(...)`.

Тулы становятся доступны LLM на следующем ходу.

### Выключение

- Группа → `tool_registry:remove_group(name)`.
- **Отдельный тул выключить нельзя.** CodeCompanion не умеет снимать с чата
  единичный тул, и расширение намеренно не патчит ядро. При попытке выключить
  отдельный тул LLM получает `success` с пояснением «cannot be disabled and stays
  enabled», пользователь — предупреждение, а тул **остаётся включённым**.

## Подтверждение и `no_approval_for`

По умолчанию тулы следуют правилу `require_approval_before`, заданному для
каждого тула. Параметр `no_approval_for` позволяет разрешить LLM включать и
выключать **конкретные** имена без запроса подтверждения, в то время как все
остальные имена продолжают следовать `require_approval_before`. Паттерны — glob
(`*`), имя матчится целиком.

Список задаётся на двух уровнях:

- **Верхний** (`opts.no_approval_for`) — применяется ко всем name-based тулам:
  `enable_tool`, `disable_tool`.
- **На тул** (`opts.tool_opts[<tool>].no_approval_for`) — тот же список,
  но scoped на один тул. Мержится **поверх** верхнего, так что имя,
  указанное в любом из них, обходит подтверждение для этого тула.

Для имени из белого списка approval short-circuit-ит и тул запускается сразу.
Для любого другого имени (или когда `name` отсутствует) действует обычное
правило `require_approval_before` этого тула.

> **Примечание:** `list_tools` не принимает аргумент `name`, поэтому
> `no_approval_for` на него никак не влияет — его подтверждение регулируется
> только `require_approval_before`.

## Пример

````lua
require("codecompanion").setup({
  extensions = {
    automcp = {
      opts = {
        -- Отдельные тулы, которые можно включать по одному (глобы)
        individual_tools = { "subagents_*", "memory" },
        -- Эти группы скрыты и заблокированы во всех операциях
        deny_groups = { "secrets*", "admin" },
        -- LLM может включать/выключать эти имена без подтверждения (глобы)
        no_approval_for = { "git", "context7", "subagents_*" },
        tool_opts = {
          list_tools = {
            require_approval_before = false, -- листинг всегда свободен
          },
          enable_tool = {
            require_approval_before = true, -- но спрашивать перед любым другим именем
            no_approval_for = { "safe-group" }, -- per-tool добавление в белый список
          },
          disable_tool = {
            require_approval_before = false,
          },
        },
      },
    },
  },
})
````

С конфигурацией выше:

- `enable_tool("git")` → запускается без подтверждения.
- `enable_tool("safe-group")` → без подтверждения (per-tool).
- `enable_tool("subagents_research")` → без подтверждения (glob в верхнем списке) и разрешён (glob в `individual_tools`).
- `enable_tool("random-group")` → запрашивает подтверждение (базовое правило).
- `disable_tool("context7")` → без подтверждения (верхний список).
- `enable_tool("admin")` / `disable_tool("admin")` → «not available» (deny).
- `list_tools()` → не зависит от списка.

## Как это работает

При загрузке расширение регистрирует тулы в `interactions.chat.tools` конфига
CodeCompanion (под ключами, совпадающими с их schema-именами: `list_tools`
и т.д.) и создаёт тул-группу `auto_tools`. Аттач/детач выполняется через
`chat.tool_registry:add_group()` / `remove_group()` / `add_single_tool()`, поэтому
поведение идентично подключению вручную (включая `system_prompt` и опции группы,
такие как `ignore_system_prompt`).

Тулы регистрируются с `visible = false`: они не показываются в `@`-меню
автокомплита, чтобы пользователю предлагалась группа `auto_tools` целиком, а не
тулы по одному. На исполнение это не влияет — внутри группы они работают как
обычно. Если нужен solo-аттач отдельного тула, включите `visible` в его
`tool_opts`:

````lua
require("codecompanion").setup({
  extensions = {
    automcp = {
      opts = {
        tool_opts = {
          list_tools = {
            visible = true, -- тул появится в `@`-меню
          },
        },
      },
    },
  },
})
````

## Тесты

````sh
nvim --headless --noplugin -u NONE -c "set rtp+=." -c "luafile tests/test_automcp.lua" -c "qa!"
````
