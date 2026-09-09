###############################################################################
# Instalação NetAlertX Baremetal/VM
# Autor: Diego Costa (@diegocostaroot) / Projeto Root (youtube.com/projetoroot)
# Veja o link: https://wiki.projetoroot.com.br
# 2026
#
# Requisitos:
#   - Debian 13 (Trixie)
#   - Arquitetura amd64 
#   - Execução como root
#   - Acesso à Internet
#   - Servidor dedicado, VM ou LXC
#
# Objetivo:
#   Automatizar a instalação do NetAlertX em ambiente bare-metal, VM ou LXC,
#   configurando automaticamente suas dependências, Python, PHP-FPM, Nginx,
#   SQLite, ARP-Scan, permissões, serviços systemd e runtime da aplicação.
#
#   O script também realiza validações do sistema, configura as portas Web
#   e API, atualiza a base OUI de fabricantes e executa um Health Check
#   ao final da instalação.
#
# Portas padrão:
#   - Web: 20211
#   - API/GraphQL: 20212
#
# Atenção:
#   - Recomendado para uma instalação limpa e dedicada ao NetAlertX.
#   - O diretório /app será removido e recriado durante a instalação.
#
# Execução:
#   chmod +x install-netalertx-debian13.sh
#   ./install-netalertx-debian13.sh
#
###############################################################################

# NetAlertX installer for Debian 13 (Trixie)
# Clean VM/LXC or bare-metal Debian 13 installation.
#
# Default ports:
#   Web: 20211
#   API: 20212
#
# Run:
#   chmod +x install-netalertx-debian13.sh
#   ./install-netalertx-debian13.sh
#
# Optional:
#   NETALERTX_ASSUME_YES=1 ./install-netalertx-debian13.sh
#   NETALERTX_UI_PORT=20211 NETALERTX_API_PORT=20212 ./install-netalertx-debian13.sh

#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

APP_DIR="/app"
DATA_DIR="/data"
VENV_DIR="/opt/myenv"
RUNTIME_API="/tmp/api"
RUNTIME_LOG="/tmp/log"

UI_PORT="${NETALERTX_UI_PORT:-20211}"
API_PORT="${NETALERTX_API_PORT:-20212}"
REPO_URL="${NETALERTX_REPO_URL:-https://github.com/netalertx/NetAlertX.git}"
REPO_BRANCH="${NETALERTX_REPO_BRANCH:-main}"

PHP_VERSION="8.4"
PHP_FPM_SERVICE="php${PHP_VERSION}-fpm"
PHP_POOL="/etc/php/${PHP_VERSION}/fpm/pool.d/www.conf"

NGINX_CONF="/etc/nginx/conf.d/netalertx.conf"
SYSTEMD_SERVICE="/etc/systemd/system/netalertx.service"
RUNTIME_SERVICE="/etc/systemd/system/netalertx-runtime.service"
TMPFILES_CONF="/etc/tmpfiles.d/netalertx.conf"
SUDOERS_CONF="/etc/sudoers.d/netalertx"
INSTALL_LOG="/var/log/netalertx-install.log"
WEB_ROOT="/var/www/html/netalertx"
SERVER_IP="127.0.0.1"

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    GREEN=$'\033[1;32m'; YELLOW=$'\033[1;33m'; RED=$'\033[1;31m'; RESET=$'\033[0m'
else
    GREEN=""; YELLOW=""; RED=""; RESET=""
fi

mkdir -p "$(dirname "$INSTALL_LOG")"
touch "$INSTALL_LOG"
exec > >(tee -a "$INSTALL_LOG") 2>&1

info(){ printf '%s[INFO]%s %s\n' "$GREEN" "$RESET" "$*"; }
warn(){ printf '%s[WARN]%s %s\n' "$YELLOW" "$RESET" "$*" >&2; }
error(){ printf '%s[ERROR]%s %s\n' "$RED" "$RESET" "$*" >&2; }
die(){ error "$*"; exit 1; }
section(){ printf '\n%s\n%s\n%s\n' '======================================================================' "$*" '======================================================================'; }

