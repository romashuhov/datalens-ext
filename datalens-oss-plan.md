# DataLens OSS: доработанный план (права доступа + AD/SSO)

Версия документа: 2026-09-12. Основан на Notion-странице «Попытка доработать DataLens OSS» и на discovery по коду форков в этом репозитории:

| Компонент | Версия в форке | Где смотрел |
|---|---|---|
| datalens (compose, release 2.9.0) | `1cebb39` | `datalens/docker-compose.yaml`, `init.sh` |
| datalens-us | 1.39.0 | `datalens-us/src` |
| datalens-ui | 0.3831.0 | `datalens-ui/src` |
| datalens-auth | 0.27.0 | `datalens-auth/src` |
| datalens-backend (control-api / data-api) | 0.2457.0 в compose, читал `main` | shallow clone в scratchpad, не форк |

---

## 0. Главные выводы

1. **Гипотеза подтверждена.** В US `registry/plugins/common` классы `Collection`, `Workbook`, `SharedEntry` и `DLS` — заглушки на глобальной роли. Platform-реализация ACL в OSS отсутствует, но все интерфейсы (`checkPermission`, `fetchAllPermissions`, `bulkFetchAllPermissions`, `register`, `deletePermissions`, везде с `parentIds`) уже вызываются в нужных местах. Достаточно заменить три класса.
2. **UI управления доступом уже написан.** `IamAccessDialog` (таблицы прямых и унаследованных прав, добавление субъектов, поиск пользователей) лежит в `datalens-ui/src/ui/components/IamAccessDialog`. В OSS он выключен тремя вещами: фича `CollectionsAccessEnabled = false`, в реестре компонентов `IamAccessDialogComponent = пустой компонент`, gateway-сервис `extensions` состоит из заглушек, возвращающих `[]`. Значит UI-этап — это «подключить и дописать переключатель наследования», а не «написать с нуля».
3. **API access bindings в US нет вообще.** Ни роутов, ни таблиц. Контракт, который ожидает UI, задан типами в `datalens-ui/src/shared/schema/extensions/types/iam-access-dialog.ts`. Его и стоит реализовать.
4. **Backend (control-api, data-api) защищён автоматически.** При `AUTH__TYPE=NATIVE` backend работает в режиме `USAuthMode.regular`: проверяет JWT пользователя сам и пробрасывает его в US на публичные `/v1` роуты. Значит проверки прав в US закрывают и прямые запросы к datasets/charts data. Private-роуты (`/private/...`, master token) проверки пропускают, ими пользуются только сервисы.
5. **Zitadel в US 1.39 и UI 0.3831 отсутствует.** Файлы `auth-zitadel.ts`, `utils/zitadel.ts`, флаг `ZITADEL` из плана в этих версиях удалены. Zitadel остался только в Python-backend как один из `AUTH__TYPE`. Для нас этот путь бесполезен.
6. **datalens-auth уже готов к IdP-пользователям.** Таблица `auth_users` имеет колонки `idp_user_id`, `idp_slug`, `idp_type`; local-стратегия passport фильтрует `idp_type IS NULL`; есть флаг `AUTH_MANAGE_LOCAL_USERS_DISABLED`. Стратегии OIDC/SAML нет. SSO логично реализовать внутри datalens-auth, а не внешним адаптером, потому что UI-middleware зависит от `/refresh` и `/v1/users/me/profile` этого сервиса.
7. **Рекомендация по архитектуре:** на первом этапе Access Service делать **модулем внутри US** (таблицы в БД US, резолвер в процессе), с интерфейсом, который позже можно вынести в отдельный сервис. Причины ниже в разделе 2.

---

## 1. Права доступа: что реально есть в коде

### 1.1 Точки расширения (US)

`datalens-us/src/registry/plugins/common/index.ts` объявляет реестр классов `DLS`, `Workbook`, `Collection`, `SharedEntry` и функций (`checkOrganizationPermission`, `isNeedBypassEntryByKey`, `logEvent`, …). `setup.ts` регистрирует OSS-реализации. Заменить реализацию = зарегистрировать другие классы.

Интерфейс (`entities/structure-item/types.ts`):

```
register({parentIds})                     // вызывается при создании Collection/Workbook
checkPermission({parentIds, permission})  // бросает ACCESS_SERVICE_PERMISSION_DENIED
fetchAllPermissions({parentIds})          // заполняет this.permissions
static bulkFetchAllPermissions(ctx, [{model, parentIds}])
deletePermissions({parentIds})            // при удалении
enableAllPermissions()                    // когда accessService выключен
```

`parentIds` всегда передаётся: `getParentIds` (`services/new/collection/utils/get-parents.ts`) делает рекурсивный CTE и возвращает цепочку от ближайшего родителя к корню. **Порядок в SQL не задан** (`ORDER BY` нет), он получается правильным только потому, что Postgres отдаёт строки рекурсивного CTE в порядке обхода. Код уже на него опирается (`parents.slice(1)` в `get-workbooks-list.ts`). Рядом есть детерминированный вариант: `makeParentsMap` + `getParentsIdsFromMap`, которые строят цепочку по `parentId` каждой строки. Резолвер должен использовать только его (см. 3.2).

### 1.2 Заглушка

`collection.ts` / `workbook.ts` / `shared-entry.ts`: `getAllPermissions()` смотрит только на `user.roles` (глобальные `datalens.editor` / `datalens.admin`), `register()` возвращает `getMockedOperation`, `deletePermissions()` — no-op. Важная деталь: с глобальной ролью Viewer сегодня `view = true` для всего.

**Ловушка в `bulkFetchAllPermissions`:** заглушка вызывает `fetchAllPermissions({parentIds: []})` для каждого элемента, то есть выбрасывает цепочку родителей, которую ей передали. Если новая реализация повторит это, наследование в списках молча не заработает: объект откроется по прямой ссылке (там `parentIds` берутся из `getParentIds`), но в списке коллекции его не будет. У элементов одного списка цепочки не всегда одинаковые: `get-collections-list-by-ids.ts` и `get-workbooks-list-by-ids.ts` строят `parentIds` для каждого элемента отдельно через `makeCollectionsWithParentsMap` / `makeWorkbooksWithParentsMap`.

