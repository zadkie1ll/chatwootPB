# Этап 0: исследование Chatwoot CE

Дата: 24.11.2026. Основное ТЗ: [CHATWOOT_CODEX_SPEC.md](../CHATWOOT_CODEX_SPEC.md), прочитано полностью. Статус: статическое исследование завершено; этап 1 не начат. В исходном каталоге был только файл ТЗ, Git-репозитория и исходников приложения не было.

## 1. База исследования и воспроизводимость

Выбран официальный стабильный [v4.20.1](https://github.com/chatwoot/chatwoot/releases/tag/v4.20.1), опубликованный 20.11.2026, не prerelease. Полный commit: `b2f94636d325a126a67c6c4c808303d8aa8cbeea`. Данные проверены через GitHub API releases/latest и commits/v4.20.1; архив официального репозитория распакован во временный каталог для чтения. Приложение, Docker, миграции и коннекторы не запускались. Это не аудит безопасности и не доказательство работающей интеграции.

[Зафиксированные метаданные и хеши прочитанных файлов](evidence/upstream.json). Все пути ниже относятся именно к этому commit. Постоянные ссылки: `https://github.com/chatwoot/chatwoot/blob/b2f94636d325a126a67c6c4c808303d8aa8cbeea/<path>`.

Подготовлен `scripts/bootstrap-chatwoot.sh`: получение официального тега в отдельный каталог, обязательная сверка полного SHA, detached checkout. В текущем проекте исходники пока не установлены. Bootstrap не запускает приложение и не реализует этап 1. Операционная процедура — [operations.md](operations.md).

## 2. Стек и граница CE

Подтверждено исходниками:

| Слой | Версия / механизм | Основание |
|---|---|---|
| Ruby | 3.4.13 | `.ruby-version`, `docker/Dockerfile` |
| Rails | 8.0.5.2 | `Gemfile.lock` |
| Node | 24.22.1 | `.nvmrc`, Dockerfile |
| pnpm | 10.2.0 | Dockerfile |
| UI | Vue 3, Vite, Vuex, Tailwind; русские локали присутствуют | `package.json`, `app/javascript/dashboard/` |
| Auth | Devise, devise_token_auth; API AccessToken | `Gemfile.lock`, `app/controllers/api/base_controller.rb` |
| Policies | Pundit 2.3.0 | `Gemfile.lock`, `app/policies/` |
| Фоновые задачи | ActiveJob / Sidekiq 7.3.10 | `Gemfile.lock`, `app/jobs/`, `config/sidekiq.yml` |
| Данные | PostgreSQL, ActiveRecord; upstream Compose использует pgvector:pg16 | `db/schema.rb`, `docker-compose.production.yaml` |
| Realtime | ActionCable с Redis, RoomChannel | `config/cable.yml`, `app/channels/room_channel.rb` |
| Файлы | ActiveStorage, local/object storage | `app/models/attachment.rb`, `config/storage.yml` |

[Корневая LICENSE](https://github.com/chatwoot/chatwoot/blob/b2f94636d325a126a67c6c4c808303d8aa8cbeea/LICENSE) разрешает MIT для открытой части с исключением `enterprise/` и самостоятельными лицензиями зависимостей. Нельзя считать весь официальный архив MIT. Закрытые реализации Enterprise не использовались для проектирования и не копировались. Собственные ownership, роли и аудит реализуем в CE самостоятельно.

`lib/chatwoot_app.rb` содержит штатный `DISABLE_ENTERPRISE`; задавать явно `true` и при сборке, и при запуске web/worker. Не задавать строку `false`: в этой реализации непустая строка truthy. В этапе 1 исключить `enterprise/` из build context без удаления LICENSE и без изменения проверок лицензии; проверить CE frontend/backend и отсутствие Enterprise в образе. `custom/` автоматически меняет список extensions, поэтому не использовать его как неподтвержденный способ отключения Enterprise. Имена функций из core не дают права использовать EE-компоненты.

Нужен отдельный лицензионный реестр фактически включённых Ruby/npm/Python/системных зависимостей и SBOM образа; он ещё не создан. Нельзя обещать лицензионную чистоту всей транзитивной цепочки на основании LICENSE Chatwoot. Версии PostgreSQL/Redis/proxy и digest образов выбираются в этапе 1: upstream `latest`, `redis:alpine`, `pg16` не являются достаточной фиксацией.

## 3. Доменная модель

Chatwoot уже содержит `Account`, `AccountUser`, `User`, `Contact`, `ContactInbox`, `Inbox`, `Conversation`, `Message`, `Attachment`. Contact принадлежит Account; ContactInbox связывает контакт и inbox с внешним `source_id`. В схеме уникальны `(inbox_id, source_id)` и `(account_id, display_id)` для Conversation. Внутренний `Conversation.id` и видимый/API `display_id` различаются. Нельзя смешивать их в mapping.

`Conversation.assignee_id` закрепляет отдельный диалог, не клиента со всеми каналами. Уникального владельца Contact, защищённого от гонок между каналами, штатная схема не обеспечивает. Номер телефона не имеет уникального ограничения, достаточного для такого закрепления. Штатные ContactInbox и Message.source_id полезны для mapping, но не заменяют ChannelIdentity и durable idempotency ledger. У Message.source_id обычный индекс, не гарантия уникальной доставки.

План: отдельные собственные ownership и role membership, ChannelIdentity, AssignmentAudit в БД Chatwoot; InboxEvent/OutboxEvent/DeliveryRecord в integration DB. Детали — [architecture.md](architecture.md). Это проектные модели, пока не существующие классы или миграции.

## 4. Фактические права CE

`AccountUser` имеет `agent: 0`, `administrator: 1`. Бизнес-роли ТЗ не совпадают с ними. Выдать руководителю штатного administrator означало бы также открыть управление каналами; техническому администратору — данные чатов. Требуется независимая бизнес-роль на уровне Account и пересмотр всех веток administrator, включая фоновые рассылки.

| Механизм | Наблюдение в выбранном CE | Значение для проекта |
|---|---|---|
| Account boundary | `EnsureCurrentAccountHelper` проверяет членство пользователя в account; token owner проходит свой путь | Сохраняем tenant boundary, дополняем ownership |
| ConversationPolicy.show? | administrator / AgentBot / член inbox **или** команды | Чужой чат доступен участникам общего канала; assignee не является границей |
| PermissionFilterService | administrator получает весь relation; agent фильтруется по inbox | «Мои» — пользовательский фильтр, его нельзя считать защитой |
| ContactPolicy | show/create/update/search/filter разрешены; export/import/destroy — administrator | Ограничений по владельцу клиента нет |
| ContactsController | выборки `Current.account.contacts`, получение по ID в account | Контакт другого менеджера нужно закрыть на уровне scope и объекта |
| SearchService | контакты ищутся по account; сообщения/диалоги главным образом по доступным inbox | Отдельно закрывать все типы поиска, GIN и fallback |
| MessagesController | вложенный BaseController авторизует conversation через show?; операции create/update/destroy/retry имеют свои ветки | Нужны права на конкретное действие и повторная проверка назначения при отправке |
| AssignmentsController | наследует проверку show?, вызывает AssignmentService | Передачу запретить менеджеру, не оставлять обход через штатный assignee |
| API tokens | `AccessTokenAuthHelper`: токен User или AgentBot; у AgentBot ограниченный список endpoints | Админский токен слишком широк, allowlist AgentBot не решает ownership |

Наблюдения подтверждены чтением кода, но не воспроизведены HTTP-тестом. Подробный реестр поверхностей и будущих проверок — [security.md](security.md). Нельзя заявлять «CE небезопасен»: его штатная модель доступа просто отличается от требуемой.

## 5. WebSocket, уведомления и передача

`RoomChannel.ensure_stream` подписывает User на личный pubsub_token и `account_<id>`. `broadcast_presence` добавляет доступные контакты account в presence.update. `ActionCableListener` рассылает contact.created/updated/merged/deleted в общий account-поток. Диалоги, сообщения, typing и ряд других событий идут участникам inbox плюс администраторам; mentions направляются упомянутому пользователю. Это самостоятельные каналы раскрытия данных независимо от HTTP.

`ActionCableBroadcastJob` получает уже сформированный список адресатов; для некоторых событий обновляет Conversation, но не вычисляет право текущего владельца перед каждым получателем. При передаче клиента недостаточно изменить assignee: в очереди могут оставаться события со старыми получателями и payload. Нужен пересчёт допуска непосредственно перед доставкой, version fence назначения, отзыв/обновление подписок и очистка клиентского состояния. На WebSocket невозможно отозвать уже доставленные байты; это ограничение фиксируем явно. Email/push/browser notifications и их queued payload также требуют повторной проверки.

## 6. API inbox, REST и webhooks

Подтверждены `Channel::Api`, его identifier, hmac_token, hmac_mandatory, webhook_url и отдельный webhook secret. Не путать HMAC идентификации контакта с подписью webhook.

В `config/routes.rb` присутствуют:

- Application API: `/api/v1/accounts/:account_id/contacts`, `/conversations`, вложенные `/conversations/:conversation_id/messages` и `/assignments`; поиск, фильтры, meta, attachments и другие действия.
- Client API: `/public/api/v1/inboxes/:inbox_id/contacts/:contact_id/conversations/...`; inbox_id — identifier API-канала, contact_id — source_id ContactInbox. Это контактный интерфейс, а не аутентификация сервисной учётной записи.

`Public::Api::V1::InboxesController` при mandatory HMAC проверяет identifier_hash; у verified ContactInbox история может охватывать другие диалоги того же Contact. Для корпоративной установки отключить этот неиспользуемый публичный путь на входе и проверить внутренние обходы. Сервисные записи вести через отдельный узкий интерфейс CE с own auth/scopes либо ограниченный Application API после реализации прав. Не выдавать Client API capability менеджерам.

`WebhookListener` публикует message_created/message_updated и события диалога. API inbox получает события независимо от account webhook subscriptions; account webhook имеет отдельные subscription и feature checks. `Webhooks::Trigger` подписывает точные bytes JSON: HMAC-SHA256 от `<timestamp>.<body>`, заголовки `X-Chatwoot-Timestamp`, `X-Chatwoot-Signature` (`sha256=...`), `X-Chatwoot-Delivery`. Получатель должен проверять подпись constant-time, TTL, replay и сохранять запрос в БД до 2xx. Delivery ID не заменяет логический ключ идемпотентности.

Не предполагать гарантированный retry API inbox webhook: `Webhooks::Trigger.execute` обрабатывает ошибки, специальный raise retryable предусмотрен для AgentBot с 429/500. Нужны собственный транзакционный outbox в Chatwoot и reconciliation, иначе сбой до получения webhook Django может потерять исходящую операцию. Django outbox сам по себе эту границу не закрывает.

У Message штатные статусы sent/delivered/read/failed; pending/unknown ТЗ отсутствуют в enum. Нужна собственная модель состояния доставки с отображением в UI, без ложного delivered/read. Chatwoot sent не считать подтверждением внешней отправки. Внутренние заметки, входящие и activity отфильтровывать явно, вне зависимости от `webhook_sendable?`.

## 7. Вложения

`Attachment.file_url` использует `url_for(file)`, download_url — `file.blob.url`, thumb_url — representation URL. Scoped список attachments не защищает уже выданный signed URL от повторного использования после передачи клиента. Нужен авторизованный proxy с проверкой account/ownership для каждого скачивания, Range, preview и avatar, приватное хранилище, запрет обхода через стандартные ActiveStorage routes/CDN. Кеш и долгие открытые HTTP-потоки требуют отдельного решения; ранее скачанные файлы не отзываются. Фактические сроки действия URL и поведение Range проверяем в этапе 2.

## 8. Telegram Personal

Штатный `app/models/channel/telegram.rb` хранит bot_token и использует `api.telegram.org/bot...`: это Bot API, не личный MTProto аккаунт. Нужен внешний gateway и API inbox.

[Telegram contacts API](https://core.telegram.org/api/contacts) документирует resolvePhone с ограничениями приватности и рекомендует не более одного обращения в 3 секунды. Ненайденный и скрытый пользователь могут давать одинаковую ошибку: поиск по любому номеру гарантировать нельзя. [API Terms](https://core.telegram.org/api/terms) требуют собственный api_id, соблюдение приватности и ограничивают использование данных для AI; перед будущим RAG нужна новая проверка условий.

Кандидаты: Telethon (MIT, Python, проще DRF-интеграция) и TDLib ([Boost Software License 1.0](https://github.com/tdlib/td/blob/master/LICENSE_1_0.txt), официальный C++ клиент, сложнее сборка и binding). Предварительно Telethon stable 1.x; окончательный dependency pin и проверка актуального upstream — этап 3. [Старый GitHub Telethon](https://github.com/LonamiWebs/Telethon) архивирован; документация stable сейчас 1.45.0, разработчик [объявил перенос на Codeberg](https://t.me/s/TelethonUpdates?before=1587). Codeberg напрямую через web-инструмент не получен, поэтому полнота maintenance/security проверки пока не подтверждена; архив старого зеркала не считать доказательством прекращения проекта.

[Sessions](https://docs.telethon.dev/en/stable/concepts/sessions.html) содержат ключ авторизации и кеш идентичностей: защищённый persistent volume, один процесс-владелец сессии, управляемый failover без параллельного клиента. [FloodWait](https://docs.telethon.dev/en/stable/concepts/errors.html) обрабатывать по задержке сервера. Нужны reconnect/reconciliation, отражение сообщений из официального клиента без эха, согласованная обработка edit/delete/reply и вложений. 2FA вводит администратор вне интерфейса менеджеров. Всё перечисленное пока проект, live-проверок не было.

## 9. MAX Personal: блокирующий результат discovery

[Официальная документация MAX](https://dev.max.ru/docs/chatbots/bots-coding/prepare/) описывает работу от имени бота. В проверенных материалах не обнаружен документированный разрешённый API личного аккаунта. Это результат ограниченного исследования, а не доказательство отсутствия любых договорных API.

[Соглашение MAX](https://legal.max.ru/ps), проверено 24.11.2026: пункты 4.3.7, 4.3.10 и 4.4 ограничивают автоматизированное взаимодействие, использование стороннего интерфейса и интеграции без специального разрешения/отдельного соглашения. Вывод для проекта: до подтверждения применимого разрешения live-PoC Personal не проводить. Владелец проекта должен получить подтверждение допустимого способа у платформы или договорного провайдера. Это технический gate, не заключение о юридическом соответствии.

[Trollobot/Telemax](https://github.com/Trollobot/Telemax) — существующий неофициальный мост Personal MAX → Telegram. На проверке репозиторий не архивирован; последний проверенный main commit `7f84e7e605ae05c46a9b359800aac296f2c67ab1` от 23.11.2026. LICENSE — AGPL-3.0, package.json уточняет AGPL-3.0-only. README, лицензия, метаданные и manifest просмотрены; протокол, безопасность реализации и воспроизводимость функций не валидированы. Свежее обновление не доказывает надёжность. Код не скопирован, зависимости и install.sh не запускались. Его перенос в продукт требует отдельного анализа обязательств AGPL, включая сетевое использование модификаций; выделение процесса само по себе не гарантирует отсутствия обязательств. Зеркалирование переписок в Telegram не соответствует нашей архитектуре и изоляции.

Решение: **MAX Personal — no-go до подтверждения разрешённого интерфейса; полный MVP заблокирован этим каналом**. После разрешения — обязательный PoC по [max-poc.md](max-poc.md). Альтернативы: официальный/договорной personal API с проверкой стоимости и SLA; либо явное изменение требований владельцем. Бот не принимается как эквивалент личного аккаунта. Telegram-only может быть согласован только как изменённый, неполный MVP.

## 10. Неизвестные и решения владельца

| Приоритет | Вопрос | До какого шага нужен ответ |
|---|---|---|
| Блокер MAX | Есть ли специальное разрешение и подходящий personal API, включая поиск номера и вложения? | До live-PoC и этапа 4; до крупных затрат этапа 2 — go/no-go |
| Gate этапов | Согласован ли план этапа 1? | До Compose, запуска CE, A/B/R и PoC |
| Security | Точный профиль технического администратора и временный audited доступ к данным | До финализации ролей этапа 2 |
| Модель | Что делать с группами, secret chats, edit/delete, историей до подключения и официальным клиентом? | До контракта этапа 3; по умолчанию планируем личные cloud-чаты 1:1, остальное не обещано |
| Доставка | Как отображать исходящие из официального клиента без менеджера, особенно у неназначенного клиента? | До этапа 3; нельзя назначать случайного владельца |
| Эксплуатация | ОС/архитектура хоста, домен, число менеджеров, нагрузка, размеры/типы файлов, RPO/RTO | До стенда/нагрузочной приёмки соответственно |
| ПДн | Размещение, сроки хранения/удаления, основания обработки, передача провайдерам | До реальных данных и production |
| Лицензии | Полный SBOM, AGPL применимость, версии Python/Django/DRF и коннекторов | До включения зависимостей/дистрибуции |

Список рисков и критерии закрытия — [risks.md](risks.md). План этапа 1 и дальнейших изменений — [implementation-plan.md](implementation-plan.md). Ничего из будущих функций не считается реализованным этим документом.