on_error(){
    local rc=$?
    local line="${1:-unknown}"
    error "Falha na linha ${line}, código ${rc}."
    error "Log completo: ${INSTALL_LOG}"
    exit "$rc"
}
trap 'on_error $LINENO' ERR

require_root(){ [ "$EUID" -eq 0 ] || die 'Execute este script como root.'; }

check_os(){
    section 'VALIDANDO SISTEMA OPERACIONAL'
    [ -r /etc/os-release ] || die '/etc/os-release não encontrado.'
    # shellcheck disable=SC1091
    . /etc/os-release
    [ "${ID:-}" = debian ] || die "Debian 13 requerido. Encontrado: ${ID:-unknown}."
    [[ "${VERSION_ID:-}" == 13* ]] || die "Debian 13 requerido. Encontrado: ${VERSION_ID:-unknown}."
    info "Debian ${VERSION_ID} (${VERSION_CODENAME:-trixie})."
}

check_arch(){
    local arch
    arch="$(dpkg --print-architecture)"
    case "$arch" in
        amd64|arm64) info "Arquitetura: $arch" ;;
        *) die "Arquitetura não suportada: $arch" ;;
    esac
}

validate_ports(){
    section 'VALIDANDO PORTAS'
    [[ "$UI_PORT" =~ ^[0-9]+$ ]] || die 'UI_PORT inválida.'
    [[ "$API_PORT" =~ ^[0-9]+$ ]] || die 'API_PORT inválida.'
    (( UI_PORT >= 1 && UI_PORT <= 65535 )) || die 'UI_PORT fora do intervalo.'
    (( API_PORT >= 1 && API_PORT <= 65535 )) || die 'API_PORT fora do intervalo.'
    [ "$UI_PORT" != "$API_PORT" ] || die 'As portas Web e API devem ser diferentes.'
    if ss -lnt 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${UI_PORT}$"; then warn "Porta ${UI_PORT} já está em uso."; fi
    if ss -lnt 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${API_PORT}$"; then warn "Porta ${API_PORT} já está em uso."; fi
}

detect_ip(){
    SERVER_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' || true)"
    SERVER_IP="${SERVER_IP:-$(hostname -I 2>/dev/null | awk '{print $1}' || true)}"
    SERVER_IP="${SERVER_IP:-127.0.0.1}"
    info "IP detectado: ${SERVER_IP}"
}

check_layout(){
    section 'VALIDANDO LAYOUT DO FILESYSTEM'
    [ ! -L "$APP_DIR" ] || die "$APP_DIR é um symlink. Abortando."
    mountpoint -q "$APP_DIR" 2>/dev/null && die "$APP_DIR é um mount point. Abortando."
    [ ! -L "$DATA_DIR" ] || die "$DATA_DIR é um symlink. Abortando."
}

confirm_install(){
    [ -n "${NETALERTX_ASSUME_YES:-}" ] && return
    warn "O conteúdo de ${APP_DIR} será removido e recriado."
    warn 'NGINX, PHP-FPM e systemd serão configurados.'
    read -r -p 'Continuar? [y/N]: ' answer
    case "$answer" in y|Y|yes|YES) ;; *) die 'Instalação cancelada.' ;; esac
}

install_packages(){
    section 'INSTALANDO DEPENDÊNCIAS'
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y \
        ca-certificates curl git sudo qemu-guest-agent nginx sqlite3 cron \
        iproute2 net-tools iptraf-ng dnsutils nmap fping mtr traceroute nbtscan \
        arp-scan snmp libwww-perl perl usbutils avahi-daemon avahi-utils \
        build-essential python3 python3-dev python3-venv python3-pip \
        python3-psutil zip lsb-release
    apt-get install -y php8.4 php8.4-cgi php8.4-fpm php8.4-sqlite3 php8.4-curl
    systemctl enable "$PHP_FPM_SERVICE" nginx
}

stop_old(){
    section 'PARANDO SERVIÇOS ANTERIORES'
    systemctl stop netalertx.service 2>/dev/null || true
    systemctl disable netalertx.service 2>/dev/null || true
    systemctl stop netalertx-runtime.service 2>/dev/null || true
    systemctl disable netalertx-runtime.service 2>/dev/null || true
    pkill -f '/app/server/' 2>/dev/null || true
}

