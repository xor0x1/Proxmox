#!/usr/bin/env bash
set -Eeuo pipefail

# === Config (можно править под себя) ===
ROLE="ZabbixMonitoring"
PRIVS='Datastore.Audit Sys.Audit VM.Audit'
GROUP="zabbix"
USER="zabbix@pam"
TOKEN_NAME="zabbix"
SCOPE="/"                 # Глубина назначения роли (обычно корень)
TOKEN_FILE="zbx.token"
PRIVSEP=0                 # 0 = отключить разделение привилегий для токена
# ================================

# Красивый вывод
c_green(){ printf "\033[1;32m%s\033[0m\n" "$*"; }
c_yellow(){ printf "\033[1;33m%s\033[0m\n" "$*"; }
c_blue(){ printf "\033[1;34m%s\033[0m\n" "$*"; }
c_red(){ printf "\033[1;31m%s\033[0m\n" "$*"; }

trap 'c_red "❌ Ошибка на строке $LINENO. Прерываю."' ERR

require_tools() {
  command -v pveum >/dev/null 2>&1 || { c_red "Не найден pveum. Запустите на узле Proxmox."; exit 1; }
}

ensure_role() {
  if pveum role list | awk 'NR>1{print $1}' | grep -Fxq "$ROLE"; then
    c_blue "Роль $ROLE уже существует — пропускаю создание."
  else
    c_green "Создаю роль $ROLE с правами: $PRIVS"
    pveum role add "$ROLE" --privs "$PRIVS"
  fi
}

ensure_group() {
  if pveum group list | awk 'NR>1{print $1}' | grep -Fxq "$GROUP"; then
    c_blue "Группа $GROUP уже существует — пропускаю создание."
  else
    c_green "Создаю группу $GROUP"
    pveum group add "$GROUP"
  fi
}

ensure_acl() {
  # Проверяем, есть ли у группы нужная роль на нужном пути
  if pveum acl list | awk 'NR>1{print $1" "$2" "$4}' | grep -Fqx "$SCOPE $ROLE group:$GROUP"; then
    c_blue "ACL для группы $GROUP на $SCOPE с ролью $ROLE уже задан — пропускаю."
  else
    c_green "Назначаю группе $GROUP роль $ROLE на $SCOPE"
    pveum acl modify "$SCOPE" -group "$GROUP" -role "$ROLE"
  fi
}

ensure_user() {
  if pveum user list | awk 'NR>1{print $1}' | grep -Fxq "$USER"; then
    c_blue "Пользователь $USER уже существует — пропускаю создание."
  else
    c_green "Создаю пользователя $USER"
    pveum user add "$USER"
  fi

  # ВНИМАНИЕ: следующая команда ЗАМЕНЯЕТ список групп пользователя.
  # Если нужно сохранить существующие группы, добавьте их здесь через запятую.
  if pveum user list | awk -v u="$USER" 'NR>1 && $1==u{print $3}' | grep -q "\<$GROUP\>"; then
    c_blue "Пользователь $USER уже состоит в группе $GROUP — пропускаю добавление."
  else
    c_green "Добавляю пользователя $USER в группу $GROUP"
    pveum user modify "$USER" -group "$GROUP"
  fi
}

ensure_token() {
  # Проверим, есть ли уже токен с таким именем
  if pveum user token list "$USER" 2>/dev/null | awk 'NR>1{print $1}' | grep -Fxq "$TOKEN_NAME"; then
    c_yellow "Токен $TOKEN_NAME для $USER уже существует."
    c_yellow "Я НЕ буду пересоздавать его (иначе старый станет недействительным)."
    c_yellow "Если хотите пересоздать — удалите вручную и запустите скрипт снова:"
    c_yellow "  pveum user token delete $USER $TOKEN_NAME"
    return 0
  fi

  c_green "Создаю токен $TOKEN_NAME для $USER (privsep=$PRIVSEP)"
  # pveum вернёт tokenid/full-tokenid/value; сохраним весь вывод в файл
  pveum user token add "$USER" "$TOKEN_NAME" -privsep "$PRIVSEP" | tee "$TOKEN_FILE" >/dev/null

  chmod 600 "$TOKEN_FILE"
  c_green "Токен сохранён в файл: $TOKEN_FILE (права 600). Берегите его!"
}

main() {
  c_blue "▶ Начинаем подготовку токена для Proxmox API (Zabbix)"
  require_tools
  ensure_role
  ensure_group
  ensure_acl
  ensure_user
  ensure_token
  c_green "✔ Все действия успешно выполнены."
  cat <<EOF

Подсказка по использованию:
  • Файл с данными токена: $TOKEN_FILE
  • В заголовке HTTP используйте:
      Authorization: PVEAPIToken=<full-tokenid>=<value>
    где <full-tokenid> и <value> взяты из $TOKEN_FILE

Пример для curl:
  FULL_TOKEN_ID=\$(awk -F': ' '/full-tokenid/ {print \$2}' $TOKEN_FILE)
  TOKEN_VALUE=\$(awk -F': ' '/value/ {print \$2}' $TOKEN_FILE)
  curl -sS \\
    -H "Authorization: PVEAPIToken=\${FULL_TOKEN_ID}=\${TOKEN_VALUE}" \\
    https://<pve-host>:8006/api2/json/nodes

EOF
}

main "$@"
