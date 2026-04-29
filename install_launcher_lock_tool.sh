#!/usr/bin/env bash
# install_launcher_lock_tool.sh — instalacja LOCK TOOL (SaaS launcher + WebUI)
#
# Użycie:
#   sudo bash install_launcher_lock_tool.sh
#   sudo bash install_launcher_lock_tool.sh --server https://licenses.example.com
#   sudo bash install_launcher_lock_tool.sh --binary /sciezka/do/launcher_lock_tool
#   sudo bash install_launcher_lock_tool.sh --skip-register
#
# Co robi:
#   1. Instaluje launcher binary → /usr/local/bin/launcher_lock_tool
#   2. Tworzy /etc/lock_tool/launcher.conf
#   3. Instaluje webui.py + lock.json → /opt/lock-tool/
#   4. Tworzy run-webui.sh → /opt/lock-tool/
#   5. Instaluje serwis systemd (WebUI)
#   6. Rejestruje maszynę na serwerze licencji

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

DEFAULT_SERVER="https://licenses.example.com"
INSTALL_BIN="/usr/local/bin/launcher_lock_tool"
CONF_DIR="/etc/lock_tool"
CONF_FILE="${CONF_DIR}/launcher.conf"
PREFIX="/opt/lock-tool"

SERVER_URL="$DEFAULT_SERVER"
BINARY_SRC=""
SKIP_REGISTER=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --server)        SERVER_URL="$2";    shift 2 ;;
        --binary)        BINARY_SRC="$2";    shift 2 ;;
        --skip-register) SKIP_REGISTER=true; shift   ;;
        --help|-h)
            echo "Użycie: sudo bash $0 [--server URL] [--binary /sciezka/launcher_lock_tool] [--skip-register]"
            exit 0 ;;
        *) die "Nieznana opcja: $1" ;;
    esac
done

[[ $EUID -eq 0 ]] || die "Uruchom jako root: sudo bash $0"
[[ "$(uname -s)" == "Linux" ]] || die "Tylko Linux."

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}  LOCK TOOL — Instalacja launchera + WebUI                   ${NC}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
info "Serwer licencji: ${SERVER_URL}"
info "Katalog źródłowy: ${SCRIPT_DIR}"
echo ""

# ════════════════════════════════════════════════════════════════════
# KROK 1 — Zależności
# ════════════════════════════════════════════════════════════════════
echo -e "${YELLOW}[1/6] Instalacja zależności...${NC}"
apt-get install -y --no-install-recommends \
    libssl3 libcurl4 python3 python3-flask \
    > /dev/null 2>&1 && ok "Zależności zainstalowane (libssl3, libcurl4, python3, flask)." \
                      || warn "Nie udało się zainstalować zależności — kontynuuję."

# ════════════════════════════════════════════════════════════════════
# KROK 2 — Launcher binary
# ════════════════════════════════════════════════════════════════════
echo -e "${YELLOW}[2/6] Instalacja launchera...${NC}"

if [[ -z "$BINARY_SRC" ]]; then
    if   [[ -f "${SCRIPT_DIR}/launcher_lock_tool"      ]]; then BINARY_SRC="${SCRIPT_DIR}/launcher_lock_tool"
    elif [[ -f "${SCRIPT_DIR}/dist/launcher_lock_tool" ]]; then BINARY_SRC="${SCRIPT_DIR}/dist/launcher_lock_tool"
    elif [[ -f "$(pwd)/launcher_lock_tool"             ]]; then BINARY_SRC="$(pwd)/launcher_lock_tool"
    else die "Nie znaleziono pliku 'launcher_lock_tool'. Podaj ścieżkę: --binary /sciezka/launcher_lock_tool"
    fi
fi

[[ -f "$BINARY_SRC" ]] || die "Plik nie istnieje: $BINARY_SRC"
MAGIC=$(xxd -l 4 "$BINARY_SRC" 2>/dev/null | awk '{print $2$3}' || true)
[[ "$MAGIC" == "7f454c46" ]] || die "Plik nie jest binarką ELF: $BINARY_SRC"