unmount_if_needed(){
    local p="$1"
    if mountpoint -q "$p" 2>/dev/null; then
        info "Desmontando $p"
        umount "$p"
    fi
}

prepare_app(){
    section "PREPARANDO ${APP_DIR}"
    unmount_if_needed "${APP_DIR}/api"
    unmount_if_needed "${APP_DIR}/log"
    unmount_if_needed "$RUNTIME_API"
    unmount_if_needed "$RUNTIME_LOG"
    rm -rf --one-file-system "$APP_DIR"
    mkdir -p "$APP_DIR"
}

clone_repo(){
    section 'BAIXANDO NETALERTX'
    git clone --depth 1 --branch "$REPO_BRANCH" "$REPO_URL" "$APP_DIR"
    [ -d "$APP_DIR/server" ] || die '/app/server não encontrado.'
    [ -d "$APP_DIR/front" ] || die '/app/front não encontrado.'
    [ -d "$APP_DIR/back" ] || die '/app/back não encontrado.'
    [ -f "$APP_DIR/requirements.txt" ] || die '/app/requirements.txt não encontrado.'

    # O repositório pode trazer links Docker:
    # /app/api -> /tmp/api
    # /app/log -> /tmp/log
    # Removemos os links antes de criar os diretórios para evitar:
    # mkdir: cannot create directory '/app/api': File exists
    for p in "$APP_DIR/api" "$APP_DIR/log"; do
        if [ -L "$p" ]; then
            info "Removendo symlink $p -> $(readlink "$p")"
            rm -f "$p"
        elif [ -e "$p" ] && [ ! -d "$p" ]; then
            rm -f "$p"
        fi
    done
    mkdir -p "$APP_DIR/api" "$APP_DIR/log"
}

install_python(){
    section 'CONFIGURANDO PYTHON'
    rm -rf "$VENV_DIR"
    python3 -m venv "$VENV_DIR"
    "$VENV_DIR/bin/python" -m pip install --upgrade pip setuptools wheel
    "$VENV_DIR/bin/python" -m pip install -r "$APP_DIR/requirements.txt"
    # Compatibilidade com branches que ainda omitem pydantic.
    "$VENV_DIR/bin/python" -m pip install 'pydantic>=2,<3'
    "$VENV_DIR/bin/python" <<'PY'
import importlib
for module in ('requests','psutil','pydantic','flask','graphene','aiohttp','scapy'):
    importlib.import_module(module)
print('Python dependency check: OK')
PY
}

prepare_data(){
    section 'PREPARANDO DADOS'
    mkdir -p "$APP_DIR/config" "$APP_DIR/db"
    if [ -f "$APP_DIR/back/app.conf" ]; then cp -f "$APP_DIR/back/app.conf" "$APP_DIR/config/app.conf"; else touch "$APP_DIR/config/app.conf"; fi
    if [ -f "$APP_DIR/back/app.db" ]; then cp -f "$APP_DIR/back/app.db" "$APP_DIR/db/app.db"; else touch "$APP_DIR/db/app.db"; fi
    mkdir -p "$DATA_DIR"
    rm -rf "$DATA_DIR/config" "$DATA_DIR/db" "$DATA_DIR/api" "$DATA_DIR/log"
    ln -s "$APP_DIR/config" "$DATA_DIR/config"
    ln -s "$APP_DIR/db" "$DATA_DIR/db"
    ln -s "$RUNTIME_API" "$DATA_DIR/api"
    ln -s "$RUNTIME_LOG" "$DATA_DIR/log"
}

