# Computation expressions: Result и Option

Подключение к другому проекту и публичная поставка: [INTEGRATION.md](INTEGRATION.md). Надёжность и законы композиции: [RELIABILITY.md](RELIABILITY.md).

Таблица возможностей builders и общий контракт: [CE_SEMANTICS.md](CE_SEMANTICS.md).

Рабочий синхронный DSL на AST-макросах Daslang 0.6.5-RC2.
Использует стандартные Result и Option: [переход и совместимость](CE_SEMANTICS.md).
`computation` общий для builders; связывание записывается пайпом.
StateBuilder и WriterBuilder — примеры builders из
[examples/builders](examples/builders/README.md); их контракт описан в [семантика builders](CE_SEMANTICS.md).

```powershell
cd C:\src\dascript_computation_expressions
.\run_computation.ps1
.\run_computation.ps1 -Test
```

Можно задать `-Daslang <путь к daslang.exe>` или `DASLANG_EXE`.


## Result

```das
require computation/computation

let outcome = computation(ResultBuilder()) {
    let health = checked_number(100) |> bind
    let damage = checked_number(15) |> bind
    let remaining = health - damage
    return remaining
}
```

`checked_number` из демо возвращает `Result<int;string>`.
При `ok` извлекается значение и выполняется продолжение. При `error`
ошибка возвращается сразу; последующие выражения не вычисляются.
`return value` упаковывается в успешный Result.

Конструкторы:

```das
ok(42, type<string>)
err("not found", type<int>)
```

У ошибки указывается тип отсутствующего успешного значения, поскольку его
невозможно вывести из строки сообщения. Ошибка в этом примере всегда `string`.
Тип успешного результата всей цепочки может отличаться от типа промежуточного
значения: например, bind получает `int`, а финальный return возвращает `string`.

### Другой тип ошибки

`ResultBuilder()` работает с `Result<T;string>`. Для другого копируемого типа
ошибки передайте его builder:

```das
let loaded = computation(ResultBuilder(type<LoadError>)) {
    let id = find(1) |> bind      // find возвращает Result<int;LoadError>
    return id * 2                 // результат: Result<int;LoadError>
}
```

Тип ошибки нельзя вывести из `return value`, поэтому его несёт builder.
Источник с другим типом ошибки не преобразуется: такой bind отклоняется при
компиляции. Поддержаны те же конструкции, что у `ResultBuilder()`: циклы,
`and_bind`, `return_from` и ресурсы.

## Option

```das
let greeting = computation(OptionBuilder()) {
    let name = some("Alice") |> bind
    return "Hello, {name}"
}
```

Option представлен `Option<T>`. Значим тег `none`,
а его bool-поле — техническая заглушка. Создавайте отсутствие через
`none(type<T>)`. При отсутствии значения продолжение не вызывается.

```das
var executed = 0
let absent = computation(OptionBuilder()) {
    let number = none(type<int>) |> bind
    executed++
    return number + 1
}
// absent is none; executed == 0
```

## Возврат готового вычисления

Чтобы вернуть уже готовый Result/Option без дополнительной упаковки:

```das
let forwarded = computation(ResultBuilder()) {
    return err("forwarded", type<string>) |> return_from
}
```

`return_from` должен соответствовать выбранному builder. Простой `return`
намеренно упаковывает значение, в том числе если это другой контейнер.

## Что делает макрос

`AstCallMacro.canVisitArgument()` не даёт компилятору выводить тип исходного
блока до преобразования. Парсер представляет `expr |> bind` как вызов `bind`
с одним аргументом; макрос потребляет этот маркер, обычной runtime-функции
`bind` нет.

Для каждого связывания остаток блока становится продолжением:

```text
ce_bind(builder, первая_операция, значение =>
    ce_bind(builder, вторая_операция, другое_значение =>
        ce_return(builder, итог)))
```

Операции builder реализованы перегрузками `ce_bind`, `ce_return`,
`ce_return_from`, `ce_zero`, `ce_combine`, `ce_delay` по типу `ResultBuilder`/`OptionBuilder`. `ce_unwrap`
используется только внутри `typedecl`, чтобы вывести тип аргумента продолжения;
он не выполняет runtime-распаковку ошибочного значения. Реальное извлечение
делает `ce_bind` после проверки тега.

