# Лабораторная инфраструктура этапа 1

- `upstream.lock.json`: официальный Chatwoot source SHA.
- `images.lock.env/json`: registry digest и платформы CE, pgvector/PostgreSQL, Redis 7.2, Nginx.
- `chatwoot/Dockerfile`: производный образ из официального CE с проверкой SHA/отсутствия Enterprise.
- `postgres/01-chatwoot.sh`: первый init отдельной БД и app-role без superuser; extensions созданы администратором.
- `nginx/default.conf`: localhost reverse proxy/WebSocket.
- Корневой `compose.yaml`: внутренние БД/Redis/web/worker, one-shot migrations, persistent volumes, healthchecks, профиль tools для синтетического seed.

Сборка/запуск пока не выполнены: Docker Engine отсутствует. Процедура и статус — [operations](../docs/operations.md), [stage-1-report](../docs/stage-1-report.md). Production/TLS/реальные аккаунты не подключены.