### 1.3 Enum'ы прав и ролей

| Ресурс | Permissions | Roles (уже есть в коде) |
|---|---|---|
| Collection | listAccessBindings, updateAccessBindings, createCollection, createWorkbook, createSharedEntry, limitedView, view, update, copy, move, delete | limitedViewer, viewer, editor, admin |
| Workbook | listAccessBindings, updateAccessBindings, limitedView, view, update, copy, move, publish, embed, delete | limitedViewer, viewer, editor, admin |
| SharedEntry | listAccessBindings, updateAccessBindings, limitedView, view, update, copy, move, delete, createEntryBinding, createLimitedEntryBinding | + entryBindingCreator, limitedEntryBindingCreator |

Наши 4 уровня (Viewer / Editor / Admin / No access) ложатся на существующие `CollectionRole` / `WorkbookRole` почти один в один. UI-конфиг `iamResources` в `datalens-ui/src/server/configs/opensource/common.ts` уже содержит идентификаторы ролей `datalens.collections.viewer`, `datalens.workbooks.editor` и т.п. Придётся добавить только `noAccess`.

### 1.4 Где вызываются проверки (основные)

| Сценарий | Файл (datalens-us/src/services/new/…) | Что проверяется |
|---|---|---|
| Открыть коллекцию | `collection/get-collection.ts` → `utils/check-and-set-collections-permission.ts` | Collection.LimitedView, + fetchAllPermissions если `includePermissionsInfo` |
| Содержимое коллекции | `collection/get-collection-content.ts`, `structure-item/get-structure-items.ts` | LimitedView на родителе, затем `checkPermission` **на каждый элемент страницы** (Promise.all, pageSize 100), затем `bulkFetchAllPermissions` |
| Список воркбуков | `workbook/get-workbooks-list.ts`, `get-workbooks-list-by-ids.ts`, `collection/get-collections-list-by-ids.ts` | то же |
| Хлебные крошки | `collection/get-collection-breadcrumbs.ts` | LimitedView на **каждом** предке через `Promise.all`; отказ на любом уровне = исключение, падает весь запрос. UI это частично терпит: `CollectionPage` при 403 рисует крошки из одной текущей папки, а `IamAccessDialog` при ошибке молча отключает список унаследованных прав. Решение в 3.5 |
| Открыть воркбук | `workbook/get-workbook.ts` | Workbook.LimitedView / все permissions |
| Объекты внутри воркбука | `entry/get-entry/utils.ts` → `workbook/utils/get-entry-permissions-by-workbook.ts` | execute = limitedView, read = view (для dash/widget/report — limitedView), edit = update, admin = updateAccessBindings |
| Данные чартов (charts-engine, data-api) | `entry/get-joined-entries-revisions-by-ids.ts` | Execute на воркбук |
| Создание / перемещение / копирование / удаление | `collection/create-collection.ts`, `workbook/create-workbook.ts`, `move-*.ts`, `copy-workbook.ts`, `delete-*.ts` | createCollection / createWorkbook на целевой коллекции, Move/Copy/Delete на объекте, `register()` после создания, `deletePermissions()` после удаления |
| Корень | `collection/get-collection-root-permissions.ts` → `checkOrganizationPermission` | глобальная роль (создание в корне) — **оставляем как есть** |

Вывод: **никаких новых проверок в контроллерах и сервисах не нужно.** Объекты внутри Workbook (datasets, charts, dashboards, connections) уже наследуют права воркбука.

**Что на самом деле означает `updateAccessBindings`.** Это не только «управлять доступом». В `get-entry-permissions-by-workbook.ts` из него выводится entry-уровневый `admin`, и в UI на `permissions.admin` завязаны: публикация дашборда/чарта (`DialogSwitchPublic`, `EntryPanel`), контекстное меню shared entries внутри воркбука (`WorkbookEntriesTable/utils.ts`: для записи с `collectionId` меню показывается только при `updateAccessBindings`), диалог доступа у датасетов и подключений, а также массовое перемещение в legacy-навигации. Экспорт воркбука в UI проверяет только фичу `EnableExportWorkbookFile` и глобальную настройку, без permissions; импорт делает meta-manager, его проверка в разделе 7. Вывод для таблицы ролей в 3.3: если `updateAccessBindings` отдать только Admin, редакторы теряют публикацию и работу с shared entries. Это нужно решить до утверждения таблицы (вопрос 2 в разделе 6).

### 1.5 Что пропускает проверки

`isPrivateRoute` (master token или dynamic master token) отключает ACL. Кто ходит private-роутами: UI-сервер (3 действия в `shared/schema/us-private`: meta записи, get entry, list entries; плюс workbook-export), meta-manager (экспорт/импорт), backend через `private_us_manager` для сервисных операций. Это допустимо, но в этапе hardening нужно пройти по этим вызовам и убедиться, что они не отдают пользователю данные из недоступного воркбука.

### 1.6 Access bindings API: чего ждёт UI

Контракт из `datalens-ui/src/shared/schema/extensions/types/iam-access-dialog.ts`:

```
listCollectionAccessBindings({collectionId, withInherits?, pageSize?, pageTokenData?})
  -> [{resource: {type: 'datalens.collection', id}, response: {accessBindings: [{roleId, subject: {id, type}}], nextPageToken}}]
     (при withInherits=true — по одному элементу на каждый уровень цепочки)
updateCollectionAccessBindings({collectionId, deltas: [{action: 'ADD'|'REMOVE', accessBinding: {roleId, subject}}]})
  -> Operation
listWorkbookAccessBindings / updateWorkbookAccessBindings — аналогично
getClaims({subjectIds}) -> {subjectDetails: [{subjectClaims: {sub, subType, email, name, givenName, familyName, preferredUsername}}]}
batchListMembers({search, pageSize, pageToken}) -> {members: SubjectClaims[], nextPageToken}
```