prepare_runtime(){
    section 'CRIANDO RUNTIME'
    mkdir -p "$RUNTIME_API" "$RUNTIME_LOG/plugins"
    touch "$RUNTIME_LOG/app.log" "$RUNTIME_LOG/execution_queue.log" \
          "$RUNTIME_LOG/app_front.log" "$RUNTIME_LOG/app.php_errors.log" \
          "$RUNTIME_LOG/stderr.log" "$RUNTIME_LOG/stdout.log" \
          "$RUNTIME_LOG/db_is_locked.log" "$RUNTIME_API/user_notifications.json"
    chown -R www-data:www-data "$RUNTIME_API" "$RUNTIME_LOG"
    chmod 0770 "$RUNTIME_API" "$RUNTIME_LOG" "$RUNTIME_LOG/plugins"
    chmod -R ug+rwX,o-rwx "$RUNTIME_API" "$RUNTIME_LOG"
}

configure_tmpfiles(){
    section 'CONFIGURANDO TMPFILES'
    cat > "$TMPFILES_CONF" <<EOF2
d /tmp/api 0770 www-data www-data -
d /tmp/log 0770 www-data www-data -
d /tmp/log/plugins 0770 www-data www-data -
EOF2
    systemd-tmpfiles --create "$TMPFILES_CONF"
}

configure_php(){
    section 'CONFIGURANDO PHP-FPM'
    [ -f "$PHP_POOL" ] || die "Pool PHP-FPM não encontrado: $PHP_POOL"
    cp -a "$PHP_POOL" "${PHP_POOL}.netalertx.$(date +%s).bak"
    sed -i '/^[[:space:]]*env\[NETALERTX_/d;/^[[:space:]]*env\[PORT\]/d;/^[[:space:]]*env\[GRAPHQL_PORT\]/d' "$PHP_POOL"
    cat >> "$PHP_POOL" <<EOF2

; NetAlertX bare-metal
env[NETALERTX_APP] = /app
env[NETALERTX_DATA] = /data
env[NETALERTX_TMP] = /tmp
env[NETALERTX_CONFIG] = /app/config
env[NETALERTX_DB] = /app/db
env[NETALERTX_DB_FILE] = /app/db/app.db
env[NETALERTX_API] = /tmp/api
env[NETALERTX_LOG] = /tmp/log
env[NETALERTX_FRONT] = /app/front
env[NETALERTX_SERVER] = /app/server
env[NETALERTX_BACK] = /app/back
env[PORT] = ${UI_PORT}
env[GRAPHQL_PORT] = ${API_PORT}
EOF2
    /usr/sbin/php-fpm8.4 -t
    systemctl restart "$PHP_FPM_SERVICE"
}

configure_arp_scan(){
    section 'CONFIGURANDO ARP-SCAN'
    cat > "$SUDOERS_CONF" <<'EOF2'
www-data ALL=(root) NOPASSWD: /usr/sbin/arp-scan
EOF2
    chmod 0440 "$SUDOERS_CONF"
    /usr/sbin/visudo -c -f "$SUDOERS_CONF"
}

configure_nginx(){
    section 'CONFIGURANDO NGINX'
    systemctl stop nginx 2>/dev/null || true
    rm -f /etc/nginx/sites-enabled/default
    rm -rf "$WEB_ROOT"
    mkdir -p /var/www/html
    ln -s "$APP_DIR/front" "$WEB_ROOT"

    cat > "$NGINX_CONF" <<EOF2
server {
    listen ${UI_PORT};
    listen [::]:${UI_PORT};
    server_name _;
    root ${APP_DIR}/front;
    index index.php;
    client_max_body_size 100M;

    location /server/ {
        proxy_pass http://127.0.0.1:${API_PORT}/;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 300;
    }

    location /api/ {
        proxy_pass http://127.0.0.1:${API_PORT}/;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 300;
    }

    location ~ \.php\$ {
        try_files \$uri =404;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_pass unix:/run/php/php8.4-fpm.sock;
    }

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }
}
EOF2

    /usr/sbin/nginx -t
    systemctl enable nginx
    systemctl start nginx
}

# =====================================================================
# PERMISSÕES DE RUNTIME DO NETALERTX
# =====================================================================

