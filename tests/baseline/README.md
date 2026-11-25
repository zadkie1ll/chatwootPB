# Диагностика исходных прав CE — этап 1

Это лабораторные сценарии без реальных клиентов и мессенджеров. Они воспроизводят права **неизменённого CE**, включая доступ B к чатам A. PASS у baseline означает совпадение с ожидаемым поведением upstream, а не выполнение требований изоляции корпоративного продукта. В отчёте эти наблюдения получают `owner_isolation_requirement_met: false`.

`seed.rb`: подтверждённые A/B как agent, R как штатный administrator исключительно для baseline, D во второй организации; синтетические X/Y/Z/Q и API inbox без внешнего webhook. R здесь ещё не соответствует будущей бизнес-роли руководителя. Автоназначение отключено. Не добавляет SuperAdmin. Отказывается от повторного посева и работает только в БД chatwoot_lab с lab confirmation.

`runtime.rb`: SHA, отсутствие Enterprise и extensions, не-superuser DB role, Redis, heartbeat Sidekiq, текущие миграции и local storage. `check.mjs`: HTML и compiled asset, вход A/B/R, чтение чужих контактов/чатов/сообщений, поиск/список/неназначенный, межаккаунтный отказ, запрет анонимного чтения, WebSocket B при изменениях A, private note, передача и повторное скачивание signed URL. Это ограниченный baseline, не полная матрица security.md и не браузерный E2E.

Запуск после поднятия стенда:

```bash
bash scripts/compose.sh --profile tools run --rm lab-seed
python3 scripts/check-lab.py
```

Требуются Node с глобальными fetch/WebSocket (например Node 24), Python 3 и Docker Engine. Секреты из .env и secrets/baseline.json не печатаются. Отчёты создаются только после фактического запуска в docs/evidence/stage-1-{runtime,baseline}.json. Сценарий временно меняет имя X и assignee, возвращает их обратно; добавляет private note, поэтому запускать только на этом синтетическом наборе. Fixture seed не повторять на существующем наборе.