`getClaims` и `batchListMembers` покрываются существующими роутами datalens-auth `POST /v1/users/get-by-ids` и `GET /v1/users/list` (permission `InstanceUse`, доступна любой роли), в UI они уже есть как `auth.getUsersByIds` / `auth.getUsersList`.

### 1.7 Тесты

`datalens-us/src/tests/int/env/platform/*` — тесты Яндекс-платформы: в фейковый токен кладутся `accessBindings`, т.е. это мок их внешнего Access Service. Запускается только `opensource`-набор (`jest/int/run.js`). Нам нужно добавить свои suites в `env/opensource` с реальными bindings через API.

---

## 2. Расхождения плана с реальностью и решения

| Пункт плана | Что в коде | Решение |
|---|---|---|
| Отдельный Access Service по HTTP | Списки вызывают `checkPermission` на каждый элемент; `bulkFetchAllPermissions` есть, но `checkPermission` в циклах остаётся. Отдельный сервис = до 100 HTTP-вызовов на страницу списка либо переписывание всех списков. | **Модуль внутри US**: таблицы в БД US, резолвер в процессе, кэш цепочек в рамках запроса. Интерфейс модуля (`AccessResolver`, `AccessBindingsRepository`) делаем таким, чтобы вынос в сервис был заменой реализации. |
| Zitadel как второй путь auth | В US/UI отсутствует | Из плана убрать. |
| Роли Viewer/Editor/Admin/No access | В DataLens есть `limitedViewer/viewer/editor/admin`, deny-роли нет | Используем родные 4 роли + добавляем `noAccess`. `limitedViewer` (видеть дашборды, не видеть датасеты) в UI не показываем на первом этапе, но в резолвере поддерживаем. |
| `inheritPermissions=false` | Колонки нет | Отдельная таблица `access_settings` (см. 3.1), а не колонка в `collections`, чтобы не трогать upstream-схему и упростить синк форка. |
| «Дыра»: без явного Viewer где-то пользователь ничего не видит | Корень проверяется по глобальной роли | Ввести **политику корня** `ACL_ROOT_DEFAULT_ROLE = viewer \| none` (env). Это виртуальный binding `subject=*` на корне: наследуется вниз как обычный, обрывается на `inherit=false` и перебивается `noAccess`. Решено: `viewer` только на период миграции, цель `none`. |
| Глобальные роли | `datalens.viewer/editor/admin` продолжают управлять созданием в корне и админкой | Оставить. Глобальный `datalens.admin` считать суперпользователем (все permissions), чтобы нельзя было залочить инстанс. |
| Shared entries (датасеты/подключения в коллекциях) | В US 1.39 уже есть `SharedEntry` со своим ACL-интерфейсом, в UI фича `EnableSharedEntries` | Собственных bindings не заводим; `SharedEntry` наследует роль родительской коллекции. Иначе включение ACL сломает shared entries. |
| Аудит изменений ACL | Нет | В таблице bindings храним `created_by/created_at`; полноценный audit trail не делаем. |

---

## 3. Модель прав (уточнённая)

### 3.1 Хранилище (миграция в datalens-us)

```
access_bindings
  resource_type  text      -- 'datalens.collection' | 'datalens.workbook' (ResourceType из entities/types.ts)
  resource_id    bigint    -- collections.collection_id / workbooks.workbook_id
  subject_type   text      -- 'user' (позже 'group')
  subject_id     text      -- userId из JWT (закодированный id datalens-auth)
  role           text      -- limitedViewer | viewer | editor | admin | noAccess
  created_at, created_by
  PK (resource_type, resource_id, subject_type, subject_id)
  INDEX (subject_type, subject_id)

access_settings
  resource_type, resource_id  PK
  inherit        boolean not null default true
  updated_at, updated_by
```

Одна роль на пару субъект-ресурс. Это упрощает UI (`ADD` с другой ролью = replace) и резолвер.

### 3.2 Резолвер

Вход: `userId`, `roles` (глобальные), `target = {type, id}`, `parentIds` (ближайший → корень).

Порядок цепочки резолвер получает не из массива, который вернул `getParents`, а строит сам из `parentsMap` (`Map<collectionId, parentId>`) через `getParentsIdsFromMap`. Шаг 3 от порядка не зависит, шаги 4–5 зависят. Заодно стоит поправить сам `getParentIds`: после CTE собирать цепочку через `makeParentsMap` + `getParentsIdsFromMap`. Одна функция, 34 вызова по коду перестают зависеть от порядка строк Postgres.

1. Если глобальная роль `datalens.admin` → `admin`.
2. Цепочка `chain = [target, ...parentIds]`. Одним запросом грузим bindings пользователя для всех элементов цепочки, вторым — `access_settings` для них.
3. Если на любом элементе цепочки у пользователя `noAccess` → **No access** (терминально).
4. Идём по цепочке от target вверх. На каждом уровне: если есть явный binding → это ответ. Если у уровня `inherit=false` → останавливаемся (bindings этого уровня уже учтены), ответ **No access**.
5. Дошли до корня без ответа → применяем `ACL_ROOT_DEFAULT_ROLE` (если `viewer`) или **No access**.
6. Роль → permissions по таблице 3.3.

Тот же алгоритм для группы субъектов после появления групп: шаги 3–4 выполняются по множеству `{user} ∪ groups`, конфликт на одном уровне решается по правилу «deny > max(allow)» (Tableau-подобно). В v1 не реализуем, но структура запроса это позволяет.

### 3.3 Роль → permissions (предложение, требует подтверждения)

| Permission | limitedViewer | viewer | editor | admin |
|---|---|---|---|---|
| limitedView | ✓ | ✓ | ✓ | ✓ |
| view | | ✓ | ✓ | ✓ |
| copy | | ✓ | ✓ | ✓ |
| update, createCollection, createWorkbook, createSharedEntry, publish, embed | | | ✓ | ✓ |
| move | | | ✓ | ✓ |
| delete | | | | ✓ |
| listAccessBindings | | | ✓ | ✓ |
| updateAccessBindings | | | | ✓ |