Builder вычисляется один раз во внешнем блоке; макрос создаёт локальную изменяемую копию контекста. Каждый достигнутый источник
bind вычисляется один раз. Продолжения — синхронные daScript blocks, не
сохраняемые heap-lambda. Обычные Value CE синхронны. Отложенный запуск даёт
отдельный `deferred`, а кадровые корутины и планировщик — модули
`coroutine_builder` и `coroutine_scheduler`. Добавлены cold TaskBuilder/TaskResultBuilder с неблокирующим poll-адаптером; см. [семантика builders](CE_SEMANTICS.md).
Проверка тега Result/Option нужна на каждом bind; макрос не убирает стоимость
проверки результата операции. Создание самих строк или значений может выделять
память независимо от механизма продолжений.

Исходная декларация переменной переносится в продолжение, поэтому сохраняются
её имя, явный тип и различие `let`/`var`. Смешивание Option с ResultBuilder и
несовместимая аннотация типа отклоняются обычным компилятором.

## Ветвления, циклы и bind без переменной

Полный запускаемый пример находится в `computation_control_demo.das`.

```das
var completed = 0
let outcome = computation(ResultBuilder()) {
    for (i in range(5)) {
        if (i % 2 == 0) {
            let value = validate(i) |> bind
            print("accepted {value}\n")
        } else {
            validate(i) |> bind
        }
        completed++
    }
    return completed
}
```

`validate` возвращает Result. Самостоятельный `source |> bind` проверяет
контейнер и отбрасывает успешное значение. В отличие от F# `do!`, здесь
разрешён любой копируемый payload, не только Unit. Пайп остаётся обязательной
формой записи в примерах; маркера `do!` в синтаксисе daScript нет.

При Error/None внутри ветки прекращается тело итерации, затем цикл и всё
продолжение после него. Для вложенных циклов ошибка распространяется наружу.
`while` заново вычисляет условие перед каждой достигнутой итерацией; после
ошибки оно больше не проверяется. Источники `for` вычисляются обычным циклом
daScript при входе в него; если предшествующий bind завершился ошибкой,
цикл вообще не запускается. Для Result сохраняется исходный текст ошибки.

В завершающем `if/elif/else` можно возвращать полезный результат:

```das
let description = computation(OptionBuilder()) {
    let n = some(4) |> bind
    if (n > 0) { return "positive" }
    else { return "nonpositive" }
}
```

Типы результатов веток должны совпадать. Ветка без `else` получает
неявный успешный Unit, поэтому вернуть `int` только из одной такой ветки
нельзя: это несовместимые типы.

### `match` внутри Task и Sequence

В `TaskBuilder`, `TaskResultBuilder` и `SequenceBuilder` ветки обычного
`daslib/match` поддерживают CE-операции. Например, после ожидания выполнение
продолжается внутри выбранной ветки, затем переходит к общему хвосту:

```das
require computation/computation
require computation_task/task_builder
require daslib/match

[task]
def after_vote(action : int) : int {
    var reward = 0
    match (action) {
        if (1 || 2) {
            let amount = task_after_polls(1, 4) |> bind
            reward += amount
        }
        if (_) { reward = 1 }
    }
    return reward
}
```

Поддержаны вложенные `match`, паттерны `$v(name)` и guards; связанные имена
могут затенять внешние CE-переменные. При возобновлении выбранной ветки её
паттерн и guard не проверяются повторно. `return` завершает Task, а
`break`/`continue` из ветки относятся к окружающему CE-циклу. Ресурсы ветки
освобождаются перед общим хвостом, а также при отмене и ошибке.

Макрос CE обрабатывает тела веток, оставляя выбор паттерна стандартному
`daslib/match`. Нужен самостоятельный statement `match(subject) { ... }`
(также допустим `match::match`). Поддержка не распространяется на RHS-выражения
`let x = match(...)`, `static_match`, `multi_match` или eager builders.
Регрессия: [test_task_match.das](tests/test_task_match.das).

## Zero, Combine, Delay

