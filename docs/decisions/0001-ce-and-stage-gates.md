# ADR 0001: CE, ownership и gates

Дата: 24.11.2026. Статус: решения этапа 0; запуск этапа 1 ожидает согласования.

1. База — официальный Chatwoot v4.20.1, commit b2f94636d325a126a67c6c4c808303d8aa8cbeea. Собственные небольшие патчи CE, сохранение notices; Enterprise не использовать, лицензионные проверки не обходить.
2. Владелец клиента — собственная сущность в Chatwoot. Conversation.assignee — синхронизируемое представление, inbox/team membership не является основанием доступа. Бизнес-роли отделены от штатного administrator.
3. API inbox — транспорт для внешних personal gateways. Штатный Telegram Bot API не подходит. Сервисный auth и delivery ledger проектируются отдельно; публичный Client API не используется как manager/backend auth.
4. Требуется транзакционный outbox также в Chatwoot: webhook без durable source не закрывает потери. Exactly-once внешней отправки не обещать.
5. MAX Personal — no-go до разрешённого интерфейса и успешного PoC. Бот не заменяет personal. Использование Telemax не одобрено; AGPL и актуальность проверены только на уровне manifest/metadata/docs.
6. Этап 0 не включает Docker deployment, реальные аккаунты, миграции, UI и gateway. Следующий шаг — согласование конкретного плана этапа 1.

Основания: [discovery](../discovery.md), [риски](../risks.md), [план](../implementation-plan.md).