Спорные места: `delete` для editor (в плане Admin = «административные операции»; я бы оставил удаление админу), `copy` для viewer (копирование в свою коллекцию — безопасно, права на копию получает автор). `move` дополнительно требует `createWorkbook/createCollection` на целевой коллекции, это уже есть в `move-*.ts`.

Отдельно про `updateAccessBindings` (см. 1.4): при таблице выше редакторы не смогут публиковать дашборды и работать с shared entries внутри воркбука, потому что entry-уровневый `admin` выводится из этого права.

**Решено: семантика облака, маппинг не трогаем.** Обе функции в OSS выключены по умолчанию: `EnablePublishEntry` и `EnableSharedEntries` в `features-list` стоят в `false` для production, и в корпоративном контуре с AD публичные дашборды обычно не нужны. Пока эти фичи не включены, вопрос не возникает. Если публикация понадобится позже, менять вывод `admin` в `get-entry-permissions-by-workbook.ts` нельзя: из `permissions.admin` выводится не только кнопка публикации, и такая правка задевает все места сразу, включая неразобранные. Чинить точечно сами проверки: диалог публикации смотрит на `publish`, контекстное меню shared entries — на `update`. Тот же объём правок без побочных эффектов и честнее при мерже с upstream.

### 3.4 Жизненный цикл bindings

- `register()` при создании: автор получает `admin` на новый объект (иначе после включения `inherit=false` объект станет недоступен даже создателю).
- `deletePermissions()`: удалить bindings и settings объекта (у воркбуков и коллекций уже есть вызовы в `delete-*.ts`).
- Копирование воркбука: копия получает только `admin` автора, bindings оригинала не копируются.
- Перемещение: bindings остаются на объекте, меняется только цепочка родителей. Это ожидаемо и совпадает с UI «унаследованные права».

### 3.5 Доступ к вложенной папке без прав на предков

Основной сценарий: пользователю выдан Viewer только на `Компания / Финансы / Отчёты`. Сейчас при этом ломаются две вещи, и обе решаются одним решением, которое нужно принять до этапа 1.

1. `get-collection-breadcrumbs.ts` проверяет LimitedView на каждом предке и падает целиком. UI показывает крошки из одной папки, диалог доступа теряет унаследованные права.
2. Из корня до папки не дойти: `get-collection-content.ts` фильтрует элементы по LimitedView, `Компания` в корневом списке не появится. Папка доступна только по прямой ссылке.

| Вариант | Что менять | Плюсы | Минусы |
|---|---|---|---|
| A. Обрезать путь до ближайшей доступной папки | `get-collection-breadcrumbs.ts`: ловить `ACCESS_SERVICE_PERMISSION_DENIED`, возвращать хвост цепочки | Минимальные правки | Проблема 2 не решается: из корня папку не найти, нужен отдельный вход (избранное, поиск, ссылка) |
| B. Недоступных предков показывать только названием | Модель ответа крошек получает `accessible: boolean`, UI рисует такие элементы без ссылки; корневой список не меняется | Путь виден целиком | Проблема 2 не решается; утекают названия закрытых папок |
| **C. Неявный «проход» вверх по цепочке (принято)** | Если у пользователя есть роль ≥ viewer на любой потомок коллекции, на саму коллекцию он получает неявный `limitedView`. Крошки и корневой список начинают работать без правок в них | Поведение как в Google Drive и файловых системах: папка видна, внутри только то, к чему есть доступ | Нужно быстро отвечать «есть ли доступ ниже» для каждого элемента списка |

**Решено: вариант C, хранение без денормализации.** ACL живёт в одной базе с `collections`, поэтому множество «сквозных» папок считается одним запросом на HTTP-запрос пользователя: взять коллекции и воркбуки, где у него есть binding с ролью не ниже `viewer` (для воркбука взять его `collectionId`), и рекурсивным CTE по `parentId` подняться до корня. Результат — набор id коллекций, хранится в кэше запроса рядом с кэшем цепочек. Проверка для любого элемента списка — вхождение в множество в памяти. Bindings у одного человека обычно десятки, запрос дешёвый. Дерево остаётся только в `collections`, при перемещении ничего не пересчитывается, схема из 3.1 не меняется, и решение перестаёт блокировать этап 1. Колонка `resource_path bigint[]` с GIN-индексом остаётся в запасе как оптимизация, если на реальных объёмах запрос окажется дорогим.

Три правила корректности для C:

- bindings `noAccess` сами по себе не делают папку видимой: фильтр по роли прямо в запросе;
- неявный проход даёт строго `limitedView`, ни `view`, ни ничего выше; содержимое папки по-прежнему фильтруется поэлементно;
- названия и описания промежуточных папок становятся видны пользователю. Это осознанное решение, имя папки иногда само по себе информация; при именовании закрытых разделов это нужно помнить.

`noAccess` на предке по-прежнему сильнее неявного прохода.

---

## 4. Этапы реализации (вертикальные срезы)

### Этап 0. Подготовка (0.5 дня)

- Ветки в форках us/ui/auth, dev-контур через `datalens/init.sh --dev-us --dev-ui`.
- В US новый конфиг `objectAclEnabled` (env `OBJECT_ACL_ENABLED`, по умолчанию `false`): при `false` регистрируются старые заглушки, при `true` — новые классы. Даёт безопасный откат.
- В CI два прогона `test:int`: с флагом выключенным (старый набор без изменений) и включённым (старый набор плюс новые suites). Выключенный прогон обязан оставаться зелёным на каждом этапе.

### Этап 1. Ядро ACL в US, без UI (2–4 дня)

Файлы (новые, datalens-us):