- `CeUnit` — пустая структура для результата без полезного значения.
- `ce_zero(ResultBuilder())` возвращает `Ok(CeUnit())`.
- `ce_zero(OptionBuilder())` возвращает `Some(CeUnit())`, **не None**.
- Пустой блок и блок без завершающего return заканчиваются `ce_zero`.
- `ce_combine(builder, first, next)` принимает Result/Option с Unit слева
  и продолжение справа. При сбое он возвращает Error/None, не вызывая `next`;
  тип полезного результата продолжения может быть любым поддержанным типом.
- `ce_delay(builder, body)` в этих синхронных builders вызывает блок ровно
  один раз. Сам блок передаётся без выполнения. `Combine` вызывает Delay
  для продолжения только после успеха первой части.

Это немедленно выполняемые computation expressions: значение computation —
готовый Result/Option. Delay здесь не создаёт хранимую задачу или ленивое
вычисление для последующего повторного запуска. Для этого есть отдельный
`deferred` ([семантика builders](CE_SEMANTICS.md)). Завершающий hook `ce_run` также
поддержан ([семантика builders](CE_SEMANTICS.md)); типизированные задачи описаны в [семантика builders](CE_SEMANTICS.md).

Макрос рекурсивно преобразует ветки и тела циклов. Ветки и циклы,
после которых есть код, объединяются с ним через Combine. Циклы остаются
нативными `ExprFor`/`ExprWhile`, без рекурсивного вызова на каждую итерацию.
Тело итерации выполняется через Delay. Аккумулятор цикла начинается с Zero,
`ce_loop_append` объединяет его с результатом итерации, затем `ce_loop_failed`
проверяет Error/None. При сбое результат выходит из обёртки цикла и
распространяется через Combine. Writer накапливает журнал, State переносит
состояние. Это стандартное раскрытие синхронных циклов. Builder может
переопределить For/While через общий протокол: [семантика builders](CE_SEMANTICS.md).
Одновременный обход нескольких источников описан в [семантика builders](CE_SEMANTICS.md).

## Поддерживаемый поднабор и границы

- Последовательные объявления по одной переменной, вызовы, assert, присваивания.
- `let x = source |> bind`, `var x = source |> bind`, `source |> bind`.
- `if/elif/else`, `for`, `while`, вложенные ветки и циклы.
- Пустые блоки и блоки без return: успешный Unit.
- Финальный `return value` и `return source |> return_from` в своей области.
- Вложенные computation expressions.
- `let resource = acquire() |> use_resource` и `try_finally(body, cleanup)`; см. [семантика builders](CE_SEMANTICS.md).

Result, Option и Validation раскрываются напрямую, без продолжений: bind
превращается в проверку и выход из блока области, а `if`, вложенные блоки и
циклы остаются нативными. Поэтому в них `return` внутри ветки или тела цикла
завершает всю computation: запись `if (...) { return 42 }; return 7`
допустима, а в циклах работают `break` и `continue`:

```das
let found = computation(OptionBuilder()) {
    for (item in items) {
        if (item.hidden) { continue }
        let price = lookup(item) |> bind      // none завершает всю computation
        if (price > limit) { return item.id } // ранний выход с результатом
    }
    return -1
}
```

Типы всех `return` области должны совпадать. Тело `try_finally`
и область после `use_resource` — отдельные области: `return` со значением из
них всю computation не завершает, и перед последующим кодом они должны
вычислять Unit. `break` и `continue` из них работают: цикл вокруг получает
команду, ресурс освобождается, cleanup выполняется.

У остальных Value-builders тело цикла и промежуточная ветка перед последующим
кодом должны вычислять Unit. Обычно для этого достаточно не писать return.
Неявное отбрасывание полезного результата промежуточной ветки запрещено
сигнатурой Combine, и `if (...) { return 42 }; return 7` там не поддержана:
выражайте выбор результата завершающим `if/else`.

`return` перед другими инструкциями своей области выдаёт диагностику макроса.

Pattern matching как отдельная конструкция CE и `yield` для Result/Option
не поддержаны. Вместо F# `use` и `and!` есть
`use_resource` и пайповый `and_bind`; для native finally используется
`try_finally`. Error остаётся значением, а не исключением языка.
Обычные ResultBuilder/OptionBuilder требуют копируемого payload; move-only
значения поддерживают отдельные MoveResultBuilder/MoveOptionBuilder
([семантика builders](CE_SEMANTICS.md)). TaskBuilder/TaskResultBuilder описаны в [семантика builders](CE_SEMANTICS.md); это поднабор идеи F# CE,
а не полная совместимость синтаксиса и семантики F#. Перечень стратегий —
[BUILDER_PROTOCOL.md](BUILDER_PROTOCOL.md).

