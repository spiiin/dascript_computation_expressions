# Публичный API computation expressions

Проверенный SDK — Daslang v0.6.5-RC2 со стандартной daslib. SDK не включён в экспорт.
Result и Option теперь являются стандартными `Result<T;string>` / `Option<T>`.
Миграция и правила владения: [семантика builders](CE_SEMANTICS.md).
Необязательный `computation_task/task_hv` требует установленный `dashv/dashv_boost`.
API: `hv_websocket`, `ws_connect`, `ws_send_text`, `ws_receive_text`,
`HvWebSocketConfig`, `hv_websocket_stats`; контракт и пример: [семантика builders](CE_SEMANTICS.md).

Библиотека — два пакета: `computation` (ядро) и `computation_task` (Task-рантайм,
нужен только для задач). В приложении они лежат в `modules/`, см.
[подключение](INTEGRATION.md):

```das
options gen2
require computation/computation
```

Дополнительные подключения: `computation/validation_builder`,
`computation/deferred_computation`, `computation/coroutine_builder`, `computation/coroutine_scheduler`.
State, Writer, Reader и Query в библиотеку не входят: это примеры builders поверх
публичного протокола, см. [examples/builders](examples/builders/README.md).
Типизированные задачи: `computation_task/task_builder`, см. [семантика builders](CE_SEMANTICS.md).
Планировщик и таймауты: `computation_task/task_scheduler`, см. [семантика builders](CE_SEMANTICS.md).
Совместное ожидание: `computation_task/task_combinators`, операции task_when_all,
task_result_when_all, task_race и [and_bind для Task](CE_SEMANTICS.md); см. [семантика builders](CE_SEMANTICS.md).
Модуль подключается по имени пакета, без расширения. Тесты и примеры этого
репозитория подключают пакеты из `packages/` относительным путём с `.das`.

## Builders и результаты

| Builder | Результат |
|---|---|
| ResultBuilder / OptionBuilder | `Result<T;string>` (err/ok) / `Option<T>` (none/some) |
| MoveResultBuilder / MoveOptionBuilder | Те же варианты с передаваемым владением |
| ValidationBuilder | valid/invalid с накоплением ошибок в and_bind |
| ListBuilder(type<T>) | Владеющий array<T> |
| SequenceBuilder(type<T>) | Ленивый iterator, для move-only элементов — owning slot |
| CoroutineBuilder | Ленивый iterator<CoroutineFrame> |
| TaskBuilder(type<T>) | Однократная задача с результатом T, запуск через task_poll |
| TaskResultBuilder(type<T>) | Задача с Result<T>, Error пропускает продолжение |
| TaskResultBuilder(type<T>, type<E>) | То же с собственным типом ошибки: Task<Result<T;E>> |
| AsyncSequenceBuilder(type<T>) | Асинхронный stream; next возвращает Task<Option<T>> |

ListBuilder()/SequenceBuilder() выбирают int. Обычные Value CE выполняются
немедленно; Sequence/Coroutine — при обходе/возобновлении. Обычные
Result/Option используют копируемые данные. Для move-only нужны owning builders
или соответствующий List/Sequence. По умолчанию нет сетевого async или потоков.
Task поддерживает неблокирующее ожидание через callback-адаптер; сетевой транспорт
и потоки сам модуль не предоставляет. API: task_poll, task_status, task_value,
task_error, task_cancel, task_scope, task_from_poll, task_after_polls.
`task_from_async(source)` принимает стандартные [async]-итераторы с res/wait
или void-итераторы bool. `task_from_async(source, closeLambda)` также владеет
внешним cleanup. Источник перемещается, Task возвращает последний res после
полного завершения; void возвращает CeUnit. Ограничение native inscope в SDK
0.6.4 и безопасный пример владения описаны в [семантика builders](CE_SEMANTICS.md).

## Прикладные операции

`T`, `S`, `E` ниже — обозначения типов, а не буквальные объявления daScript.

