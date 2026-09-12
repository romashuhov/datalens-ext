#!/usr/bin/env bash
# Пересинхронизация локальных клонов форков DataLens после переписывания истории ветки acl
# и включения принудительного LF (.gitattributes).
#
# Запускать из каталога, где рядом лежат datalens, datalens-us, datalens-ui, datalens-auth:
#   bash resync.sh
# или без скачивания файла:
#   curl -fsSL https://raw.githubusercontent.com/romashuhov/datalens-ext/main/resync.sh | bash
#
# Что делает для каждого репозитория:
#   1. сохраняет ваши незакоммиченные правки в патч (различия только в CRLF не считаются правками)
#      и копирует неотслеживаемые файлы в бэкап;
#   2. забирает ветку acl с GitHub и жёстко переключается на неё;
#   3. перечитывает все файлы с LF согласно .gitattributes;
#   4. накладывает ваши правки обратно; при конфликте оставляет патч в бэкапе и сообщает.
# Игнорируемые файлы (.env, node_modules, dist) не трогаются.
set -uo pipefail

REPOS="datalens datalens-us datalens-ui datalens-auth"
BACKUP="$PWD/resync-backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP"
failed=""

for r in $REPOS; do
  if [ ! -d "$r/.git" ]; then
    echo "!! $r: не найден в $PWD, пропускаю"
    failed="$failed $r"
    continue
  fi
  echo "== $r"
  (
    set -e
    cd "$r"
    git config core.autocrlf false

    # 1. свои правки: CR в конце строк отбрасываем, чтобы патч не тащил CRLF обратно
    git diff --ignore-cr-at-eol HEAD | sed 's/\r$//' > "$BACKUP/$r.patch"
    untracked=$(git ls-files --others --exclude-standard)
    if [ -n "$untracked" ]; then
      while IFS= read -r f; do
        mkdir -p "$BACKUP/$r-untracked/$(dirname "$f")"
        cp "$f" "$BACKUP/$r-untracked/$f"
      done <<<"$untracked"
    fi

    # 2. переписанная ветка
    git fetch -q origin acl
    git reset -q --hard
    git checkout -q -B acl origin/acl

    # 3. перечитать файлы с LF
    git rm -rq --cached . && git reset -q --hard

    # 4. вернуть правки
    if [ -s "$BACKUP/$r.patch" ]; then
      if git apply --3way --ignore-whitespace "$BACKUP/$r.patch" 2>/dev/null; then
        echo "   правки возвращены: $(git diff --name-only HEAD | tr '\n' ' ')"
      else
        echo "   !! правки не наложились автоматически, патч: $BACKUP/$r.patch"
        exit 2
      fi
    else
      echo "   своих правок не было"
    fi
    if [ -d "$BACKUP/$r-untracked" ]; then
      cp -R "$BACKUP/$r-untracked/." .
      echo "   неотслеживаемые файлы возвращены"
    fi
    echo "   ветка acl = $(git rev-parse --short HEAD), CRLF в скриптах: $(git ls-files -z '*.sh' | xargs -0 grep -l $'\r' 2>/dev/null | wc -l)"
  ) || failed="$failed $r"
done

echo
echo "Бэкап правок: $BACKUP"
if [ -n "$failed" ]; then
  echo "Требуют внимания:$failed"
  exit 1
fi
echo "Готово. Дальше как обычно: cd datalens && ./init.sh --dev --dev-env --dev-us --dev-auth --dev-ui --dev-root"