```
src/db/migrations/2026xxxx_access_bindings.ts
src/components/access/types.ts            # Role, Subject, ResourceRef, EffectiveAccess
src/components/access/repository.ts       # bindings/settings CRUD, batch load по цепочке
src/components/access/resolver.ts         # алгоритм 3.2
src/components/access/role-permissions.ts # таблица 3.3 для Collection/Workbook/SharedEntry
src/registry/plugins/acl/entities/collection.ts
src/registry/plugins/acl/entities/workbook.ts
src/registry/plugins/acl/entities/shared-entry.ts   # роль = роль родительской коллекции
src/registry/plugins/acl/setup.ts
```

Изменяемые: `src/configs/common.ts` (флаг), `src/registry/setup.ts` (выбор плагина), `src/types/nodekit.ts`.

Обязательные требования к реализации, вытекающие из 1.2 и 3.2:

- `bulkFetchAllPermissions` берёт `parentIds` из каждого элемента, группирует элементы с одинаковой цепочкой и делает один запрос на группу. Пустой массив никогда не подставляется.
- Цепочка строится через `parentsMap`, не через порядок массива.
- Резолвер fail-closed: любое исключение внутри него (БД, неизвестная роль, отсутствующая строка `access_settings`) превращается в `ACCESS_SERVICE_PERMISSION_DENIED`, исходная ошибка пишется в лог. Отдельный unit-тест на это.
- Вариант C из 3.5: в кэше запроса есть множество «сквозных» коллекций (один рекурсивный запрос от bindings пользователя вверх), `checkPermission(LimitedView)` на коллекции сверяется с ним после обычного резолва. Схему не трогаем.

Первый тест (`src/tests/int/env/opensource/suites/acl/basic.test.ts`): создать коллекцию Finance админом, руками вставить bindings `Alice → viewer`, `Bob → noAccess`; `GET /v1/collections/:id` от Alice = 200, от Bob = 403 `ACCESS_SERVICE_PERMISSION_DENIED`; `GET /v1/collections/:id/content` для Alice не содержит недоступных вложенных объектов.

Регрессионный тест на ловушку из 1.2: Alice → viewer на `Finance`, воркбук `Forecast` внутри без локальных прав. `GET /v2/workbooks/:id` = 200 **и** `Forecast` присутствует в `GET /v1/collections/:financeId/content`, в `POST /v2/workbooks-get-list-by-ids` и в `GET /v1/structure-items`.

### Этап 2. Наследование, `inherit=false`, явный No access (1–2 дня)

Unit-тесты резолвера на сценарии из плана: Finance→Viewer / Forecast без локальных прав; Forecast→Editor поверх Viewer; Secret Forecast с `inherit=false`; `noAccess` на предке против Editor ниже; политика корня `viewer` и её обрыв на `inherit=false`.

Сценарий из 3.5 как интеграционный тест: Viewer только на `Компания / Финансы / Отчёты`. Ожидаем: `GET /v1/collections/:отчёты/breadcrumbs` = 200 с тремя элементами, корневой `content` содержит `Компания`, внутри `Компания` виден только `Финансы`, `GET /v1/collections/:компания` = 200 без `view`. Плюс перемещение `Отчёты` в другую ветку и повторная проверка.

### Этап 3. Производительность списков (1 день)

- В `bulkFetchAllPermissions` грузить bindings одним запросом для всех элементов страницы (все `parentIds` одинаковы внутри одной коллекции).
- Кэш bindings и settings по цепочке в `ctx` на время запроса, чтобы 100 вызовов `checkPermission` в `get-collection-content.ts` не делали 100 запросов в БД.
- Замер на коллекции с 100+ воркбуками.

### Этап 4. API управления bindings в US (1–2 дня)

Роуты (в `src/routes.ts`, контроллеры с zod-схемами как у соседних):

```
GET  /v1/collections/:collectionId/access-bindings?withInherits&pageSize   (permission listAccessBindings)
POST /v1/collections/:collectionId/access-bindings   {deltas}              (updateAccessBindings)
POST /v1/collections/:collectionId/access-settings   {inherit}             (updateAccessBindings)
GET/POST /v1/workbooks/:workbookId/access-bindings, /access-settings        аналогично
```

Формат ответа — как в 1.6, чтобы UI-редьюсеры не переписывать. `withInherits=true` возвращает элементы по всей цепочке предков, помечая уровень, где `inherit=false`. Тесты на 403 для Viewer/Editor при попытке изменить bindings.

### Этап 5. UI (2–3 дня)

- `datalens-ui/src/server/components/features/features-list/CollectionsAccessEnabled.ts`: `production: true` для OSS.
- `src/ui/registry/units/common/components-map.tsx` (или OSS-регистрация): `IamAccessDialogComponent` → реальный `IamAccessDialogComponent`.
- `src/shared/schema/extensions/actions/iam-access-dialog.ts`: заглушки → реальные `createAction` на US-роуты этапа 4; `getClaims` и `batchListMembers` → маппинг результата `auth.getUsersByIds` / `auth.getUsersList` в `SubjectClaims` (`sub = userId`, `subType = USER_ACCOUNT`, `name = firstName lastName`, `preferredUsername = login`).
- В диалог добавить переключатель «Наследовать права от родительской коллекции» (новый небольшой блок в `AccessList`, вызывает `/access-settings`), в конфиг `iamResources` — роль `noAccess` с локализацией, в `AccessList` визуально различать прямые и унаследованные (таблицы для этого уже две).
- Проверить, что `permissions.listAccessBindings/updateAccessBindings` из ответа US корректно скрывают кнопку доступа у Viewer.

### Этап 6. Hardening (1–2 дня)