| Операция | Назначение |
|---|---|
| `ok(value,type<string>)`, `err(message,type<T>)` | Стандартные конструкторы Result; совместимые обёртки `result_ok` / `result_error` сохранены |
| `some(value)`, `none(type<T>)` | Стандартные конструкторы Option из daslib/option |
| `move_ok(value[,type<E>])`, `move_some(value)` | Перемещение: одноаргументный move_ok — обёртка для Result<T,string>, остальные — стандартные функции |
| `ce_move_some(value)` | Стандартный Option с обходом AOT-перемещения tuple; см. STANDARD_TYPES.md |
| `move_error(message, type<T>)`, `move_none(type<T>)` | Неуспешные owning-результаты |
| `validation_ok(value)`, `validation_error(message,type<T>)`, `left |> validation_zip(right)` | Проверки и объединение независимых ошибок |
| `deferred(builder,data) $(snapshot) {...}`, `deferred(builder) {...}` | Владеющий снимок для повторных запусков |
| `run_deferred(task)` | Новый запуск; task передаётся изменяемым владельцем |
| `sequence_each(source, action)` | Защищённый обход и закрытие источника, включая исключение action |
| `sequence_each_move(source, action)` | Защищённый обход owning-элементов по ссылке |
| `sequence_next_move(source, value)` | Получить следующий элемент перемещением, возвращает bool |
| `sequence_close(source)` | Явное закрытие итератора |
| `next_frame()`, `wait_frames(count)` | События ожидания Coroutine, выдаются через yield |
| `coroutine_resume(task)`, `coroutine_cancel(task)` | Продолжить / закрыть сценарий |

Владельцы результата обычно принимаются через `var inscope result <- ...`.
Consuming bind записывается `var item & = source |> bind`, передача наружу —
`return <- item` / `yield <- item`. Нельзя сохранять заимствованную ссылку на
слот дольше его владельца. Снимки deferred не принимают произвольные указатели,
handles и stack blocks; каждый run клонирует рабочие данные.

## Scheduler

`CoroutineScheduler` и `CoroutineTaskId` предоставляют:

- `coroutine_spawn(scheduler, source)` — передать сценарий, получить ID;
- `coroutine_tick(scheduler)` — обновить активные задачи;
- `coroutine_status`, `coroutine_error`, `coroutine_valid` — запрос состояния ID;
- `coroutine_cancel(scheduler,id)` — отменить задачу;
- `coroutine_forget`, `coroutine_prune` — удалить завершённые записи;
- `coroutine_task_count`, `coroutine_slot_count` — число задач / слотов;
- `coroutine_close(scheduler)` — закрыть все задачи;
- `coroutine_scope($(var scheduler:CoroutineScheduler) {...})` — защищённая область scheduler.

## CE-маркеры и расширение

`source |> bind`, `left |> and_bind(right) |> bind`, `return value`,
`return source |> return_from`, `yield value`, `source |> yield_from`,
`resource |> use_resource`, `try_finally(body,cleanup)`, `try_with(body,handler)`
раскрываются макросом. Поддержка зависит от builder. and_bind вычисляет фабрики
достигнутой группы слева направо; у Task затем кооперативно опрашивает детей. Не запускает
потоки; Error/None не являются исключениями.

`identity_builder.das` и `main.das` в экспортированном примере показывают
минимальный CeValueProtocol с ce_bind/ce_unwrap/ce_return/ce_zero/ce_combine.
Новые правила определяются перегрузками ce_* рядом с builder, без регистрации.
Для and_bind нужна ce_merge_sources, для циклов — соответствующие операции
протокола. Внутренние курсоры, slots и устройство снимков не являются API.

## Task scheduler

Модуль task_scheduler.das: task_scheduler(type<T>, TaskSchedulerConfig()), task_spawn, task_tick(scheduler, now_ms), task_configure, task_scheduler_config, task_scheduler_time, task_valid, task_status/value/error(scheduler,id), task_count, task_active_count, task_slot_count, task_cancel(scheduler,id), task_forget, task_prune, task_scheduler_close, task_scheduler_scope. Полный контракт и пример: [семантика builders](CE_SEMANTICS.md).

