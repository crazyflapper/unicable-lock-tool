#!/usr/bin/env bash
# uninstall_launcher_lock_tool.sh — deinstalacja LOCK TOOL

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info() { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()   { echo -e "${GREEN}[OK]${NC}    $*"; }

[[ $EUID -eq 0 ]] || { echo -e "${RED}[ERROR]${NC} Uruchom jako root: sudo bash $0" >&2; exit 1; }

PREFIX="/opt/lock-tool"

echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}  LOCK TOOL — Deinstalacja                                   ${NC}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

systemctl stop    lock-tool-webui.service 2>/dev/null || true
systemctl disable lock-tool-webui.service 2>/dev/null || true
rm -f /etc/systemd/system/lock-tool-webui.service
systemctl daemon-reload 2>/dev/null || true
ok "Serwis systemd usunięty."

rm -f /usr/local/bin/launcher_lock_tool
ok "Launcher usunięty."

rm -rf /etc/lock_tool
ok "Konfiguracja usunięta (/etc/lock_tool/)."

rm -rf "$PREFIX"
ok "Pliki aplikacji usunięte (${PREFIX}/)."

for home_dir in /root /home/*; do
    LEASE="$home_dir/.config/lock_tool"
    [[ -d "$LEASE" ]] || continue
    rm -rf "$LEASE"
    info "Usunięto lease: ${LEASE}"
done

echo ""
echo -e "${GREEN}${BOLD}  ✅ Deinstalacja zakończona.${NC}"
echo ""