- Пройти все `usPrivate`-вызовы UI и meta-manager (экспорт/импорт воркбука): после импорта автор должен получить `admin`.
- Навигация/поиск: `get-structure-items.ts`, избранное (`favorites`), `get-entries` с фильтрами — убедиться, что фильтрация по LimitedView работает и в них.
- Публичные дашборды и embeds (`onlyPublic`, `DL_EMBED_TOKEN_HEADER`) — не должны сломаться, ACL их не касается.
- Скрипт миграции существующих инсталляций (`src/db/scripts/acl-bootstrap.ts`, запускается один раз при включении флага): для каждой живой коллекции и воркбука вставить binding `createdBy → admin`. Идемпотентный, с dry-run и отчётом, сколько объектов и авторов затронуто. Пользователи, которых уже нет в auth, получают binding всё равно, чистить его не нужно.
- Порядок включения на проде: миграция схемы → bootstrap-скрипт → `ACL_ROOT_DEFAULT_ROLE=viewer` + `OBJECT_ACL_ENABLED=true` → админы раздают права → переключение корня на `none`.
- Документация по env-флагам и по этому порядку.

Итого ядро прав: ориентировочно 8–14 рабочих дней одного разработчика до рабочего UI.

---

## 5. Интеграция с AD / SSO: результаты discovery

### 5.1 Как auth устроен сейчас

```
Browser ──cookie {accessToken, refreshToken} + cookie *_exp──▶ UI server (ui-auth.ts)
   │  1) нет cookie → страница signin (React, units/auth) → POST /gateway/auth/auth/signin → datalens-auth /signin (passport-local)
   │  2) exp близко → gateway → datalens-auth POST /refresh → новые cookie
   │  3) jwt.verify(accessToken, AUTH_TOKEN_PUBLIC_KEY, PS256) → userId, sessionId, roles
   │  4) datalens-auth GET /v1/users/me/profile (Bearer) → profile в контекст
   ▼
UI server ──Authorization: Bearer <accessToken>──▶ US (/v1), control-api, data-api, meta-manager
                                                  (Utils.pickAuthHeaders; charts-engine пробрасывает Authorization)
US:        app-auth.ts: jwt.verify → {userId, sessionId, roles}
backend:   dl_auth_native: jwt.decode → {userId, exp, roles?}; далее US regular mode с тем же Bearer
datalens-auth: jwt-auth.ts подписывает PS256 приватным ключом; таблицы auth_users, auth_sessions, auth_refresh_tokens, auth_roles
```

Ответы на вопросы плана:

| Вопрос | Ответ |
|---|---|
| Кто создаёт пользователя | datalens-auth: `/signup` (self-signup, отключается `AUTH_SIGNUP_DISABLED`) и `/v1/management/users/create` (админ, UI «Настройки сервиса → Пользователи»). Admin `admin/admin` создаётся при init. |
| Где хранится | `pg-auth-db.auth_users` (login, password, first/last name, email, **idp_user_id, idp_slug, idp_type**) |
| Session / refresh | `auth_sessions` (TTL 30 дней), `auth_refresh_tokens` (10 дней), access token 15 минут. Refresh делает UI-сервер прозрачно для браузера. |
| Кто подписывает JWT | datalens-auth, `TOKEN_PRIVATE_KEY`; публичный ключ раздаётся через env `AUTH_TOKEN_PUBLIC_KEY` в ui, us, meta-manager, backend (`AUTH__JWT_KEY`). |
| Обязательные claims | US и UI: `userId, sessionId, roles`; backend: `userId, exp`, `roles` опционально. `sessionId` формально нигде не валидируется, но нужен для `/refresh`. |
| Обязательные roles | Для входа в UI — любая; для создания в корне — `datalens.editor`/`datalens.admin`; `defaultRole` при signup = `datalens.viewer`. |
| Нужна ли запись в pg-auth-db | **Да**: UI на каждом запросе страницы дергает `/v1/users/me/profile`, а `/refresh` ищет сессию в БД. Внешний адаптер без записи пользователя в auth-БД не заработает. |
| Кто ещё валидирует токен | UI server, US, meta-manager, control-api, data-api. Все по одному публичному ключу. |
| Zitadel | В UI/US отсутствует. В backend есть, но без UI/US это неприменимо. |

### 5.2 Варианты интеграции

| Вариант | Объём изменений | Поддержка | Внешние зависимости | Группы AD | Безопасность | Локальная разработка |
|---|---|---|---|---|---|---|
| **A. OIDC внутри datalens-auth** (passport `openid-client`), корпоративный IdP = ADFS / Keycloak / Entra ID поверх AD | auth: стратегия + 2 роута + upsert пользователя по `idp_user_id`; UI: кнопка «Войти через SSO» и проксирование `/auth/oidc/*`; US/backend: **0** | низкая, всё в одном сервисе | нужен OIDC-провайдер над AD (обычно уже есть) | claim `groups` или запрос к IdP при логине | стандартный code flow, токены DataLens не меняются | нужен dev-IdP (Keycloak в compose) |
| B. AD → Keycloak (LDAP federation) → вариант A | как A + Keycloak | средняя | Keycloak | Keycloak умеет отдавать группы AD | ок | Keycloak в compose закрывает и dev |
| C. Внешний адаптер, выпускающий DataLens-JWT | адаптер должен реализовать `/signin`, `/refresh`, `/logout`, `/v1/users/me/profile`, `/v1/users/list`, `get-by-ids` — фактически переписать datalens-auth | высокая | свой сервис | самим | свой код с ключами подписи | сложно |
| D. LDAP bind прямо в datalens-auth (passport-ldapauth) | auth: стратегия + upsert; UI: та же форма логина | низкая | доступ к LDAP из контура DataLens | membership из LDAP при логине | пароль пользователя проходит через DataLens | нужен тестовый LDAP |

**Решено: A**, если у компании есть OIDC-провайдер над AD, иначе **B** (Keycloak с федерацией в AD). Вариант D остаётся только на случай, когда ставить Keycloak запрещено: LDAP bind не даёт единого входа и прогоняет доменные пароли через DataLens, а Keycloak настраивается за день, сразу отдаёт группы и закрывает локальную разработку. A и B одинаково живут в datalens-auth и не трогают контракт токенов, US и backend.