configure_permissions(){
    section 'CONFIGURANDO PERMISSÕES'

    info "Ajustando permissões de runtime do NetAlertX..."

    # -----------------------------------------------------------------
    # /app
    # -----------------------------------------------------------------
    # O código da aplicação permanece pertencendo ao root.
    # www-data não precisa escrever diretamente em /app.
    chown root:root /app
    chmod 0755 /app

    # -----------------------------------------------------------------
    # Diretórios que precisam ser graváveis pelo NetAlertX
    # -----------------------------------------------------------------
    local runtime_dirs=(
        "/app/config"
        "/app/db"
        "/app/front"
        "/app/api"
        "/app/log"
        "/tmp/api"
        "/tmp/log"
        "/tmp/log/plugins"
    )

    local dir

    for dir in "${runtime_dirs[@]}"; do
        if [ ! -d "$dir" ]; then
            info "Criando diretório: $dir"
            mkdir -p "$dir"
        fi

        chown -R www-data:www-data "$dir"
        chmod 0770 "$dir"
    done

    # -----------------------------------------------------------------
    # Arquivo de versão
    # -----------------------------------------------------------------
    if [ ! -e "/app/.VERSION" ]; then
        touch "/app/.VERSION"
    fi

    chown www-data:www-data "/app/.VERSION"
    chmod 0664 "/app/.VERSION"

    # -----------------------------------------------------------------
    # Timestamp do frontend
    # -----------------------------------------------------------------
    if [ ! -e "/app/front/buildtimestamp.txt" ]; then
        touch "/app/front/buildtimestamp.txt"
    fi

    chown www-data:www-data "/app/front/buildtimestamp.txt"
    chmod 0664 "/app/front/buildtimestamp.txt"

    # -----------------------------------------------------------------
    # Runtime temporário
    # -----------------------------------------------------------------
    mkdir -p \
        /tmp/api \
        /tmp/log \
        /tmp/log/plugins

    chown -R www-data:www-data \
        /tmp/api \
        /tmp/log

    chmod 0770 \
        /tmp/api \
        /tmp/log \
        /tmp/log/plugins

    # -----------------------------------------------------------------
    # Teste de escrita
    # -----------------------------------------------------------------
    info "Validando permissões de escrita..."

    local test_file

    test_file="/app/config/.netalertx_permission_test"

    if ! sudo -u www-data sh -c "echo test > '$test_file'"; then
        error "www-data não consegue escrever em /app/config"
        return 1
    fi

    rm -f "$test_file"

    test_file="/app/db/.netalertx_permission_test"

    if ! sudo -u www-data sh -c "echo test > '$test_file'"; then
        error "www-data não consegue escrever em /app/db"
        return 1
    fi

    rm -f "$test_file"

    test_file="/app/front/.netalertx_permission_test"

    if ! sudo -u www-data sh -c "echo test > '$test_file'"; then
        error "www-data não consegue escrever em /app/front"
        return 1
    fi

    rm -f "$test_file"

    test_file="/tmp/api/.netalertx_permission_test"

    if ! sudo -u www-data sh -c "echo test > '$test_file'"; then
        error "www-data não consegue escrever em /tmp/api"
        return 1
    fi

    rm -f "$test_file"

    test_file="/tmp/log/.netalertx_permission_test"

    if ! sudo -u www-data sh -c "echo test > '$test_file'"; then
        error "www-data não consegue escrever em /tmp/log"
        return 1
    fi

    rm -f "$test_file"

    info "Permissões de runtime validadas com sucesso."
}


create_start_script(){
    section 'CRIANDO START SCRIPT'
    cat > "$APP_DIR/start.netalertx.sh" <<EOF2
#!/usr/bin/env bash
set -Eeuo pipefail
export NETALERTX_APP="/app"
export NETALERTX_DATA="/data"
export NETALERTX_TMP="/tmp"
export NETALERTX_CONFIG="/app/config"
export NETALERTX_DB="/app/db"
export NETALERTX_DB_FILE="/app/db/app.db"
export NETALERTX_API="/tmp/api"
export NETALERTX_LOG="/tmp/log"
export NETALERTX_FRONT="/app/front"
export NETALERTX_SERVER="/app/server"
export NETALERTX_BACK="/app/back"
export LISTEN_ADDR="127.0.0.1"
export PORT="${UI_PORT}"
export GRAPHQL_PORT="${API_PORT}"
export PYTHONUNBUFFERED="1"
export PYTHONPATH="/app:/app/server"
cd /app
exec /opt/myenv/bin/python /app/server/
EOF2
    chown root:www-data "$APP_DIR/start.netalertx.sh"
    chmod 0750 "$APP_DIR/start.netalertx.sh"
    [ -x "$APP_DIR/start.netalertx.sh" ] || die 'start.netalertx.sh não foi criado corretamente.'
}

