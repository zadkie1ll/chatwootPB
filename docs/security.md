# Изоляция и карта поверхностей доступа

Актуальное состояние реализации и фактических проверок: [current-status.md](current-status.md). MAX отложен, активный канал — Telegram Personal.
Рабочая изоляция реализована собственной политикой CE. Проверенные сценарии и открытые замечания фиксируются в [аудите](audit-2026-11-25.md) и evidence; историческая инвентаризация ниже не означает, что проверки всё ещё не выполнены.

## Политика

Deny by default; сначала account boundary, затем бизнес-роль, ownership, разрешённое действие и актуальная версия. Менеджер получает свои контакты и историю, а также согласованную общую очередь новых неизвестных входящих со скрытым номером до привязки. Руководитель — всех и очередь, передача/освобождение только ему. technical_admin управляет каналами/секретами без доступа к содержимому по умолчанию. Временный доступ к данным требует отдельного разрешения и аудита. Суперадминистратор инфраструктуры с доступом к БД — отдельная доверенная роль, приложение не может устранить этот доступ.

Штатные administrator, team membership, inbox membership, participant, mention и possession of signed URL не должны расширять бизнес-доступ. Техническая и руководящая роли не сводятся к CE administrator. Для сервиса — отдельный principal, account/inbox/action allowlist, ротация и отзыв; не менеджерский или admin token.

## Реестр поверхностей

Все пути — upstream v4.20.1. «Осмотрено» означает статическое чтение, не пройденный security test. «Инвентаризация» — найден маршрут/класс, полный граф вызовов предстоит проверить в этапе 2.

| Поверхность | Проверенные точки / место дальнейшего аудита | Изменение и обязательная проверка A/B/R |
|---|---|---|
| Вход, account, токены | Осмотрено: api/base_controller, AccessTokenAuthHelper, EnsureCurrentAccountHelper | tenant + role на каждом пути, User/AgentBot, revoked token, disabled user, multi-account |
| Контакты/active/search/filter | Осмотрено: ContactPolicy, ContactsController, SearchService | общий ownership scope до пагинации и counts; IDOR show/update/avatar/custom attrs |
| Контактные подресурсы | attachments controller осмотрен; notes, labels, conversations, contact_inboxes — инвентаризация routes | закрыть чужой контакт и вложенные IDs; JSON не содержит чужих имён/каналов |
| Списки диалогов/meta/unread/filter | Осмотрено: ConversationFinder, PermissionFilterService, ConversationsController; unread routes найдены | scope до фильтра/агрегации, все статусы и «all», счётчики только доступного |
| Прямой диалог | Осмотрено: ConversationPolicy, conversations/base_controller | account + owner; team/inbox не дают обхода; ID и display_id |
| Создание/изменение диалога | Осмотрено: ConversationsController, AssignmentsController | atomic claim; запрет прямого assignee/contact/inbox tampering; передача только R |
| Сообщения/заметки | Осмотрено: MessagesController | index/create/update/delete/retry, private notes, translate/forward/reply — запрет чужого source/target ID |
| Поиск | Осмотрено: SearchService | contacts/conversations/messages, GIN/LIKE/fallback; snippets и pagination без утечки |
| Файлы/превью/аватар | Осмотрено: Attachment, contact attachments controller | ownership при каждом GET/HEAD/Range/preview; прежняя signed URL не обходит передачу; cache/no-store |
| ActiveStorage/direct uploads | Инвентаризация Rails engine и использования blob IDs | запрет стандартного публичного download; проверка владельца при прикреплении blob; content disposition |
| WebSocket/presence | Осмотрено: RoomChannel, ActionCableListener, ActionCableBroadcastJob | убрать контактные account-wide payload; персонифицированные события, send-time recheck; reconnect после передачи |
| Notifications | listener осмотрен; notifications_controller, NotificationFinder и push/email jobs — инвентаризация | списки/counts/старые уведомления и отправка после transfer; нейтральное revocation событие без контакта |
| Exports/transcripts/reports | contacts export и transcript осмотрены; data_exports, API v2 reports — инвентаризация | менеджеру закрыть; R только согласно роли; jobs проверяют права при выполнении и скачивании |
| Bulk/macros/automations | controllers и routes найдены | запрет смешанного набора чужих ID, закрыть assignment side effects, отложенные задачи после transfer |
| Mentions/teams/participants | event mentioned осмотрен; остальные — инвентаризация | упоминание не открывает чужой чат; поиск адресатов не раскрывает клиента, командные shortcuts не расширяют доступ |
| Client/public/widget/mobile | public inbox controllers осмотрены; widget/platform routes — инвентаризация | неиспользуемые пути закрыть proxy и сервером; мобильные клиенты используют те же API и policies |
| Интеграции/webhooks | Осмотрено: WebhookListener, Webhooks::Trigger, Channel::Api | сервисный auth, exact-body HMAC, TTL/replay/size; внутренние notes не отправляются клиенту |
| Объединение/удаление | contact merge routes, jobs — инвентаризация | только R с аудитом, конфликты владельцев без молчаливого присвоения, lifecycle deletion |
| Админка/секреты | InboxPolicy осмотрен; super_admin — инвентаризация | выделить technical scope, закрыть просмотр чатов, токены не включать в manager JSON |
| Кеш/логи/errors | presenters, serializers, frontend stores, logger — полный аудит впереди | нейтральные 404/отказы, cache keys с account/user/version, без текста сообщений/секретов в логах |