## Проверки

`test_computation.das` для каждого builder проверяет успех и сбой на каждом
из трёх шагов. При сбое второго шага ожидается:

```text
Result fail_at=2: steps=1/1/0, return=0
Option fail_at=2: steps=1/1/0, return=0
```

Дополнительно проверяются исходный текст ошибки, переход `int -> string`,
вычисление builder и источников ровно один раз, мутация связанной `var`,
вложенные блоки, computation без bind и `return_from`.
`test_computation_no_return.das` теперь является положительной проверкой Zero.
`test_computation_control.das` проверяет оба builders: успех и сбой на каждой
позиции, пустые циклы, 10 000 итераций, вложенные циклы, выбранные ветки,
счётчики условий/источников/эффектов, остановку перед источниками следующих
циклов, bind без переменной и терминальные блоки с Unit.

Негативные проверки `mixed`, `annotation`, `return_position`, `loop_value`,
`combine_value`, `loop_mixed` ожидают ошибки компиляции: несовместимые
контейнеры и типы, return не на своём месте, не-Unit результат тела цикла или
первой части Combine. Runner проверяет код завершения и ожидаемую диагностику.

Файлы: `computation.das` — преобразование AST; `computation_builders.das` —
типы и перегрузки операций; `computation_demo.das` — запускаемые примеры.



Дополнительные примеры и тесты State/Writer: 
`state_demo.das`, `writer_demo.das`, `test_computation_effects.das`.


WriterResultBuilder объединяет журнал и остановку при Error; см. [семантика builders](CE_SEMANTICS.md).


StateResultBuilder объединяет состояние и Error с откатом всего workflow; см. [семантика builders](CE_SEMANTICS.md).


Using/TryFinally и проверки cleanup на всех builders: [семантика builders](CE_SEMANTICS.md).


ListBuilder использует другое значение Zero/Combine и собирает элементы из циклов; см. [семантика builders](CE_SEMANTICS.md). Массив результата передаётся через `<-`.


## Yield и SequenceBuilder

`yield value` и `source |> yield_from` теперь поддерживаются в ListBuilder.
Для ленивого обхода используйте SequenceBuilder: правила и ограничения
однопроходного итератора описаны в `SEQUENCE.md`.


## Короткая запись блока

У завершающего блока без параметров `$` можно опустить:
`computation(ResultBuilder()) { return 42 }`.
Примеры и тесты используют эту запись. В блоках внутри списка аргументов
(`try_finally($ { ... }, $ { ... })`) и блоках с параметрами
(`$(value : int) { ... }`) `$` остаётся обязательной частью выбранной записи.

## Panic

Panic фатален: библиотека его не перехватывает и не освобождает после него
ресурсы, а `try_with` удалён — его использование даёт ошибку компиляции.
Неудачу, которую должен обработать вызывающий, возвращайте значением (Error,
None, invalid). Подробности: [семантика builders](CE_SEMANTICS.md).


## Расширение CE отдельными модулями

`computation.das` теперь служит совместимым фасадом. Макрос находится в
`computation_macro.das`, дескрипторы и defaults — в `builder_protocol.das`,
общий runtime последовательностей — в `sequence_runtime.das`.
Новый builder выбирает стратегию через `ce_protocol` и определяет перегрузки
операций; менять фасад или макрос не нужно. Пример независимого расширения:
`require computation_macro` + `require reader_builder` из `examples/builders`.
Контракт, ограничения и игровой пример: [BUILDER_PROTOCOL.md](BUILDER_PROTOCOL.md),
`reader_demo.das`.

## Независимые источники

Добавлен общий `left |> and_bind(right) |> bind` для Result, Option,
Validation и List через `ce_merge_sources`. Примеры и правила:
[семантика builders](CE_SEMANTICS.md), `and_bind_demo.das`.

## Оптимизация bind → return

Соседняя завершающая пара использует необязательный `ce_bind_return`; без
перегрузки сохраняется обычный Bind/Return. Синтаксис не меняется.
Подробности и проверки: [семантика builders](CE_SEMANTICS.md), `bind_return_demo.das`.