create_runtime_service(){
    section 'CRIANDO SERVIÇO DE RUNTIME'
    cat > "$RUNTIME_SERVICE" <<'EOF2'
[Unit]
Description=NetAlertX Runtime Directories
After=local-fs.target
Before=netalertx.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/systemd-tmpfiles --create /etc/tmpfiles.d/netalertx.conf
ExecStart=/bin/bash -c 'mkdir -p /tmp/api /tmp/log/plugins'
ExecStart=/bin/bash -c 'chown -R www-data:www-data /tmp/api /tmp/log'
ExecStart=/bin/bash -c 'chmod 0770 /tmp/api /tmp/log /tmp/log/plugins'
ExecStop=/bin/true

[Install]
WantedBy=multi-user.target
EOF2
    systemctl daemon-reload
    systemctl enable netalertx-runtime.service
    systemctl start netalertx-runtime.service
}

create_service(){
    section 'CRIANDO SERVIÇO NETALERTX'
    cat > "$SYSTEMD_SERVICE" <<EOF2
[Unit]
Description=NetAlertX Network Discovery
Wants=network-online.target
After=network-online.target netalertx-runtime.service ${PHP_FPM_SERVICE}.service nginx.service
Requires=netalertx-runtime.service

[Service]
Type=simple
User=www-data
Group=www-data

WorkingDirectory=/app

Environment="PATH=/opt/myenv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

Environment=NETALERTX_APP=/app
Environment=NETALERTX_DATA=/data
Environment=NETALERTX_TMP=/tmp
Environment=NETALERTX_CONFIG=/app/config
Environment=NETALERTX_DB=/app/db
Environment=NETALERTX_DB_FILE=/app/db/app.db
Environment=NETALERTX_API=/tmp/api
Environment=NETALERTX_LOG=/tmp/log
Environment=NETALERTX_FRONT=/app/front
Environment=NETALERTX_SERVER=/app/server
Environment=NETALERTX_BACK=/app/back
Environment=LISTEN_ADDR=127.0.0.1
Environment=PORT=20211
Environment=GRAPHQL_PORT=20212
Environment=PYTHONUNBUFFERED=1
Environment=PYTHONPATH=/app:/app/server

ExecStart=/app/start.netalertx.sh

Restart=on-failure
RestartSec=5
TimeoutStartSec=120
TimeoutStopSec=30

PrivateTmp=false

StandardOutput=journal
StandardError=journal
Restart=on-failure
RestartSec=5
TimeoutStartSec=120
TimeoutStopSec=30
NoNewPrivileges=false
PrivateTmp=false
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF2
    [ -x "$APP_DIR/start.netalertx.sh" ] || die 'ExecStart inválido: start.netalertx.sh não existe.'
    systemctl daemon-reload
    systemctl enable netalertx.service
}

update_vendors(){
    section 'ATUALIZANDO VENDEDORES OUI'
    if [ -x "$APP_DIR/back/update_vendors.sh" ]; then
        "$APP_DIR/back/update_vendors.sh" || warn 'Falha ao atualizar vendors. Continuando.'
    else
        warn 'update_vendors.sh não encontrado. Continuando.'
    fi
}

start_services(){
    section 'INICIANDO SERVIÇOS'
    systemctl restart netalertx-runtime.service
    systemctl restart "$PHP_FPM_SERVICE"
    /usr/sbin/nginx -t
    systemctl reload nginx
    systemctl restart netalertx.service
}