install -m 755 "$BINARY_SRC" "$INSTALL_BIN"
ok "Launcher: ${INSTALL_BIN} ($(du -sh "$INSTALL_BIN" | cut -f1))"

# ════════════════════════════════════════════════════════════════════
# KROK 3 — Konfiguracja launchera
# ════════════════════════════════════════════════════════════════════
echo -e "${YELLOW}[3/6] Konfiguracja launchera...${NC}"

mkdir -p "$CONF_DIR"

EXISTING_KEY=""
if [[ -f "$CONF_FILE" ]]; then
    EXISTING_KEY=$(grep "^license_key" "$CONF_FILE" 2>/dev/null | awk -F= '{print $2}' | tr -d ' ' || true)
    [[ -n "$EXISTING_KEY" ]] && info "Zachowuję istniejący klucz: ${EXISTING_KEY}"
fi

cat > "$CONF_FILE" <<EOF
# Konfiguracja launchera LOCK TOOL
# Wygenerowano: $(date -u +%Y-%m-%dT%H:%M:%SZ)

[server]
url             = ${SERVER_URL}
timeout_connect = 5
timeout_read    = 10

[license]
license_key     = ${EXISTING_KEY}

[paths]
lease_file      = ~/.config/lock_tool/.lease
EOF

chmod 644 "$CONF_FILE"
ok "Konfiguracja: ${CONF_FILE}"

for user_home in "$HOME" "$(getent passwd "${SUDO_USER:-}" 2>/dev/null | cut -d: -f6)"; do
    [[ -z "$user_home" || ! -d "$user_home" ]] && continue
    LEASE_DIR="${user_home}/.config/lock_tool"
    if [[ ! -d "$LEASE_DIR" ]]; then
        mkdir -p "$LEASE_DIR"
        chmod 700 "$LEASE_DIR"
        OWNER=$(stat -c '%U' "$user_home" 2>/dev/null || echo "root")
        chown "$OWNER:$OWNER" "$LEASE_DIR" 2>/dev/null || true
    fi
done
ok "Katalog lease gotowy."

# ════════════════════════════════════════════════════════════════════
# KROK 4 — Pliki aplikacji: webui.py + lock.json
# ════════════════════════════════════════════════════════════════════
echo -e "${YELLOW}[4/6] Instalacja plików aplikacji (${PREFIX}/)...${NC}"

mkdir -p "$PREFIX"

if [[ -f "${SCRIPT_DIR}/webui.py" ]]; then
    install -m 755 "${SCRIPT_DIR}/webui.py" "${PREFIX}/webui.py"
    ok "webui.py → ${PREFIX}/"
else
    warn "Brak webui.py w ${SCRIPT_DIR} — dodaj ręcznie."
fi

# lock.json — nie nadpisuj jeśli już istnieje (klient mógł skonfigurować)
if [[ -f "${SCRIPT_DIR}/lock.json" ]]; then
    if [[ -f "${PREFIX}/lock.json" ]]; then
        warn "Zachowuję istniejący: ${PREFIX}/lock.json"
    else
        install -m 644 "${SCRIPT_DIR}/lock.json" "${PREFIX}/lock.json"
        ok "lock.json → ${PREFIX}/"
    fi
else
    warn "Brak lock.json w ${SCRIPT_DIR} — dodaj ręcznie."
fi

# run-webui.sh — kluczowe: LOCK_TOOL_BIN wskazuje na launcher_lock_tool
cat > "${PREFIX}/run-webui.sh" <<RUNEOF
#!/usr/bin/env bash
set -euo pipefail
export LOCK_JSON="${PREFIX}/lock.json"
export LOCK_TOOL_BIN="${INSTALL_BIN}"
export LOCK_WEBUI_HOST="127.0.0.1"
export LOCK_WEBUI_PORT="8088"
exec python3 "${PREFIX}/webui.py"
RUNEOF
chmod +x "${PREFIX}/run-webui.sh"
ok "run-webui.sh → ${PREFIX}/ (LOCK_TOOL_BIN=${INSTALL_BIN})"

