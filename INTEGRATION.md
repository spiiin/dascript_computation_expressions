# Подключение CE к другому проекту

Проверяемая версия — Daslang v0.6.5-RC2 со стандартной daslib (включая AST-макросы); SDK в экспорт не входит.

Библиотека состоит из двух пакетов в `packages/`:

| Пакет | Что в нём | Зависит от |
|---|---|---|
| `computation` | Макрос `computation`, Result/Option, Validation, List, Sequence, Coroutine, Parser, Search, deferred | только daslib |
| `computation_task` | Task-рантайм: задачи, AsyncSequence, scheduler, каналы, jobque, события, сеть | `computation` |

Примеры, тесты, бенчмарки и демонстрационные builders отделены в examples/,
tests/, benchmarks/ и support/. State, Writer, Reader и Query — примеры builders
в examples/builders, в пакеты они не входят.

## Установка

Пакет — это папка с модулями, описателем `.das_module` и манифестом
`.das_package`. Положите нужные пакеты рядом в `modules/` своего проекта:

```
my_project/
  main.das
  modules/
    computation/
    computation_task/      # только если нужны задачи
```

Это можно сделать копированием папок из `packages/`, либо exporter:

```powershell
./export_library.ps1 -Destination C:/my_project/ce_example
./export_library.ps1 -Destination C:/my_project/ce_core -Packages computation
daslang.exe C:/my_project/ce_example/main.das -no-module-cache
```

Destination должен быть новым каталогом. Поставка содержит `modules/` с
выбранными пакетами, manifest.json с SHA256, main.das, identity_builder.das,
README.md, шесть справочников API/синтаксиса/семантики/протокола/подключения/
ограничений и шаблон aot_host. Exporter сверяет `.das_module` каждого пакета с
составом его папки и проверяет, что локальные requires не выходят за поставку.

Через daspkg репозиторий ставится целиком, одним пакетом
`computation_expressions`: его корневой `.das_module` регистрирует оба префикса.

```das
options gen2
require computation/computation
[export]
def main() {
    let result=computation(ResultBuilder()) {
        let n=ok(20, type<string>) |> bind
        return n+22
    }
    assert(result as ok==42)
}
```

`require computation/<модуль>` и `require computation_task/<модуль>` находят
модули по `.das_module` пакетов в `modules/` корня проекта. Корень проекта —
каталог запускаемого скрипта; для скрипта во вложенной папке его задаёт
`daslang.exe -project_root <корень>`. Пакет `computation_task` подключает
`computation` относительным путём `../computation/`, поэтому папки пакетов
должны лежать рядом и называться именно так. Дополнительные подключения и
список прикладных операций приведены в PUBLIC_API.md, включаемом в поставку.

## Минимальный собственный builder

identity_builder.das из шаблона определяет CeValueProtocol, Bind, Unwrap,
Return, Zero и Combine для tuple (value=T). Общие Delay и Run берутся из протокола.
В main.das он используется так:

```das
let custom=computation(IdentityBuilder()) {
    let n=(value=21) |> bind
    return n*2
}
assert(custom.value==42)
```

Менять computation.das и регистрировать builder не нужно. Для and_bind
добавляется ce_merge_sources; для циклов — операции соответствующего протокола.
Служебные курсоры и устройство снимков не являются прикладным API.

test_integration.ps1 проверяет новый экспорт вне исходного дерева: минимальный
builder, поставку одного пакета `computation` без Task-рантайма и smoke с Parser,
Search, Validation, MoveResult, Task и повторными deferred List. Тест не
использует support или тестовые builders.

## Task-рантайм

Полный Task-контракт: [семантика builders](CE_SEMANTICS.md).
Асинхронные последовательности: `require computation_task/async_sequence_builder`,
контракт и пример — [семантика builders](CE_SEMANTICS.md).
Сеть подключается отдельным `require computation_task/task_tcp`, см. TASK_TCP.md.
Для WebSocket: `require computation_task/task_hv`, см. [семантика builders](CE_SEMANTICS.md).
Этот необязательный модуль требует dasHV (`dashv/dashv_boost`) из SDK.
Остальные модули можно использовать без dasHV.
AOT host template находится в aot_host/; runner run_aot.ps1 и тестовый manifest
доступны в исходном репозитории, см. README.md исходного репозитория.

Ожидание событий без нативных зависимостей: `require computation_task/task_events`.
API и владение: [семантика builders](CE_SEMANTICS.md).
