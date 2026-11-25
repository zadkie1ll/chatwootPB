# Риски и критерии закрытия

| ID | Риск / текущее состояние | Действие и критерий закрытия |
|---|---|---|
| R01 блокер | MAX Personal: разрешённый API не подтверждён; соглашение ограничивает сторонние интеграции | Владелец получает подтверждение допустимого интерфейса; затем полный PoC. Иначе no-go/пересмотр MVP |
| R02 критический | CE inbox/team access не обеспечивает owner isolation | Общая серверная политика + вся матрица security.md на mock inbox до реальных данных |
| R03 критический | WebSocket/account contact broadcasts, presence и queued recipients | Персональный fanout, send-time authorization, transfer race/reconnect tests |
| R04 критический | Signed URLs сохраняют доступ к файлам | Private download proxy, закрытие обходных storage URLs, HEAD/Range/preview tests после transfer |
| R05 высокий | Потеря API inbox webhook и внешний timeout с неизвестным исходом | CW transaction outbox + Django ledger/reconcile, fault injection без потери/слепого retry |
| R06 высокий | Гонка claim/merge/transfer/send | Unique identity/ownership + locking/fencing, конкурентные тесты, видимый in-flight/unknown |
| R07 высокий | CE admin смешивает права R и T | Собственные role grants, аудит всех admin shortcuts, T без истории по умолчанию |
| R08 высокий | Потеря/утечка общей сессии; действия из официального клиента | Один session owner, защищённые backups, revoke/reconnect/no-echo smoke; инструкции администратора |
| R09 высокий | AGPL Telemax и сторонние зависимости/образы | Не включать Telemax без отдельного анализа обязательств; SBOM/notice/security review для итоговой сборки |
| R10 высокий | ПДн и размещение не согласованы | До production владелец согласует инфраструктуру, основания/retention/доступ/провайдеров; это не закрывается кодом |
| R11 средний | Rate limit/приватность/платные сообщения Telegram | Проверяемые отказы и паузы; не обходить, не оплачивать автоматически, не гарантировать любой номер |
| R12 средний | Обновления upstream ломают CE fork | Pinned SHA/digests, журнал патчей, focused regression на каждом upgrade |
| R13 высокий | Неопределённые нагрузка, RPO/RTO и файлы | Согласовать до нагрузочной/операционной приёмки; restore измерить фактически |

Ни один риск не считается закрытым только наличием этой документации. R01 сейчас блокирует MAX-часть и подтверждение полного MVP, но не завершение discovery.