wait_for_api(){
    local i
    local listen_ok=0

    for i in $(seq 1 30); do
        if ss -lntp 2>/dev/null | grep -Eq ":${API_PORT}[[:space:]]"; then
            listen_ok=1
            break
        fi

        sleep 1
    done

    if [ "$listen_ok" -eq 1 ]; then
        info "API escutando na porta ${API_PORT}."

        # Teste HTTP do GraphQL/API.
        # Não exigimos HTTP 200, pois o endpoint pode responder
        # 400/405 dependendo da rota e do método utilizado.
        if curl -sS \
            --max-time 10 \
            -o /dev/null \
            "http://127.0.0.1:${API_PORT}/" \
            2>/dev/null; then

            info "API respondeu HTTP."
            return 0
        fi

        # A porta está aberta mesmo que a rota / não aceite GET.
        warn "API está escutando, mas não respondeu ao GET /."
        return 0
    fi

    error "API não abriu a porta ${API_PORT}."

    journalctl \
        -u netalertx.service \
        -n 150 \
        --no-pager || true

    return 1
}

health_check(){
    section 'HEALTH CHECK'
    local failed=0

    for service in "$PHP_FPM_SERVICE" nginx netalertx-runtime netalertx; do
        if systemctl is-active --quiet "$service"; then
            info "${service}: ACTIVE"
        else
            error "${service}: INACTIVE"
            systemctl status "$service" --no-pager -l || true
            failed=1
        fi
    done

    [ -x "$APP_DIR/start.netalertx.sh" ] || { error 'start.netalertx.sh ausente.'; failed=1; }
    [ -d "$RUNTIME_API" ] && [ -w "$RUNTIME_API" ] || { error "$RUNTIME_API não gravável."; failed=1; }
    [ -d "$RUNTIME_LOG" ] && [ -w "$RUNTIME_LOG" ] || { error "$RUNTIME_LOG não gravável."; failed=1; }

    if [ -L "$DATA_DIR/config" ] && [ -L "$DATA_DIR/db" ] && [ -L "$DATA_DIR/api" ] && [ -L "$DATA_DIR/log" ]; then
        info '/data mappings: OK'
    else
        error '/data mappings: FAILED'
        failed=1
    fi

    wait_for_api || failed=1

if curl -sS \
    --max-time 10 \
    -o /dev/null \
    "http://127.0.0.1:${UI_PORT}/"; then

    info "HTTP UI: OK"

else
    warn "HTTP UI não respondeu."

    if ss -lnt 2>/dev/null | grep -Eq ":${UI_PORT}[[:space:]]"; then
        warn "A porta ${UI_PORT} está aberta, mas a requisição HTTP falhou."
    fi

    failed=1
fi

    echo
    if [ "$failed" -eq 0 ]; then
        chown -R www-data:www-data /app/
        printf '%s\n' '======================================================================'
        printf '%s\n' "${GREEN}NETALERTX INSTALADO COM SUCESSO${RESET}"
        printf '%s\n' '======================================================================'
        echo "Web : http://${SERVER_IP}:${UI_PORT}"
        echo "API : http://${SERVER_IP}:${API_PORT}"
        echo "Serviço: systemctl status netalertx"
        echo "Logs   : journalctl -u netalertx -f"
        echo "Install log: ${INSTALL_LOG}"
        return 0
    fi

    printf '%s\n' '======================================================================'
    printf '%s\n' "${RED}HEALTH CHECK FALHOU${RESET}"
    printf '%s\n' '======================================================================'
    echo 'Execute:'
    echo '  systemctl status netalertx --no-pager -l'
    echo '  journalctl -u netalertx -n 150 --no-pager'
    return 1
}

main(){
    section 'NETALERTX - INSTALADOR DEBIAN 13'

    require_root
    check_os
    check_arch
    validate_ports
    detect_ip
    check_layout
    confirm_install
    install_packages
    stop_old
    prepare_app
    clone_repo
    install_python
    prepare_data
    prepare_runtime
    configure_tmpfiles
    configure_php
    configure_arp_scan
    configure_nginx
    configure_permissions
    create_start_script
    create_runtime_service
    create_service
    update_vendors
    start_services
    health_check
}

main "$@"
