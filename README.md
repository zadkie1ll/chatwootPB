# Корпоративный мультимессенджер на Chatwoot CE

Основное ТЗ: [CHATWOOT_CODEX_SPEC.md](CHATWOOT_CODEX_SPEC.md). Рабочая версия поддерживает личный Telegram, распределение переписок между менеджерами, редактирование сообщений, получение медиа, сводку OpenAI и интеграцию с Битрикс24. Диалоги создаются кнопкой «+»; Enter отправляет сообщение, Shift+Enter добавляет строку. Используется Chatwoot Community Edition; Enterprise-компоненты исключены. Подключение MAX — следующий этап.

Приложение: [mess.prav-buro.ru](https://mess.prav-buro.ru/app/login). Актуальное состояние: [docs/current-status.md](docs/current-status.md). [Подключение Telegram и работа менеджеров](docs/user-guide.md), [эксплуатация](docs/operations.md), [настройка сервера](docs/server-setup.md).

Менеджер видит закреплённых клиентов; руководитель — все переписки; технический администратор управляет подключением без доступа к содержимому. Изоляция применяется к HTTP, WebSocket и выдаче файлов. Telegram Personal работает через собственный MTProto gateway. Решения: [ADR 0003](docs/decisions/0003-telegram-first.md), [ADR 0004](docs/decisions/0004-bitrix-and-shared-intake.md).

Инструкция: [Telegram и Битрикс24 — сотрудники, сделки, общая очередь](docs/bitrix24.md). Решения по новой видимости и CRM: [ADR 0004](docs/decisions/0004-bitrix-and-shared-intake.md).

## Документация

- [Discovery: код CE, лицензии, API, WebSocket и коннекторы](docs/discovery.md).
- [Архитектура и модель владения/доставки](docs/architecture.md).
- [Изоляция и карта поверхностей доступа](docs/security.md).
- [План изменений и конкретные шаги этапа 1](docs/implementation-plan.md).
- [MAX PoC: gate, процедуры и фактический статус](docs/max-poc.md).
- [Риски и критерии их закрытия](docs/risks.md).
- [Bootstrap и план эксплуатации](docs/operations.md).
- [Архитектурные решения](docs/decisions/0001-ce-and-stage-gates.md).
- [Отчёт этапа 0](docs/stage-0-report.md), [журнал патчей upstream](docs/upstream-changes.md).

## Структура

```text
CHATWOOT_CODEX_SPEC.md        основное ТЗ, сохранено без изменений
chatwoot/                    исходники CE v4.20.1 с корпоративными изменениями
integration/                 Django/DRF integration и delivery worker
gateways/telegram/           MTProto gateway и локальный mock
gateways/max/                только после разрешённого PoC
infra/                       pinned images, CE image recipe, proxy и DB init
scripts/                     bootstrap, генерация секретов, Compose и проверки
docs/                        исследование, решения, планы и evidence
tests/baseline/               исходные права CE: HTTP, socket, файлы
tests/e2e/                    браузерные проверки изоляции A/B/R
.env.example                 предварительный CE-only шаблон без секретов
```

Исходники закреплены на `v4.20.1`, commit `b2f94636d325a126a67c6c4c808303d8aa8cbeea`, с собственными изменениями. Результаты локальных проверок и ограничения описаны в [отчёте этапа 1](docs/stage-1-report.md) и [текущем статусе](docs/current-status.md). Клиентские данные, секреты и рабочая Telegram session не входят в исходники.


## Репозиторий

[GitHub: zadkie1ll/chatwootPB](https://github.com/zadkie1ll/chatwootPB) содержит обычные файлы CE в `chatwoot/`, а не submodule. Исходная MIT-лицензия и атрибуция сохранены; версия upstream указана в `SOURCE-ORIGIN.json` экспортированной копии. История локального upstream checkout не публикуется.

После клонирования не запускайте `bootstrap-chatwoot.sh` поверх `chatwoot/`: корпоративные исходники уже включены. Для установки используйте инструкции сервера; секреты создаются на месте и не хранятся в Git. Публичная копия не содержит содержимое `docs/evidence/`, эксплуатационные отчёты и снимки экрана. Ссылки на такие свидетельства в исторических документах относятся к приватной рабочей копии. Для повторного экспорта из рабочей папки: `python3 scripts/export-github.py --destination /путь/к/пустой/папке`.