Таймаут при регистрации: task_spawn(scheduler, source, TaskTimeout(after_ms=30)). task_timed_out(scheduler,id) отличает его от ручной отмены; deadline проверяется до poll независимо от его бюджета. См. [семантика builders](CE_SEMANTICS.md).

Общий токен: cancellation_token(), cancellation_clone(token), cancellation_requested(token), cancellation_cancel(token). task_with_cancellation(task,token) потребляет Task и сохраняет свой handle токена. Clone и := также разделяют состояние. Cancelled проходит через bind и комбинаторы без исключения. Контракт: [семантика builders](CE_SEMANTICS.md).

task_delay_ms(duration_ms) возвращает Task<CeUnit>, ожидающую now_ms текущего task_tick. Срок начинается при первом poll задержки; TaskResultBuilder также принимает Task<CeUnit> через bind. Модуль task_delay.das включён в task_scheduler.das. Контракт часов, отмена и пример: [семантика builders](CE_SEMANTICS.md).

task_when_all(tasks) потребляет массив Task с одинаковым копируемым T и возвращает владеющую задачу коллекции. Bind: var results & = task_when_all(make_jobs()) |> bind. task_value возвращает clone массива; прямая регистрация — task_scheduler(type<array<T>>). Поддержаны token, timeout и task_scope. Подробности: [семантика builders](CE_SEMANTICS.md).

## Функции-задачи: `[task]` и `[task_result]`

Функцию, тело которой целиком — одна задача, можно объявить с аннотацией.
Объявленный результат — тип значения задачи, а не сама задача:

```das
[task]
def load_level(id : int) : int {
    let chunk = read_chunk(id) |> bind
    return chunk * 2
}
```

Это та же функция, что и

```das
def load_level(id : int) : Task<int> {
    return <- computation(TaskBuilder(type<int>)) {
        let chunk = read_chunk(id) |> bind
        return chunk * 2
    }
}
```

| Аннотация | Builder | `def f(...) : T` возвращает |
| --- | --- | --- |
| `[task]` | `TaskBuilder(type<T>)` | `Task<T>` |
| `[task_result]` | `TaskResultBuilder(type<T>)` | `Task<Result<T;string>>` |
| `[task_result]`, результат `Result<T;E>` | `TaskResultBuilder(type<T>, type<E>)` | `Task<Result<T;E>>` |

Аннотации приходят вместе с `computation_task/task_builder`. Тип результата объявляется
явно; `void` и нативный `finally` не поддерживаются — для очистки есть
`try_finally(body, cleanup)`.

Тип ошибки задачи задаётся объявленным результатом `Result<T;E>`; E — любой
копируемый тип, обычно enum или структура:

```das
enum LoadError { NotFound; Denied }

[task_result]
def load(id : int) : Result<string;LoadError> {
    let record = lookup(id) |> bind        // Task<Result<Record;LoadError>>
    return record.name
}
```

Ошибка связанной задачи завершает и внешнюю, поэтому их типы ошибок должны
совпадать. Молча ошибка не преобразуется: bind задачи с другим типом ошибки
отклоняется при компиляции одним сообщением, в котором названы оба типа.
`task_map_error(task, @@convert)` из `computation_task/task_combinators` меняет тип
ошибки задачи — так в такой функции связываются источники библиотеки, которые
ошибаются строкой:

```das
def classify(message : string) : LoadError { ... }

let page = task_map_error(fetch(url), @@classify) |> bind
```

Задачи без собственного результата (`Task<CeUnit>`, например `task_delay_ms`)
связываются как обычно. `and_bind`, `deferred`, `task_result_when_all` (пара и
массив) и `task_result_race` сохраняют тип ошибки своих задач; задачи одной
группы должны ошибаться одним типом.

Задача живёт дольше вызова функции, поэтому аргументы она забирает себе.
Аргумент, объявленный `var`, перемещается в задачу и может быть некопируемым —
массив, массив задач; у вызывающего после вызова остаётся пустое значение.
Остальные аргументы копируются:

```das
[task]
def drain(var tasks : array<Task<int>>; limit : int) : int {
    var sum = 0
    for (index in range(length(tasks))) {
        let value = tasks[index] |> bind
        sum += value
    }
    return min(sum, limit)
}
```

Массив, таблица или итератор без `var` отклоняются сразу, с подсказкой
объявить аргумент `var`.

Для builders, которые выдают поток значений, есть такие же аннотации.
Объявленный результат у них — тип одного элемента; корутина значений не
выдаёт и результата не объявляет:

| Аннотация | Builder | `def f(...) : T` возвращает |
| --- | --- | --- |
| `[sequence]` | `SequenceBuilder(type<T>)` | `iterator<T>` |
| `[async_sequence]` | `AsyncSequenceBuilder(type<T>)` | `AsyncSequence<T>` |
| `[coroutine]` | `CoroutineBuilder()` | корутину; результат не объявляется |

```das
[sequence]
def evens(limit : int) : int {
    for (value in range(limit)) {
        if (value % 2 == 0) { yield value }
    }
}
```

`[sequence]` и `[coroutine]` приходят вместе с `computation/sequence_builder` и
`computation/coroutine_builder`, `[async_sequence]` — с
`computation_task/async_sequence_builder`. Аргументы `var` перемещаются так же, как у
`[task]`.

## Имена типов Task

Задачи и их handles — именованные кортежи, и у основных есть имена, чтобы
объявить глобальную переменную, поле или параметр без `typedecl(вызов())`:

| Имя | Что возвращает такое значение |
| --- | --- |
| `Task<T>` | `computation(TaskBuilder(type<T>))`; для TaskResultBuilder это `Task<Result<T;string>>` |
| `TaskEvent<T>` | Один шаг задачи |
| `TaskChannel<T>` | `task_channel(type<T>, capacity)` |
| `TaskProgress<T>` | `task_progress(type<T>)` |
| `TaskEventSource<T>` | `task_event_source(type<T>)` |
| `TaskJobQueue` | `task_job_queue()` |
| `TaskJobStream<T;Input>` | `task_jobque_stream(queue, type<T>, input, @@work)`; Input — тип входа worker |
| `AsyncSequence<T>` | `computation(AsyncSequenceBuilder(type<T>))`, функция `[async_sequence]` |
| `TaskShared<T>` | `task_share(task)` |
| `TaskScheduler<T>` | `task_scheduler(type<T>)` |
| `TaskRuntime` | `task_runtime()` |
| `TaskTicket<T>` | `task_spawn(runtime, task)` |

```das
var inbox : TaskChannel<string>
def total(var tasks : array<Task<int>>) : int { ... }

struct Game {
    runtime : TaskRuntime
    jobs : TaskScheduler<int>
}
def first_reading(var readings : AsyncSequence<int>) : Task<Option<int>> { ... }
```

Имя — тот же структурный тип, что и значение конструктора, поэтому старый код
с `typedecl(...)` остаётся совместимым. `TaskScheduler<T>` и
`TaskJobStream<T;Input>` объявляют переменную, поле или параметр с конкретными
типами; вывести `auto(T)` из аргумента через них нельзя.

## Полный Task API