## Проверки до реальных данных

Фикстуры A/B/R/T + отдельный Account2, X владельца A и Y владельца B, неизвестный Z. Для каждой поверхности проверить положительное чтение A→X и R→все, отрицательное B→X, A→Y, A/B→Z, T→содержимое и любой cross-account. Перебирать методы и action-specific permissions; проверять полный JSON, заголовки, бинарный файл и WebSocket frames, а не только UI/HTTP status.

Отдельные конкурентные сценарии: A/B одновременно claim X; создание идентичности X из Telegram/MAX одновременно; transfer во время queued event, send и file download; деактивация пользователя/отзыв токена при открытом socket; повтор webhook и retry после unknown. При transfer новый владелец получает историю, старый не получает новые данные; queued jobs пересчитывают получателя. Закрыть/открыть чат — владелец прежний.

Тесты этапа 2: Rails policies/request/channel/job specs, Vue tests очистки stores/subscriptions и hidden actions; E2E Playwright проверяет UI и фактическую сеть. CI на mock inbox, без живых каналов. Результаты выполненных проверок приведены в current-status.md и evidence; непроверенные сценарии отдельно перечислены в отчётах.

## Данные и эксплуатация

TLS, internal-only services, отдельные DB роли, приватные backups/session volumes, ограничение upload, карантин файлов. Шифрование сессий/backup и ключи вне Git; ротация и restore проверяются отдельно. Сотрудники не получают session/api_hash. Аудит минимален по содержанию, ограничен по чтению и защищён от изменения обычным пользователем. Удаление контакта не должно бесконтрольно удалять audit trail; политика retention требует решения владельца.

152-ФЗ, локализация, основания обработки, доступ сотрудников и сроки хранения согласуются до production. Технические меры не означают подтверждённого юридического соответствия. Документы и переписки не передаются сторонним AI в MVP.

## Дополнение: Битрикс24 и общая очередь

По согласованию владельца добавлена CRM. Правила назначения, исключение для входящих со скрытым номером, сопоставление сотрудников и восстановление описаны в [инструкции Битрикс24](bitrix24.md) и [ADR 0004](decisions/0004-bitrix-and-shared-intake.md). Эти правила имеют приоритет над прежним отложенным статусом CRM и запретом общей очереди. Никогда ранее не назначенные неизвестные входящие общие до привязки; старые приватные клиенты не раскрываются.