Как быстро понять, какой IdP есть: если компания живёт на Microsoft 365 или Teams, Entra ID уже есть и годится сразу. Если есть внутренние сервисы с единым входом, спросить у админов, через что они ходят, обычно это ADFS на адресе вида `adfs.<домен>`.

### 5.3 План SSO (вариант A)

1. **Discovery у заказчика (0.5 дня):** какой IdP доступен (ADFS / Entra ID / Keycloak), можно ли зарегистрировать OIDC-клиент, есть ли claim с группами (он нужен уже в v1 для ограничения входа группой).
2. **datalens-auth (2–3 дня):**
   - **generic OIDC-клиент без привязки к провайдеру:** конфигурация через discovery-документ `/.well-known/openid-configuration`, всё провайдер-специфичное только в env: `OIDC_ENABLED, OIDC_ISSUER, OIDC_CLIENT_ID, OIDC_CLIENT_SECRET, OIDC_REDIRECT_URI, OIDC_DEFAULT_ROLE, OIDC_GROUPS_CLAIM` (имя claim с группами, у Keycloak и Entra ID обычно `groups`, у ADFS настраивается правилами выдачи), `OIDC_EMAIL_CLAIM`, `OIDC_ALLOWED_GROUPS` в формате значений провайдера. Entra ID, ADFS 2016+ и Keycloak подключаются одним набором переменных, код не меняется;
   - роуты `GET /oidc/login` (redirect на IdP с state/nonce), `GET /oidc/callback` (обмен code, проверка членства в `OIDC_ALLOWED_GROUPS` по claim `groups` до любой записи в БД, затем upsert в `auth_users` по `idp_user_id + idp_slug`, роль по умолчанию через существующую логику ролей, `JwtAuth.startSession`, `setAuthCookie`); пользователь вне разрешённой группы получает страницу отказа без создания учётки;
   - **связывание с существующей локальной учёткой** (см. 5.5): при первом SSO-входе, если строки с таким `idp_user_id` нет, под флагом `OIDC_LINK_LOCAL_BY_EMAIL=true` искать локального пользователя (`idp_type IS NULL`) по почте и проставить `idp_*` в существующую строку, сохранив `user_id`;
   - `passport.ts`: local-стратегия не меняется;
   - `logout`: дополнительно RP-initiated logout в IdP (опционально);
   - хук `signinSuccess` из реестра уже есть, использовать.
3. **datalens-ui (1 день):** в `units/auth/components/Signin` кнопка «Войти через корпоративный SSO» (показывать при `DL.authSsoEnabled`), серверный роут, который редиректит на `AUTH_ENDPOINT/oidc/login` через прокси UI (auth в compose не наружу); `AUTH_SIGNUP_DISABLED=true` сразу. Одна локальная учётка администратора остаётся как аварийный вход, пароль в менеджере паролей. `AUTH_MANAGE_LOCAL_USERS_DISABLED` сразу не включать: этот флаг блокирует и роуты управления ролями (`/v1/management/users/roles/*` помечены `RouteCheck.ManageLocalUsers`).
4. **compose/helm (0.5 дня):** новые env, Keycloak-профиль для dev.
5. **PoC-проверка:** тестовый пользователь AD → SSO → `auth_users` содержит запись с `idp_type='oidc'` → страница DataLens открыта без локального пароля → US в логах видит стабильный `userId` → logout / истечение access token (15 мин) / refresh работают.

### 5.4 Группы (следующий этап, чтобы не закрыть путь)

- При OIDC-логине сохранять claim `groups` в новую таблицу `auth_user_groups (user_id, group_id, source)`.
- datalens-auth: роут `POST /v1/users/get-groups` (private, master token) или включать группы в профиль.
- ACL-резолвер US: `subjects = {user} ∪ groups(userId)` с кэшем на 1–5 минут; в `access_bindings` появляется `subject_type='group'`.
- В JWT группы **не** кладём (размер токена, cookie 4 КБ).

### 5.5 Существующие локальные пользователи при включении SSO

Если к моменту включения SSO в DataLens уже есть локальные пользователи со своим содержимым, обычный upsert по `idp_user_id` создаст им новые учётки с новыми `user_id`. А `user_id` — это и авторство объектов (`createdBy` в коллекциях и воркбуках), и субъект в наших bindings. Человек войдёт через SSO и не увидит ни своих книг как автор, ни выданных ему прав.

Лечится при первом SSO-входе в `/oidc/callback`:

1. Есть строка с таким `idp_user_id + idp_slug` → обычный вход.
2. Нет, и включён `OIDC_LINK_LOCAL_BY_EMAIL=true` → искать в `auth_users` строку с `idp_type IS NULL` и почтой, равной claim `email` из IdP (без учёта регистра). Совпадение должно быть **ровно одно**: в `auth_users` нет уникального индекса по почте, signup её уникальность не проверяет, поэтому при двух и более совпадениях ничего не связываем и логируем. Найденной строке проставляем `idp_user_id`, `idp_slug`, `idp_type`, `user_id` не меняется, локальный пароль можно обнулить.
3. Иначе создать нового пользователя.

Только по почте и только под явным флагом: связывание по логину или без флага превращается в способ угнать чужую учётку через IdP. Почту из IdP считаем доверенной, только если провайдер её верифицирует (claim `email_verified`, где он есть). Флаг включается на период миграции и выключается после.

---

## 6. Решения

Принято 2026-09-12:

