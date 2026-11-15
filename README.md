# Computation expressions for Daslang

F#-подобные computation expressions на AST-макросах Daslang: Result/Option,
State/Writer, List/Sequence, Task/AsyncSequence и Parser/Search/Query.
Типы операций проверяются при компиляции; ресурсы, отмена и move-only значения
поддерживаются протоколом builders.

```das
options gen2
require ./lib/computation.das

[export]
def main() {
    let result = computation(ResultBuilder()) {
        let value = result_ok(21) |> bind
        return value * 2
    }
    assert(result is ok && (result as ok) == 42)
}
```

## Начало работы

Нужны PowerShell 7 и Python 3. CI использует Windows x64 и закреплённый SDK
**0.6.5-RC2** с проверкой SHA-256. Для AOT нужны также CMake и Visual Studio 2022
с C++ tools. SDK в библиотеку не входит.

```powershell
git clone https://github.com/spiiin/dascript_computation_expressions.git
cd dascript_computation_expressions
$env:DASLANG_EXE = & ./.github/scripts/install-daslang.ps1 -Destination ./.work/sdk
./run_computation.ps1 -Test
```

Существующий SDK можно выбрать через `-Daslang`, `DASLANG_EXE` или `PATH`.
Скрипты находят исходники относительно своего каталога. В приложении используйте
`require ./lib/computation.das`; из вложенного каталога — `require ../lib/computation.das`.
Для поставки библиотеки и небольшого приложения: `./export_library.ps1 -Destination C:/my_project/ce`.

## Документация и примеры

- [Подключение и экспорт](INTEGRATION.md)
- [Синтаксис CE](COMPUTATION.md)
- [Builders, владение и семантика](CE_SEMANTICS.md)
- [Публичный API](PUBLIC_API.md)
- [Создание собственного builder](BUILDER_PROTOCOL.md)
- [Режимы выполнения и известные ограничения SDK](RELIABILITY.md)

| Задача | Запускаемый пример |
|---|---|
| Ошибки и отсутствующие значения | [Result/Option](examples/computation_demo.das) |
| Состояние, журнал и откат | [State/Writer/Result](examples/state_writer_result_demo.das) |
| Управление ресурсами | [use_resource и try_finally](examples/resources_demo.das) |
| Ленивые последовательности | [Sequence](examples/sequence_demo.das) |
| Асинхронные задачи, каналы и отмена | [Task toolkit](examples/task_toolkit_demo.das) |
| Асинхронные последовательности | [AsyncSequence](examples/async_sequence_demo.das) |
| Разбор текста | [Parser](examples/parser_demo.das) |
| Перебор решений | [Search](examples/search_demo.das) |
| Запросы к коллекциям | [Query](examples/query_full_demo.das) |
| Собственный builder | [Минимальное приложение](integration_example/main.das) |

## Проверки

```powershell
./tests/test_sdk_paths.ps1
./run_computation.ps1 -Test
./run_modes.ps1 -Mode Jit
./run_modes.ps1 -Mode AotGenerate
./run_aot.ps1
```

Основной runner выполняет 304 проверки файлов, диагностику, экспорт и проверки
раскрытия оптимизаций. Набор `mode_tests.json` содержит 75 тестов и примеров;
строгий AOT-хост исполняет 67 из них. Генерация C++ отдельно не означает успех AOT runtime.
Тесты TCP/HTTP/WebSocket используют локальные серверы; GLFW-тест создаёт скрытое окно.

[GitHub Actions](https://github.com/spiiin/dascript_computation_expressions/actions)
проверяет интерпретатор, JIT/AOT, AOT runtime и интеграции отдельными заданиями.
Логи сохраняются как CI artifacts; локальные результаты игнорируются Git.

`lib/` содержит 40 публичных модулей; `tests/` — регрессию и отдельные известные
repro SDK; `examples/` — примеры; `support/` — их builders и тестовые серверы.
`benchmarks/` содержит исходники нагрузок, используемые также функциональными
проверками; `aot_host/` — строгий C++ host; `integration_example/` — шаблон экспорта.
Исторические логи, замеры и дампы доступны в Git-истории, а не в рабочем дереве.

История выделена из [dascript_macro_fsharp](https://github.com/spiiin/dascript_macro_fsharp),
который подключает эту библиотеку как submodule.
