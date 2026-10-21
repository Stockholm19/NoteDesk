#!/bin/sh
# Мост для Claude Desktop: stdio → локальный MCP NoteDesk (HTTP на 127.0.0.1:18473).
#
# Токен берётся из Keychain — того же элемента, который создаёт NoteDesk
# (служба app.notedesk.mcp, учётная запись bearer-v1), и никуда не копируется.
# При первом запуске macOS спросит, можно ли программе security прочитать
# этот элемент: введите пароль от Mac и нажмите «Разрешать всегда».
#
# В claude_desktop_config.json:
#   "notedesk": { "command": "/полный/путь/к/scripts/notedesk-mcp-bridge.sh" }

NOTEDESK_MCP_TOKEN="$(/usr/bin/security find-generic-password -s app.notedesk.mcp -a bearer-v1 -w 2>/dev/null)"
if [ -z "$NOTEDESK_MCP_TOKEN" ]; then
  echo "NoteDesk MCP: токена нет в Keychain. Включите MCP в настройках NoteDesk и разрешите доступ к Keychain." >&2
  exit 1
fi
export NOTEDESK_MCP_TOKEN

# Claude Desktop запускает команды с коротким PATH
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

# Версия моста закреплена: обновлять осознанно, а не при каждом запуске.
# ${NOTEDESK_MCP_TOKEN} в одинарных кавычках раскрывает сам mcp-remote —
# так токен не попадает в командную строку процесса (ps).
exec npx -y mcp-remote@0.14.3 http://127.0.0.1:18473/mcp \
  --transport http-only \
  --header 'Authorization:Bearer ${NOTEDESK_MCP_TOKEN}' \
  --silent
