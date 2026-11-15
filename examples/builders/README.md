# Примеры builders: State, Writer, Reader и Query

Эти builders не входят в библиотеку. Они написаны поверх публичного протокола
(`ce_bind`, `ce_unwrap`, `ce_return`, `ce_zero`, `ce_combine`, операции циклов и
`ce_merge_sources`) и показывают, как добавить собственный builder без правок
макроса. В языке с изменяемыми локальными переменными, генераторами и
`daslib/linq` они в основном повторяют родные средства, поэтому поставляются как
примеры, а не как API.

Подключение из корня репозитория:

```das
options gen2
require ./packages/computation/computation.das
require ./examples/builders/computation_effects.das
```

| Модуль | Builder | Результат |
|---|---|---|
| `computation_effects.das` | StateBuilder(initial) | `(value, state)` |
| `computation_effects.das` | WriterBuilder | `(value, log)` |
| `state_result_builder.das` | StateResultBuilder(initial) | `(result, state)`, откат state при Error |
| `writer_result_builder.das` | WriterResultBuilder | `(result, log)`, журнал сохраняется при Error |
| `state_writer_result_builder.das` | StateWriterResultBuilder(initial) | `(result, state, log)`, откат state и сохранение журнала при Error |
| `reader_builder.das` | ReaderBuilder(environment) | `(value)` |
| `reader_result_builder.das` | ReaderResultBuilder(environment) | Result |
| `query_builder.das` | QueryBuilder(type<T>) | Владеющий array<T> |

Все они работают с копируемыми значениями и ошибкой-строкой. StateResult
откатывает только поле state, не внешние эффекты и не объекты по указателям.

## Операции

`T`, `S` ниже — обозначения типов, а не буквальные объявления daslang.

| Операция | Назначение |
|---|---|
| `state_get()`, `state_put(state)` | Описания чтения / замены состояния, выполняемые через bind |
| `state_result(value, state)` | Готовый результат обычного State |
| `state_result_ok(value,state)`, `state_result_error(message,type<T>,state)`, `state_result_value(result,state)` | Готовые StateResult |
| `writer_value(value, log="")`, `tell(message)` | Значение с журналом / запись Unit в журнал |
| `writer_result_ok(value,log="")`, `writer_result_error(message,type<T>,log="")`, `writer_result(result,log="")` | Готовые WriterResult |
| `state_writer_result_ok(value,state,log="")`, `state_writer_result_error(message,type<T>,state,log="")`, `state_writer_result_value(result,state,log="")` | Готовые StateWriterResult |
| `reader_ask()`, `reader_value(value)` | Окружение / готовый результат Reader |

Изменить состояние функцией — это чтение и запись:

```das
let hero = state_get() |> bind
state_put(Hero(hp=hero.hp - 25, gold=hero.gold)) |> bind
```

## Query

`QueryBuilder(type<T>)`: `query_where`, `query_select`, `query_join`; стабильный
inner join и накопление массива, без подключения СУБД.

Операции над источником: `source |> query_order_by(key,descending=false)`,
`source |> query_group_by(key)`, `source |> query_distinct()` /
`query_distinct(key)`. Порядок стабильный, ключ вычисляется один раз на строку.
Группы владеют вложенными массивами; внутри CE: `var group & = ... |> bind`.

Для блока в конце: `source |> query_order_by(descending) <| key`. Блоки
`query_where`, `query_select`, `query_group_by` и `query_distinct(key)` передаются
через `source |> query_operation <| $(row:Row) {...}`.

## Где посмотреть

Демонстрации: [state_demo.das](../state_demo.das), [writer_demo.das](../writer_demo.das),
[reader_demo.das](../reader_demo.das), [reader_result_demo.das](../reader_result_demo.das),
[query_demo.das](../query_demo.das), [query_full_demo.das](../query_full_demo.das),
[query_operators_demo.das](../query_operators_demo.das). Тесты этих builders лежат в
`tests/` вместе с тестами библиотеки: на них проверяется протокол builders на
продолжениях.
