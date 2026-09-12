# datalens-ext

Форки DataLens OSS с двумя доработками, которых нет в оригинале:

1. **Права доступа на папки и книги** (Collection / Workbook): Viewer, Editor, Admin, «Нет доступа», наследование вниз по дереву, отключение наследования на любом объекте.
2. **Вход через корпоративную учётку** (SSO по OpenID Connect поверх Active Directory): Entra ID, ADFS, Keycloak или любой другой провайдер с discovery-документом.

Обе доработки выключены по умолчанию и включаются переменными окружения.

## Что где лежит

| Каталог | Что это | Ветка с доработками |
|---|---|---|
| `datalens/` | docker-compose, образ Postgres, документация | `acl` |
| `datalens-us/` | United Storage: хранилище объектов, здесь живут права | `acl` |
| `datalens-ui/` | интерфейс и его сервер, здесь диалог доступа и кнопка SSO | `acl` |
| `datalens-auth/` | сервис аутентификации, здесь OIDC | `acl` |
| `datalens-oss-plan.md` | план работ, решения и статус реализации | — |

Каталоги форков в этот репозиторий не входят (см. `.gitignore`), у каждого свой git с remote `github.com/romashuhov/<name>`. Ветка `main` в каждом форке равна upstream, все изменения в ветке `acl`.

Backend на Python (control-api, data-api) не форкался: он пробрасывает токен пользователя в US, и права применяются к нему без изменений.

## Документация

- [datalens/docs/acl.md](datalens/docs/acl.md): роли, правила наследования, порядок включения на существующей установке, API управления правами.
- [datalens/docs/sso.md](datalens/docs/sso.md): как устроен вход, все переменные `OIDC_*`, ограничение по группе AD, привязка существующих локальных учёток, примеры для Keycloak и Entra ID, чек-лист проверки.
- [datalens/README.md](datalens/README.md): штатная инструкция по запуску DataLens, в конце разделы про SSO и права.

## Быстрый старт

```sh
cd datalens
./init.sh --hc            # генерирует .env со случайными секретами
```

В `.env` добавить:

```sh
# права доступа
OBJECT_ACL_ENABLED=true
ACL_ROOT_DEFAULT_ROLE=viewer     # на время миграции; целевое значение none

# вход через корпоративную учётку
OIDC_ENABLED=true
OIDC_ISSUER=https://<провайдер>/...
OIDC_CLIENT_ID=...
OIDC_CLIENT_SECRET=...
OIDC_REDIRECT_URI=http://<адрес DataLens>/auth/oidc/callback
OIDC_ALLOWED_GROUPS=datalens-users
AUTH_SIGNUP_DISABLED=true
```

Затем `docker compose -f docker-compose.production.yaml up -d`. На установке с существующими данными перед включением прав один раз запустить `docker compose exec us npm run acl:bootstrap`, чтобы авторы папок и книг остались их администраторами.

Образы из upstream (`ghcr.io/datalens-tech/*`) доработок не содержат: `us`, `ui` и `auth` нужно собирать из форков (`Dockerfile` в каждом) и подставлять свои теги в compose.

## Разработка и тесты

Нужен Linux Node 20 (в WSL ставится через nvm), для `datalens-us` pnpm 10.17.1, для остальных npm, для интеграционных тестов Docker.

```sh
# datalens-us
pnpm install && pnpm run build
pnpm run test:unit
JEST_MAX_WORKERS=3 pnpm run test:int:run                          # старый набор, флаг выключен
OBJECT_ACL_ENABLED=true JEST_MAX_WORKERS=3 pnpm run test:int:run acl   # набор по правам

# datalens-auth
npm ci && npm run lint && npm run typecheck && npm run test:int

# datalens-ui
npm ci && npm run typecheck && npm run lint && npm run test:jest && npm run build
```

Особенности:

- интеграционные тесты `datalens-us` используют контейнеры с фиксированными именами `postgres-test-N`, два прогона одновременно ломают друг друга;
- `npm run test:int` в `datalens-auth` записывает в корень репозитория `.env` с тестовыми значениями (в том числе `OIDC_ENABLED=true`), локальный запуск сервера после тестов его подхватит;
- старый набор тестов US с включённым флагом прав не проходит, и это ожидаемо: автор объекта стал его администратором, и старые проверки «нет прав» перестали быть верными. Поэтому два прогона: старый набор без флага, набор `acl` с флагом.

## Что осталось проверить

Вход через настоящий корпоративный провайдер и диалог доступа в браузере. Всё остальное покрыто тестами и живым прогоном через API, детали в разделе 8 плана.