`computation_task/async_sequence_builder`: AsyncSequenceBuilder, async_sequence_next,
async_sequence_close. Получение элементов через bind в TaskBuilder; завершение —
none, отмена/таймаут next закрывают stream. Владельцы: use_resource или inscope.
Копируемые и move-only элементы, один активный next. Для owning значений:
`yield <- value`, `var item & = async_sequence_next(stream) |> bind`; вне CE —
`task_take(nextTask)` для переноса, task_value для deep clone.
`child_stream() |> yield_from` передаёт элементы дочернего AsyncSequence во внешний;
дочерний stream переносится во владение делегирования, в том числе с move-only payload.
Контракт: [семантика builders](CE_SEMANTICS.md).
Внутри AsyncSequenceBuilder `for(value in child_stream())` автоматически ожидает
элементы и владеет источником до завершения/закрытия цикла. Переменная заимствует
элемент, включая move-only payload, на время итерации и вложенных bind.
`for(a,b,... in left(),right(),...)` обходит несколько AsyncSequence совместно
по кратчайшему источнику; partial-элементы и все источники освобождаются при остановке.
`left_task() |> and_bind(right_task()) |> bind` совместно ожидает Task через
ce_merge_sources/task_when_all. Для move-only пары нужен `var pair & = ... |> bind`.
Task Failed/Cancelled останавливает stream; Result.Error/Option.None в payload — данные.
Для `deferred(AsyncSequenceBuilder(type<T>),data)` каждый run_deferred создаёт
независимый stream и рабочий снимок, живущий до закрытия производителя;
поддержаны move-only элементы и вариант без явных данных.

[семантика builders](CE_SEMANTICS.md): return_from, Unit, break/continue,
move-only payload, deferred и shared-await. Task используют task_value для
копии/clone и task_take для передачи владения. Combinators: task_when_all и
task_result_when_all (пара и массив), task_race и task_result_race.
Реальная сеть — task_tcp_request_line из task_tcp.das, см. TASK_TCP.md.

## Ожидание событий

`computation_task/task_events`: task_event_source(type<T>), task_wait_event, task_event_emit,
task_event_close, task_event_subscriber_count, task_event_stats. Broadcast по активным
подпискам, копируемый T, Task<Result<T>>. Контракт: [семантика builders](CE_SEMANTICS.md).

## Parser и Search

Отдельные модули: `computation/parser_builder`, `computation/search_builder`.
Протокол и примеры: [семантика builders](CE_SEMANTICS.md).

- `ParserBuilder(text=...)`: `parser_literal`, `parser_int`, `parser_spaces`,
  `parser_eof`, `parser_choice`, `parser_call(@@grammar)`; результат parsed/failure.
- `SearchBuilder(type<T>)`: `search_choose` потребляет массив,
  `search_guard` отсекает ветвь, `search_once` / `search_cut` оставляют первое решение источника.

Новые builders работают с копируемыми значениями. Результаты Search нужно
закрывать через `sequence_each`, `sequence_close` или владеющую область.

Parser-комбинаторы: `parser_optional`, `parser_many`, `parser_many1`, `parser_sep_by`,
`parser_attempt`, `parser_commit` (операция без аргумента и обёртка).
Владеющие массивы связываются через `var items & = source |> bind`;
`return <- items` передаёт владение. Контракт: [семантика builders](CE_SEMANTICS.md).

Search-комбинаторы: `source |> search_take(n)` ограничивает число решений и закрывает источник до последней выдачи;
`left |> search_append(right)` последовательно объединяет альтернативы, владея обоими iterator.
Контракт и пример: [семантика builders](CE_SEMANTICS.md).

QueryBuilder и его операции — пример builder, см. [examples/builders](examples/builders/README.md).


Task concurrency: [семантика builders](CE_SEMANTICS.md).
Публичные модули: task_runtime, task_channel, task_parallel, task_jobque;
операции task_runtime, task_await, task_channel_send/receive, task_semaphore,
task_with_semaphore, task_when_all_limited, task_result_when_all_limited,
task_retry, task_first_success, task_job_queue, task_jobque, task_jobque_move,
task_jobque_collect.
Дополнительно: task_progress (task_progress_report/value/wait/wait_after/close),
task_http (task_http, task_http_get, task_http_post, task_http_header, task_http_ok;
нужен dasHV), task_channel_select, task_jobque_cancellable, task_jobque_stream,
task_jobque_next, task_jobque_stream_cancel, task_job_emit, task_job_cancelled,
cancellation_child, cancellation_view, cancellation_reason, cancellation_cancel(token,reason),
task_next_deadline, task_spawn_named, task_name, task_set_name, task_dump,
task_dump_text, task_stalled, TaskSchedulerConfig.max_tick_usec.
