# План реализации и согласования

Этап 0 выполнен. Этап 1 согласован владельцем 24.11.2026 и находится в работе: конфигурация подготовлена, Colima/Docker установлены, выполняется запуск. Фактический статус — [отчёт этапа 1](stage-1-report.md). Переход к этапу 2 требует отдельного отчёта и согласования.

## Этап 1: чистый CE и решение MAX

| Шаг | Изменяемые артефакты | Проверка / результат |
|---|---|---|
| 1.1 Bootstrap | chatwoot checkout/fork, lock, журнал upstream | Тег/SHA совпадают, clean base, сохранены LICENSE, определено хранение патчей |
| 1.2 CE build | infra build context, CE Docker recipe, pinned digests | EE не загружается; web/worker/frontend работают без платных компонентов |
| 1.3 Локальный стенд | compose.yaml, .env.example, README/operations | Чистая установка и миграции, healthchecks, закрытые БД/Redis, persistent volumes, перезапуск |
| 1.4 A/B/R baseline | синтетические fixtures и reproduction report | Общий API inbox; подтвердить фактические HTTP/search/socket/file права CE; обозначить исходные нарушения ТЗ |
| 1.5 MAX prerequisite | max-poc.md, решение владельца | Установить разрешённый personal interface и условия; при отсутствии — no-go без live-взаимодействия |
| 1.6 MAX live-PoC при снятом gate | изолированный PoC + обезличенный журнал | M01–M12 с реальными тестовыми аккаунтами; без production и реальных клиентов |
| 1.7 Отчёт | stage-1-report, ADR go/no-go | Изменённые файлы, команды и фактические тесты; согласование этапа 2 |

Владелец согласовал Telegram-first и отложил MAX (ADR 0003). Поэтому MAX no-go больше не блокирует ownership и Telegram backend/gateway. Исходный двухканальный MVP не объявляется готовым; реализация и приёмка текущей версии относятся к Telegram.

## Карта будущих изменений

| Этап | Изменения | Основные файлы/слои | Приёмка |
|---|---|---|---|
| 2a | BusinessRoleMembership, CustomerOwnership, ChannelIdentity, AssignmentAudit | собственные app/models/services, сгенерированные Rails migrations, constraints | Tenant/owner invariants, concurrent create/claim, transfer audit |
| 2b | Общий scope и action policies | app/policies, PermissionFilterService, ConversationFinder, SearchService, contacts/conversations controllers и подресурсы | Полная матрица security.md; другие account, прямые IDs и все HTTP методы |
| 2c | Закрыть альтернативные поверхности | bulk, reports/exports, automation/macros, notifications/jobs, mentions, public/platform/widget API | Нельзя обойти ownership через стандартный механизм; неиспользуемые пути deny |
| 2d | Realtime и вложения | RoomChannel, ActionCableListener/BroadcastJob, Attachment presenters, private download controller, ActiveStorage routing | Старый owner не получает новые события/файлы, queued events/Range/preview/reconnect |
| 2e | Русский UI | dashboard routes/store/API clients/components, i18n | Мои клиенты/диалоги, очередь R, transfer; очистка store после revocation |
| 3 | CW transactional outbox, scoped service ingest/send, Django ledger/workers, adapter v1, MTProto gateway | chatwoot app/jobs/services, integration/, gateways/telegram/, infra/ | Дубли/restarts/replay/unknown/no echo, version fence и transfer/send race |
| 4 | MAX gateway | gateways/max/, compose/secret management | Только после успешного PoC, оба personal-канала с согласованными вложениями |
| 5 | E2E, security/load review, backup restore | tests/e2e/, CI, infra/runbooks | A/B/R, нагрузка по согласованным целям, restore, тестовый пилот |
| 6 | Production gate | согласованные инфраструктура/условия платформ/ПДн | Отдельное решение владельца, проверенные ограничения и rollback |

Не переписывать Chatwoot целиком. Собственная логика — отдельные сервисы и небольшие вызовы из upstream точек. Изменения core фиксировать в [upstream-changes.md](upstream-changes.md), тестировать при каждом обновлении. Нельзя реализовать всё одним UI патчем или одним ConversationPolicy.show?.

## План тестов по слоям

Rails: policy/request/channel/job specs; DB uniqueness, account consistency, optimistic version, реальная конкурентная транзакция, допустимые роли. Vue: роль/очистка store/состояние доставки. Django: durable ACK, inbox/outbox uniqueness, HMAC exact bytes, TTL/replay, bounded retry, unknown reconciliation. Gateway: mock protocol failures и реальный smoke на разрешённых тестовых аккаунтах. Playwright: A/B/R/T и второй account; проверки тела ответа и socket, прямые file URLs.

CI без живых мессенджеров. Успех mock-тестов не означает успех Personal-коннектора. Миграции генерировать штатным Rails generator, отдельно проверять backfill/locks/deletion semantics. Фактический перечень тестов и результатов публиковать в отчёте каждого этапа.