- Access Service — модуль внутри US.
- `delete` только у admin, `copy` есть у viewer (таблица 3.3 утверждена в этой части).
- Политика корня: стартуем с `viewer` как временный режим миграции, целевое значение `none`. В коде это env `ACL_ROOT_DEFAULT_ROLE`, в документации явно помечаем `viewer` как переходный.
- `limitedViewer` в UI не показываем.
- Ошибка резолвера (нет строки настроек, невалидная роль, сбой БД) = отказ в доступе, никогда не «разрешить по умолчанию». Исключения из резолвера конвертируются в `ACCESS_SERVICE_PERMISSION_DENIED` с логированием исходной ошибки.
- Старый набор интеграционных тестов `env/opensource` должен проходить с `OBJECT_ACL_ENABLED=false` на каждом этапе; это проверка, что заглушка и старое поведение не задеты.
- Скрипт миграции существующих данных: авторы (`createdBy`) всех существующих коллекций и воркбуков получают `admin` на свои объекты. Без него после включения ACL управлять ими сможет только глобальный `datalens.admin`.
- На этапе SSO вход ограничивается членством в заданной группе AD (env `OIDC_ALLOWED_GROUPS`, проверка claim `groups` в callback; при отсутствии claim — запрос к IdP/LDAP). Пользователь вне группы получает отказ до создания записи в `auth_users`.

Принято по второму ревью:

- Публикация и shared entries: семантика облака, маппинг `admin` не трогаем, обе фичи в OSS и так выключены. Если публикация понадобится, чинить точечно проверки в UI (3.3).
- Вложенная папка без прав на предков: вариант C, неявный проход вверх, без `resource_path`. Множество «сквозных» папок считается одним рекурсивным запросом на HTTP-запрос и кэшируется рядом с цепочками (3.5). Схема 3.1 не меняется, этап 1 не заблокирован.
- IdP: A при наличии OIDC-провайдера над AD, иначе B (Keycloak с федерацией в AD). D только если Keycloak ставить запрещено (5.2).
- Локальные пользователи: self-signup выключить сразу, одну локальную админскую учётку оставить как аварийный вход, `AUTH_MANAGE_LOCAL_USERS_DISABLED` не включать (5.3).
- Связывание SSO-входа с существующими локальными учётками по почте под явным флагом (5.5).

Ещё открыто:

1. Какой именно IdP есть у компании над AD. Вопрос к админам, подсказки в 5.2. **Не блокирует:** OIDC-клиент делается generic через discovery, провайдер задаётся конфигом. Этапы 0–6 по правам доступа от IdP не зависят и начинаются сейчас, ответ нужен к началу этапа SSO. Единственное, что реально зависит от провайдера: как приходят группы (claim или отдельный запрос к IdP) и можно ли зарегистрировать клиент с нужным redirect URI.

---

## 7. Что осталось непроверенным

- Реальные размеры коллекций у заказчика (влияет на приоритет этапа 3).
- meta-manager (экспорт/импорт воркбуков) не форкнут: как он создаёт воркбуки, каким правом гейтит импорт и нужно ли выставлять bindings автору, проверю на этапе 6.
- Поведение `WorkbookIsolationEnabled` и `dynamic master token` в связке с ACL — фича выключена в OSS, но проверить стоит.

---

## 8. Статус реализации (2026-09-12)

Всё из разделов 4 и 5.3 реализовано в ветках `acl` четырёх форков, коммиты не запушены. Фактическую работу делали агенты на Opus, проверка и приёмка — по каждому этапу отдельно.

| Репозиторий | Коммиты в `acl` | Что внутри |
|---|---|---|
| datalens-us | 3 | миграция `access_bindings` / `access_settings`, модуль `src/components/access`, плагин `registry/plugins/acl`, флаги `OBJECT_ACL_ENABLED` / `ACL_ROOT_DEFAULT_ROLE`, 8 роутов access-bindings / access-settings, `acl:bootstrap`, детерминированный `getParents` |
| datalens-ui | 3 | тестовый вход на странице входа; диалог доступа подключён (`COLLECTIONS_ACCESS_ENABLED`), `extensions` → US и auth, роль noAccess, переключатель наследования; кнопка SSO и прокси `/auth/oidc/*` |
| datalens-auth | 2 | тестовый вход `POST /dev/signin`; generic OIDC: `/oidc/login`, `/oidc/callback`, `OIDC_ALLOWED_GROUPS`, `OIDC_LINK_LOCAL_BY_EMAIL`, HTML-редирект после входа |
| datalens | 4 | env в compose, `docs/acl.md`, `docs/sso.md`, `docs/dev-login.md`, README |

Дополнительно, вне исходного плана: **тестовый вход по почте без пароля** (`AUTH_DEV_LOGIN_ENABLED`) для локальной проверки прав. Отдельный `POST /dev/signin` в auth, блок на странице входа с галочкой «выдать роль editor», пользователи помечены `idp_type = dev` и никогда не пересекаются с локальными и SSO-учётками. Проверено на стенде: 16 сценарных проверок, включая создание в корне под editor, отказ viewer'у, выдачу прав между двумя тестовыми пользователями через диалог.

Проверки, выполненные при приёмке:

- US: lint, build, unit 36/36; старый интеграционный набор с выключенным флагом 233/233; ACL-suites с включённым флагом 61/61.
- auth: lint, typecheck, unit 37/37, интеграционные 96/96 (включая OIDC с in-process мок-провайдером).
- UI: typecheck server и ui, eslint, prettier, jest 856/856, production-сборка.
- Живой стенд (Postgres из образа datalens-postgres, auth, US и UI из dist): сценарий из 3.5 и остальных разделов, 26/26 проверок через API US и 14/14 через gateway UI, включая проход по цепочке, terminal noAccess, inherit=false, замену роли, отказы viewer'у, bootstrap в dry-run и прокси OIDC.

Отклонения от плана, принятые при реализации:

- `register()` теперь проверяет право `createCollection` / `createWorkbook` на родителе: в US 1.39 это право нигде больше не проверялось, заглушка была единственным барьером.
- Старый набор тестов с включённым флагом не проходит по семантическим причинам (автор объекта стал его админом, `admin: true` в permissions), это не ошибки; ACL-набор гоняется отдельно с флагом, старый — без.
- В API bindings пагинация внутри уровня ограничена `pageSize` (по умолчанию 100) без курсора.

Не проверено: вход через реальный IdP и диалог доступа в браузере глазами (проверены только typecheck, jest, сборка и вызовы gateway). Это первое, что стоит сделать при развёртывании.
