# Отчёт этапа 0

Дата: 24.11.2026. Статус: **этап 0 завершён; этап 1 не начат и ожидает согласования владельца**.

## Результат

ТЗ прочитано полностью, исходный файл не изменялся. В каталоге изначально был только `CHATWOOT_CODEX_SPEC.md`, без Git и Chatwoot. Исследован официальный CE core v4.20.1, полный SHA b2f94636d325a126a67c6c4c808303d8aa8cbeea; проверены базовая лицензия, архитектура, права, REST, WebSocket, API inbox/webhooks, файлы и фоновые задачи. Карта доступа содержит границу между прочитанными точками и поверхностями, для которых впереди полный аудит.

Ключевые выводы:

- Модель CE даёт доступ по inbox/team и account, не по единому владельцу клиента. Потребуются свои роли, ownership, scopes/policies и audit без Enterprise.
- Помимо HTTP нужно изменить общий контактный WebSocket fanout, presence, queued recipients, уведомления и выдачу файлов. Signed URL не обеспечивает отзыв доступа при передаче.
- Штатный Telegram канал использует Bot API; Personal требует внешнего MTProto gateway. Поиск по любому номеру не гарантирован; нужны реальные разрешённые тесты.
- MAX Personal не подтверждён: проверенная официальная документация — боты; ограничения соглашения требуют разрешённого способа до live-PoC. Telemax существует, обновляется, имеет AGPL, но не принят как готовое решение. Полный MVP блокируется этим вопросом.
- Для доставки нужен durable source outbox в Chatwoot плюс ledger/reconcile в Django. Обычный API inbox webhook не закрывает потерю операции.

## Изменённые/добавленные файлы

Добавлены только материалы подготовки:

- `README.md`, `.gitignore`, `.env.example`.
- `scripts/bootstrap-chatwoot.sh` — загрузка исходников с проверкой тега/SHA, без установки/запуска.
- `integration/README.md`, `gateways/telegram/README.md`, `gateways/max/README.md`, `infra/README.md`, `tests/e2e/README.md` — границы будущих компонентов.
- `infra/upstream.lock.json` — зафиксированная официальная база.
- `docs/discovery.md`, `docs/architecture.md`, `docs/security.md`, `docs/operations.md`.
- `docs/implementation-plan.md`, `docs/max-poc.md`, `docs/risks.md`, `docs/upstream-changes.md`.
- `docs/decisions/0001-ce-and-stage-gates.md`.
- `docs/evidence/upstream.json` — метаданные и SHA256 47 файлов исследованного upstream; `docs/evidence/connectors.json` — пределы проверки кандидатов.
- `docs/stage-0-report.md` — этот отчёт.

Каталог `chatwoot/` зарезервирован и пуст: рабочий fork ещё не создан. Исходники для исследования и проверки bootstrap находятся только во временных каталогах вне проекта; для воспроизводимости они не нужны, скрипт получает исходники заново. Upstream код не менялся. Git корня не инициализирован, коммитов и публикаций нет.

## Фактически выполненные проверки

| Проверка / команда | Результат |
|---|---|
| Полное чтение ТЗ и исследование исходного каталога | Только ТЗ; AGENTS.md внутри исходного каталога отсутствует |
| GitHub releases/latest, commits/v4.20.1 и официальный source archive | Stable v4.20.1; полный SHA подтверждён |
| `bash -n scripts/bootstrap-chatwoot.sh` | PASS |
| `bash scripts/bootstrap-chatwoot.sh docs` | Ожидаемый отказ, exit 2: непустой каталог не изменён |
| `bash scripts/bootstrap-chatwoot.sh /private/tmp/chatwoot-bootstrap-stage0-verified` | PASS: fetch тега, сверка SHA, detached checkout |
| `git -C /private/tmp/chatwoot-bootstrap-stage0-verified rev-parse HEAD` | b2f94636d325a126a67c6c4c808303d8aa8cbeea |
| `git ... status --porcelain` | Пустой вывод: checkout чистый |
| Python stdlib: сравнение SHA256 из evidence с проверенным Git checkout | PASS: 47/47 файлов совпали с исследованным архивом |
| Python stdlib: локальные Markdown ссылки и trailing whitespace | PASS: 32 локальные Markdown ссылки, все JSON, отсутствие trailing whitespace |

Первый сетевой запрос в sandbox не смог разрешить DNS; метаданные/исходники успешно получены повторно с сетевым разрешением. Это не ошибка bootstrap. MAX/Telegram аккаунты не подключались; реальная отправка/приём, Rails/Vue/Django/E2E/security-тесты не выполнялись. Миграций нет. Docker и ShellCheck в доступном PATH не обнаружены, сборка и ShellCheck не выполнялись. Синтаксис Bash и реальный Git bootstrap проверены.

## Ограничения и следующий шаг

Нет подтверждённой runtime-изоляции, рабочего Compose, серверной реализации, коннекторов или результата MAX PoC. Лицензии транзитивных зависимостей и итоговых образов требуют отдельной проверки. Состояние Codeberg Telethon напрямую не проверено. Исследование не утверждает юридического соответствия.

Следующий разрешаемый шаг — [план этапа 1](implementation-plan.md): локальный чистый CE, A/B/R и воспроизведение прав, CE-only build, проверка предпосылок MAX. Live-PoC MAX выполняется только после подтверждения разрешённого способа. Начало этапа 1 и любые дальнейшие этапы — исключительно после согласования владельцем проекта.