# uninstall.sh — kopia dla wygody
if [[ -f "${SCRIPT_DIR}/uninstall_launcher_lock_tool.sh" ]]; then
    install -m 755 "${SCRIPT_DIR}/uninstall_launcher_lock_tool.sh" "${PREFIX}/uninstall.sh"
    ok "uninstall.sh → ${PREFIX}/"
fi

# ════════════════════════════════════════════════════════════════════
# KROK 5 — Serwis systemd WebUI
# ════════════════════════════════════════════════════════════════════
echo -e "${YELLOW}[5/6] Konfiguracja systemd...${NC}"

cat > /etc/systemd/system/lock-tool-webui.service <<EOF
[Unit]
Description=LOCK TOOL WebUI
After=network.target

[Service]
Type=simple
ExecStart=${PREFIX}/run-webui.sh
Restart=on-failure
NoNewPrivileges=yes
PrivateTmp=yes
ProtectHome=yes
ProtectSystem=full

[Install]
WantedBy=multi-user.target
EOF

ok "lock-tool-webui.service"
systemctl daemon-reload
ok "systemd daemon-reload"

# ════════════════════════════════════════════════════════════════════
# KROK 6 — Rejestracja licencji
# ════════════════════════════════════════════════════════════════════
echo -e "${YELLOW}[6/6] Rejestracja licencji...${NC}"

LICENSE_KEY=""

if [[ "$SKIP_REGISTER" == true ]]; then
    info "Pominięto rejestrację (--skip-register)."
    info "Uruchom ręcznie: sudo launcher_lock_tool --register"
else
    OUTPUT=""
    EXIT_CODE=0
    OUTPUT=$("$INSTALL_BIN" --register 2>&1) || EXIT_CODE=$?

    if [[ $EXIT_CODE -ne 0 ]]; then
        warn "Rejestracja nieudana (kod: ${EXIT_CODE})."
        warn "Sprawdź połączenie z serwerem: ${SERVER_URL}"
        warn "Zarejestruj ręcznie: sudo launcher_lock_tool --register"
    else
        LICENSE_KEY=$(echo "${OUTPUT}" | grep -oP 'LICENSE_KEY=\K[A-Za-z0-9]+' || true)
        if [[ -n "$LICENSE_KEY" ]]; then
            sed -i "s/^license_key.*=.*/license_key     = ${LICENSE_KEY}/" "$CONF_FILE"
        fi
    fi
fi

# ════════════════════════════════════════════════════════════════════
# PODSUMOWANIE
# ════════════════════════════════════════════════════════════════════
echo ""
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}${BOLD}  ✅ INSTALACJA ZAKOŃCZONA POMYŚLNIE!${NC}"
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

if [[ -n "${LICENSE_KEY:-}" ]]; then
    echo -e "  Twój klucz instalacyjny:"
    echo ""
    echo -e "  ${BOLD}${CYAN}  ${LICENSE_KEY}  ${NC}"
    echo ""
    echo -e "  ${YELLOW}Status: PENDING${NC} — czeka na aktywację przez administratora."
    echo -e "  Panel:  ${CYAN}${SERVER_URL}/status?key=${LICENSE_KEY}${NC}"
    echo ""
fi

echo "📁 Zainstalowane pliki:"
echo "   ${INSTALL_BIN}     ← launcher (weryfikacja licencji + uruchomienie core)"
echo "   ${CONF_FILE}  ← konfiguracja launchera"
echo "   ${PREFIX}/webui.py         ← WebUI panel klienta"
echo "   ${PREFIX}/lock.json        ← konfiguracja transpondera (EDYTUJ!)"
echo "   ${PREFIX}/run-webui.sh     ← skrypt startowy WebUI"
echo ""
echo "🔧 Następne kroki:"
echo "   1. Aktywuj licencję w panelu admina"
echo "   2. Dostosuj ${PREFIX}/lock.json do swojego transpondera"
echo "   3. Uruchom WebUI:"
echo "      sudo systemctl enable --now lock-tool-webui"
echo ""
echo -e "  🌐 WebUI: ${CYAN}http://$(hostname -I | awk '{print $1}'):8088${NC}"
echo ""
