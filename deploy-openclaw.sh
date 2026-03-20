#!/bin/bash
# OpenClaw + Cloudflare Tunnel 隐私部署脚本 v3.1
# 支持 macOS + Linux (Ubuntu/Debian/CentOS/RHEL/Fedora)
#
# 特性:
#   ✅ 真实 IP 完全隐藏
#   ✅ 零公网端口暴露
#   ✅ 跨平台: macOS (launchd) + Linux (systemd)
#   ✅ 可选 Cloudflare Access (Zero Trust)
#   ✅ 安全加固: Token 文件存储 / 日志权限 600 / DNS 备份恢复
#
# 用法: ./deploy-openclaw.sh [选项]

set -e
set -o pipefail

# ========== 全局配置 ==========
readonly SCRIPT_VERSION="3.1.0"
readonly SCRIPT_NAME="deploy-openclaw.sh"
readonly DEFAULT_PORT=10371
readonly TUNNEL_NAME="openclaw-tunnel"
readonly TIMESTAMP=$(date +%Y%m%d-%H%M%S)

# 颜色定义
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly PURPLE='\033[0;35m'
readonly CYAN='\033[0;36m'
readonly WHITE='\033[1;37m'
readonly NC='\033[0m'

# ========== OS 抽象层 ==========

detect_os() {
    OS_NAME=""
    OS_VERSION=""
    OS_FAMILY=""
    PKG_MANAGER=""

    if [[ "$(uname)" == "Darwin" ]]; then
        OS_NAME="macos"
        OS_VERSION=$(sw_vers -productVersion)
        OS_FAMILY="macos"
        PKG_MANAGER="brew"
    elif [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS_NAME="${ID:-unknown}"
        OS_VERSION="${VERSION_ID:-unknown}"
        case "$ID" in
            ubuntu|debian|linuxmint|pop)  OS_FAMILY="debian"; PKG_MANAGER="apt" ;;
            centos|rhel|rocky|almalinux|ol|amzn) OS_FAMILY="rhel"; PKG_MANAGER="yum" ;;
            fedora)                        OS_FAMILY="fedora"; PKG_MANAGER="dnf" ;;
            arch|manjaro)                  OS_FAMILY="arch"; PKG_MANAGER="pacman" ;;
            *)                             OS_FAMILY="unknown" ;;
        esac
    else
        OS_NAME=$(uname -s | tr '[:upper:]' '[:lower:]')
        OS_VERSION=$(uname -r)
        OS_FAMILY="unknown"
    fi
}

pkg_install() {
    local pkg="$1"
    case "$PKG_MANAGER" in
        brew)   brew install "$pkg" >> "$LOG_FILE" 2>&1 ;;
        apt)    sudo apt-get install -y "$pkg" >> "$LOG_FILE" 2>&1 ;;
        yum)    sudo yum install -y "$pkg" >> "$LOG_FILE" 2>&1 ;;
        dnf)    sudo dnf install -y "$pkg" >> "$LOG_FILE" 2>&1 ;;
        pacman) sudo pacman -S --noconfirm "$pkg" >> "$LOG_FILE" 2>&1 ;;
        *)      error "不支持的包管理器: $PKG_MANAGER" ;;
    esac
}

install_cloudflared() {
    if command -v cloudflared &>/dev/null; then
        local ver=$(cloudflared --version 2>/dev/null | awk '{print $2}')
        success "✓ cloudflared $ver 已安装"
        return 0
    fi
    info "安装 cloudflared..."
    case "$OS_FAMILY" in
        macos)
            pkg_install "cloudflare/cloudflare/cloudflared"
            ;;
        debian)
            curl -fsSL https://pkg.cloudflare.com/cloudflared/gpg-key | sudo gpg --dearmor -o /usr/share/keyrings/cloudflare-main.gpg 2>> "$LOG_FILE"
            echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared $(lsb_release -cs 2>/dev/null || echo focal) main" | sudo tee /etc/apt/sources.list.d/cloudflared.list >> "$LOG_FILE" 2>&1
            sudo apt-get update >> "$LOG_FILE" 2>&1
            sudo apt-get install -y cloudflared >> "$LOG_FILE" 2>&1
            ;;
        rhel|fedora)
            local arch=$(uname -m)
            local rpm_url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arch}.rpm"
            sudo rpm -i "$rpm_url" >> "$LOG_FILE" 2>&1 || sudo yum install -y "$rpm_url" >> "$LOG_FILE" 2>&1
            ;;
        *)
            local arch=$(uname -m)
            case "$arch" in x86_64|amd64) arch="amd64" ;; aarch64|arm64) arch="arm64" ;; armv7l) arch="arm" ;; *) error "不支持的架构: $arch" ;; esac
            sudo curl -fsSL "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arch}" -o /usr/local/bin/cloudflared
            sudo chmod +x /usr/local/bin/cloudflared
            ;;
    esac
    command -v cloudflared &>/dev/null || error "cloudflared 安装失败"
    local ver=$(cloudflared --version 2>/dev/null | awk '{print $2}')
    success "✓ cloudflared $ver 安装成功"
}

install_nodejs() {
    if command -v node &>/dev/null; then
        local ver=$(node --version 2>/dev/null | cut -d'v' -f2)
        if [ "$(printf '%s\n' "18" "$ver" | sort -V | head -n1)" = "18" ]; then
            success "✓ Node.js $ver 已安装"
            return 0
        fi
        warn "⚠️  Node.js $ver < 18，需要升级"
    fi
    info "安装 Node.js 20..."
    case "$OS_FAMILY" in
        macos)  pkg_install "node" ;;
        debian)
            curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash - >> "$LOG_FILE" 2>&1
            sudo apt-get install -y nodejs >> "$LOG_FILE" 2>&1
            ;;
        rhel|fedora)
            curl -fsSL https://rpm.nodesource.com/setup_20.x | sudo bash - >> "$LOG_FILE" 2>&1
            sudo yum install -y nodejs >> "$LOG_FILE" 2>&1
            ;;
        *)  warn "⚠️  请手动安装 Node.js 18+" && return 1 ;;
    esac
    command -v node &>/dev/null || error "Node.js 安装失败"
    local ver=$(node --version 2>/dev/null | cut -d'v' -f2)
    success "✓ Node.js $ver 安装成功"
}

check_system_compat() {
    info "系统: $OS_NAME $OS_VERSION ($OS_FAMILY) | 包管理: $PKG_MANAGER"
    case "$OS_FAMILY" in
        macos)
            [ "$(printf '%s\n' "11.0" "$OS_VERSION" | sort -V | head -n1)" != "11.0" ] && warn "⚠️  建议 macOS 11.0+"
            ;;
        *)
            command -v sudo &>/dev/null || error "Linux 部署需要 sudo"
            ;;
    esac
}

# ========== 服务管理抽象 ==========

find_openclaw_bin() { command -v openclaw 2>/dev/null || echo "/usr/local/bin/openclaw"; }

install_openclaw() {
    info "安装 OpenClaw CLI..."
    if command -v openclaw &>/dev/null; then
        local ver=$(openclaw --version 2>/dev/null | head -n1)
        info "已安装 OpenClaw $ver"
        read -p "更新到最新版? (y/n): " -n 1 -r; echo
        [[ ! $REPLY =~ ^[Yy]$ ]] && return 0
    fi
    if [[ "$OS_FAMILY" != "macos" ]] && [[ ! -w "$(npm root -g 2>/dev/null)" ]]; then
        sudo npm install -g openclaw@latest >> "$LOG_FILE" 2>&1
    else
        npm install -g openclaw@latest >> "$LOG_FILE" 2>&1
    fi
    local ver=$(openclaw --version 2>/dev/null | head -n1)
    success "✓ OpenClaw $ver 安装成功"
}

service_install() {
    local oc_bin=$(find_openclaw_bin)
    case "$OS_FAMILY" in
        macos) _install_launchd "$oc_bin" ;;
        *)     _install_systemd "$oc_bin" ;;
    esac
}

service_uninstall() {
    case "$OS_FAMILY" in
        macos) _uninstall_launchd ;;
        *)     _uninstall_systemd ;;
    esac
}

service_start() {
    case "$OS_FAMILY" in
        macos)
            launchctl start ai.openclaw.gateway 2>/dev/null || true
            launchctl start com.cloudflare.cloudflared 2>/dev/null || true
            ;;
        *)
            sudo systemctl start openclaw-gateway 2>/dev/null || true
            sudo systemctl start cloudflared-tunnel 2>/dev/null || true
            ;;
    esac
}

service_stop() {
    case "$OS_FAMILY" in
        macos)
            launchctl stop ai.openclaw.gateway 2>/dev/null || true
            launchctl stop com.cloudflare.cloudflared 2>/dev/null || true
            launchctl unload "$HOME/Library/LaunchAgents/ai.openclaw.gateway.plist" 2>/dev/null || true
            launchctl unload "$HOME/Library/LaunchAgents/com.cloudflare.cloudflared.plist" 2>/dev/null || true
            ;;
        *)
            sudo systemctl stop openclaw-gateway 2>/dev/null || true
            sudo systemctl stop cloudflared-tunnel 2>/dev/null || true
            sudo systemctl disable openclaw-gateway 2>/dev/null || true
            sudo systemctl disable cloudflared-tunnel 2>/dev/null || true
            ;;
    esac
}

_install_launchd() {
    local oc_bin="$1"
    local dir="$HOME/Library/LaunchAgents"
    mkdir -p "$dir"
    cat > "$dir/ai.openclaw.gateway.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>Label</key><string>ai.openclaw.gateway</string>
    <key>ProgramArguments</key><array><string>$oc_bin</string><string>gateway</string><string>start</string><string>--force</string></array>
    <key>EnvironmentVariables</key><dict><key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string></dict>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><dict><key>NetworkState</key><true/><key>SuccessfulExit</key><false/></dict>
    <key>StandardOutPath</key><string>/tmp/openclaw-gateway.log</string>
    <key>StandardErrorPath</key><string>/tmp/openclaw-gateway.err.log</string>
    <key>ThrottleInterval</key><integer>30</integer>
</dict></plist>
EOF
    cat > "$dir/com.cloudflare.cloudflared.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>Label</key><string>com.cloudflare.cloudflared</string>
    <key>ProgramArguments</key><array><string>/opt/homebrew/bin/cloudflared</string><string>tunnel</string><string>--config</string><string>$CF_CONFIG_DIR/config.yml</string><string>run</string><string>$TUNNEL_NAME</string></array>
    <key>EnvironmentVariables</key><dict><key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string></dict>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><dict><key>NetworkState</key><true/><key>SuccessfulExit</key><false/><key>Crashed</key><true/></dict>
    <key>StandardOutPath</key><string>/tmp/cloudflared.log</string>
    <key>StandardErrorPath</key><string>/tmp/cloudflared.err.log</string>
    <key>ThrottleInterval</key><integer>10</integer>
</dict></plist>
EOF
    launchctl unload "$dir/ai.openclaw.gateway.plist" 2>/dev/null || true
    launchctl load "$dir/ai.openclaw.gateway.plist"
    launchctl unload "$dir/com.cloudflare.cloudflared.plist" 2>/dev/null || true
    launchctl load "$dir/com.cloudflare.cloudflared.plist"
}

_uninstall_launchd() {
    rm -f "$HOME/Library/LaunchAgents/ai.openclaw.gateway.plist"
    rm -f "$HOME/Library/LaunchAgents/com.cloudflare.cloudflared.plist"
}

_install_systemd() {
    local oc_bin="$1"
    local cf_bin=$(command -v cloudflared 2>/dev/null || echo "/usr/local/bin/cloudflared")
    sudo tee /etc/systemd/system/openclaw-gateway.service > /dev/null <<EOF
[Unit]
Description=OpenClaw Gateway
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
ExecStart=$oc_bin gateway start --force
Restart=on-failure
RestartSec=10
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
NoNewPrivileges=true
ReadWritePaths=$HOME/.openclaw /tmp
[Install]
WantedBy=multi-user.target
EOF
    sudo tee /etc/systemd/system/cloudflared-tunnel.service > /dev/null <<EOF
[Unit]
Description=Cloudflare Tunnel
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
ExecStart=$cf_bin tunnel --config $CF_CONFIG_DIR/config.yml run $TUNNEL_NAME
Restart=on-failure
RestartSec=10
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
NoNewPrivileges=true
ReadWritePaths=$CF_CONFIG_DIR /tmp
[Install]
WantedBy=multi-user.target
EOF
    sudo systemctl daemon-reload
    sudo systemctl enable openclaw-gateway
    sudo systemctl enable cloudflared-tunnel
}

_uninstall_systemd() {
    sudo systemctl stop openclaw-gateway 2>/dev/null || true
    sudo systemctl stop cloudflared-tunnel 2>/dev/null || true
    sudo systemctl disable openclaw-gateway 2>/dev/null || true
    sudo systemctl disable cloudflared-tunnel 2>/dev/null || true
    sudo rm -f /etc/systemd/system/openclaw-gateway.service
    sudo rm -f /etc/systemd/system/cloudflared-tunnel.service
    sudo systemctl daemon-reload 2>/dev/null || true
}

# ========== DNS 抽象 ==========

dns_backup() {
    local backup_file="$OC_CONFIG_DIR/.dns_backup"
    case "$OS_FAMILY" in
        macos)
            local iface=$(networksetup -listnetworkserviceorder | grep "$(route get default 2>/dev/null | grep interface | awk '{print $2}')" | head -1 | sed 's/.*Port: \(.*\),.*/\1/')
            if [ -n "$iface" ]; then
                echo "macos" > "$backup_file"
                echo "$iface" >> "$backup_file"
                networksetup -getdnsservers "$iface" 2>/dev/null >> "$backup_file" || echo "Empty" >> "$backup_file"
                chmod 600 "$backup_file"
                info "DNS 已备份 ($iface)"
            fi
            ;;
        *)
            if [ -f /etc/resolv.conf ]; then
                echo "linux" > "$backup_file"
                cp /etc/resolv.conf "$OC_CONFIG_DIR/.resolv.conf.bak"
                chmod 600 "$backup_file" "$OC_CONFIG_DIR/.resolv.conf.bak"
                info "DNS 已备份"
            fi
            ;;
    esac
}

dns_set_doh() {
    info "配置 DNS (1.1.1.1 / 1.0.0.1)..."
    case "$OS_FAMILY" in
        macos)
            local iface=$(networksetup -listnetworkserviceorder | grep "$(route get default 2>/dev/null | grep interface | awk '{print $2}')" | head -1 | sed 's/.*Port: \(.*\),.*/\1/')
            [ -n "$iface" ] && networksetup -setdnsservers "$iface" 1.1.1.1 1.0.0.1 2>/dev/null && success "✓ DNS 已设置" || warn "⚠️  DNS 设置失败"
            ;;
        *)
            if command -v resolvectl &>/dev/null; then
                local iface=$(ip route 2>/dev/null | awk '/default/ {print $5; exit}')
                [ -n "$iface" ] && sudo resolvectl dns "$iface" 1.1.1.1 1.0.0.1 2>/dev/null && success "✓ DNS (resolvectl)" || warn "⚠️  resolvectl 失败"
            else
                sudo tee /etc/resolv.conf > /dev/null <<'EOF'
nameserver 1.1.1.1
nameserver 1.0.0.1
options edns0
EOF
                success "✓ DNS (/etc/resolv.conf)"
                warn "⚠️  NetworkManager 可能覆盖此配置"
            fi
            ;;
    esac
}

dns_restore() {
    local backup_file="$OC_CONFIG_DIR/.dns_backup"
    [ ! -f "$backup_file" ] && return 0
    local platform=$(sed -n '1p' "$backup_file")
    case "$platform" in
        macos)
            local iface=$(sed -n '2p' "$backup_file")
            local dns=$(sed -n '3p' "$backup_file")
            if [ "$dns" = "Empty" ] || [ -z "$dns" ]; then
                networksetup -setdnsservers "$iface" "Empty" 2>/dev/null && success "✓ DNS 已恢复 (DHCP)"
            else
                networksetup -setdnsservers "$iface" $dns 2>/dev/null && success "✓ DNS 已恢复"
            fi
            ;;
        linux)
            [ -f "$OC_CONFIG_DIR/.resolv.conf.bak" ] && sudo cp "$OC_CONFIG_DIR/.resolv.conf.bak" /etc/resolv.conf && success "✓ DNS 已恢复" && rm -f "$OC_CONFIG_DIR/.resolv.conf.bak"
            ;;
    esac
    rm -f "$backup_file"
}

# ========== 工具函数 ==========

log() {
    local msg="$1" level="${2:-INFO}" color="$BLUE"
    case "$level" in INFO) color="$BLUE" ;; WARN) color="$YELLOW" ;; ERROR) color="$RED" ;; SUCCESS) color="$GREEN" ;; esac
    echo -e "${color}[${level}]${NC} $msg" | tee -a "$LOG_FILE"
}
info() { log "$1" "INFO"; }
warn() { log "$1" "WARN" >&2; }
error() { log "$1" "ERROR" >&2; exit 1; }
success() { log "$1" "SUCCESS"; }

generate_secure_token() { openssl rand -hex 32 2>/dev/null || LC_ALL=C tr -dc 'a-f0-9' < /dev/urandom | head -c 64; }

banner() {
    cat <<EOF

${CYAN}╔════════════════════════════════════════════════════════════╗
║                                                            ║
║   ${GREEN}OpenClaw + Cloudflare Tunnel 部署 v$SCRIPT_VERSION${CYAN}             ║
║                                                            ║
║   ${YELLOW}$OS_NAME $OS_VERSION ($OS_FAMILY) | $PKG_MANAGER${CYAN}                    ║
║                                                            ║
╚════════════════════════════════════════════════════════════╝${NC}

EOF
}

validate_port() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] || error "端口 '$port' 无效"
    [ "$port" -lt 1024 ] || [ "$port" -gt 65535 ] && error "端口范围: 1024-65535"
    (lsof -ti ":$port" &>/dev/null || ss -tlnp 2>/dev/null | grep -q ":$port ") && error "端口 $port 已被占用"
    success "✓ 端口 $port 可用"
}

validate_domain() {
    [[ "$1" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z]{2,})+$ ]] || error "域名格式无效"
    success "✓ 域名 $1 有效"
}

# ========== 核心功能 ==========

check_dependencies() {
    info "检查依赖..."
    detect_os
    check_system_compat
    [[ "$OS_FAMILY" == "macos" ]] && { command -v brew &>/dev/null || error "需要 Homebrew"; success "✓ Homebrew"; }
    install_nodejs
    install_cloudflared
    success "依赖检查完成"
}

get_user_config() {
    echo ""
    echo -e "${GREEN}===== 配置向导 =====${NC}"
    echo ""
    if [ -z "$DOMAIN" ]; then
        while true; do
            read -p "▶ 域名 (如 claw.example.com): " DOMAIN
            [[ -z "$DOMAIN" ]] && continue
            validate_domain "$DOMAIN"; break
        done
    else
        validate_domain "$DOMAIN"
    fi
    if [ -z "$PORT" ]; then
        read -p "▶ 端口 (默认 $DEFAULT_PORT): " PORT
        PORT="${PORT:-$DEFAULT_PORT}"
    fi
    validate_port "$PORT"
    if [ -n "$OPENCLAW_TOKEN" ]; then
        TOKEN="$OPENCLAW_TOKEN"; info "使用环境变量 OPENCLAW_TOKEN"
    else
        TOKEN=$(generate_secure_token)
    fi
    mkdir -p "$OC_CONFIG_DIR"
    echo -n "$TOKEN" > "$OC_CONFIG_DIR/.auth_token"
    chmod 600 "$OC_CONFIG_DIR/.auth_token"
    success "✓ Token → $OC_CONFIG_DIR/.auth_token (600)"
    echo ""
    read -p "按 Enter 继续..."
    echo ""
}

configure_openclaw() {
    info "配置 OpenClaw..."
    mkdir -p "$OC_CONFIG_DIR"
    openclaw config set gateway.port "$PORT" >> "$LOG_FILE" 2>&1
    openclaw config set gateway.bind "loopback" >> "$LOG_FILE" 2>&1
    openclaw config set gateway.mode "local" >> "$LOG_FILE" 2>&1
    openclaw config set gateway.auth.mode "token" >> "$LOG_FILE" 2>&1
    openclaw config set gateway.auth.token "$TOKEN" >> "$LOG_FILE" 2>&1
    success "✓ 配置已写入"
    openclaw config validate >> "$LOG_FILE" 2>&1 || error "配置验证失败"
    success "✓ 配置验证通过"
    openclaw gateway stop 2>/dev/null || true
    pkill -f "openclaw.*gateway" 2>/dev/null || true
    sleep 2
    info "启动 OpenClaw..."
    openclaw gateway start --force >> "$LOG_FILE" 2>&1 || error "启动失败"
    sleep 5
    (lsof -ti "127.0.0.1:$PORT" &>/dev/null || ss -tlnp 2>/dev/null | grep -q ":$PORT ") && success "✓ OpenClaw 运行中 (127.0.0.1:$PORT)" || error "未监听"
}

configure_tunnel() {
    info "配置 Cloudflare Tunnel..."
    if [ ! -f "$HOME/.cloudflared/cert.pem" ]; then
        echo -e "${YELLOW}⚠️  需要完成 Cloudflare 认证${NC}"
        read -p "按 Enter 继续..."
        cloudflared tunnel login >> "$LOG_FILE" 2>&1 || error "认证失败"
        success "✓ 认证成功"
    else
        success "✓ 已有认证凭据"
    fi
    local tunnel_id=""
    if cloudflared tunnel list 2>/dev/null | grep -q "$TUNNEL_NAME"; then
        tunnel_id=$(cloudflared tunnel list 2>/dev/null | grep "$TUNNEL_NAME" | awk '{print $1}')
        warn "⚠️  复用隧道: $tunnel_id"
    else
        local out=$(cloudflared tunnel create "$TUNNEL_NAME" 2>&1)
        tunnel_id=$(echo "$out" | sed -n 's/.*Tunnel ID: *\([0-9a-f-]*\).*/\1/p')
        [[ -z "$tunnel_id" ]] && error "创建失败: $out"
        success "✓ 隧道创建: $tunnel_id"
    fi
    export TUNNEL_ID="$tunnel_id"
    mkdir -p "$CF_CONFIG_DIR"
    cat > "$CF_CONFIG_DIR/config.yml" <<EOF
tunnel: $tunnel_id
credentials-file: $CF_CONFIG_DIR/$tunnel_id.json
protocol: http2
ingress:
  - hostname: $DOMAIN
    service: http://127.0.0.1:$PORT
    originRequest:
      noTLSVerify: false
      httpHostHeader: $DOMAIN
      connectTimeout: 30s
      keepAliveConnections: 100
      keepAliveTimeout: 90s
  - service: http_status:404
logfile: $CF_CONFIG_DIR/tunnel.log
loglevel: info
EOF
    success "✓ Tunnel 配置已生成"
    info "配置 DNS 路由..."
    cloudflared tunnel route dns "$TUNNEL_NAME" "$DOMAIN" 2>&1 | grep -qi "already" && warn "⚠️  DNS 已存在" || success "✓ DNS 路由成功"
}

configure_cf_access() {
    [ "$NO_ACCESS" = "true" ] && info "跳过 CF Access (--no-access)" && return 0
    echo -e "${GREEN}===== Cloudflare Access =====${NC}"
    [ -z "$CF_API_TOKEN" ] && { read -s -p "▶ CF API Token: " CF_API_TOKEN; echo ""; }
    [ -z "$CF_ACCOUNT_ID" ] && read -p "▶ CF Account ID: " CF_ACCOUNT_ID
    [ -z "$ACCESS_EMAIL" ] && read -p "▶ 允许的邮箱: " ACCESS_EMAIL
    local api="https://api.cloudflare.com/client/v4"
    local auth="Authorization: Bearer $CF_API_TOKEN"
    info "创建 Access Application..."
    local resp=$(curl -s -X POST "$api/accounts/$CF_ACCOUNT_ID/access/apps" -H "$auth" -H "Content-Type: application/json" \
        -d '{"name":"OpenClaw","domain":"'"$DOMAIN"'","type":"self_hosted","session_duration":"24h","auto_redirect_to_identity":false}')
    local app_id=$(echo "$resp" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')
    local app_aud=$(echo "$resp" | sed -n 's/.*"aud":"\([^"]*\)".*/\1/p')
    [ -z "$app_id" ] && { local ex=$(curl -s "$api/accounts/$CF_ACCOUNT_ID/access/apps" -H "$auth" | sed -n 's/.*"domain":"'"$DOMAIN"'".*"id":"\([^"]*\)".*"aud":"\([^"]*\)".*/\1 \2/p'); app_id=$(echo "$ex"|awk '{print $1}'); app_aud=$(echo "$ex"|awk '{print $2}'); }
    [ -z "$app_id" ] && error "无法创建 Application"
    success "✓ Application: $app_id (AUD: $app_aud)"
    curl -s -X POST "$api/accounts/$CF_ACCOUNT_ID/access/apps/$app_id/policies" -H "$auth" -H "Content-Type: application/json" \
        -d '{"name":"Whitelist","decision":"allow","include":[{"email":{"email":"'"$ACCESS_EMAIL"'"}}]}' >> "$LOG_FILE" 2>&1
    success "✓ Policy 已创建"
    # 更新 config.yml 加入 origin JWT
    cat > "$CF_CONFIG_DIR/config.yml" <<EOF
tunnel: $TUNNEL_ID
credentials-file: $CF_CONFIG_DIR/$TUNNEL_ID.json
protocol: http2
ingress:
  - hostname: $DOMAIN
    service: http://127.0.0.1:$PORT
    originRequest:
      noTLSVerify: false
      httpHostHeader: $DOMAIN
      connectTimeout: 30s
      keepAliveConnections: 100
      keepAliveTimeout: 90s
      access:
        required: true
        teamName: "${DOMAIN%%.*}.cloudflareaccess.com"
        audTag: ["$app_aud"]
  - service: http_status:404
logfile: $CF_CONFIG_DIR/tunnel.log
loglevel: info
EOF
    success "✓ Origin JWT 验证已启用"
    echo -e "${GREEN}四层防线: Edge → Access JWT → cloudflared → OpenClaw Token${NC}"
}

verify_deployment() {
    echo -e "${GREEN}===== 部署验证 =====${NC}"
    local ok=true
    info "OpenClaw 监听..."
    (lsof -ti "127.0.0.1:$PORT" &>/dev/null || ss -tlnp 2>/dev/null | grep -q ":$PORT ") && success "✓ 运行中" || ok=false
    info "Tunnel 进程..."
    pgrep -f "cloudflared.*tunnel" &>/dev/null && success "✓ 运行中" || { sleep 10; pgrep -f "cloudflared.*tunnel" &>/dev/null && success "✓ 已启动" || { warn "⚠️  未检测到"; ok=false; }; }
    info "域名可达性..."
    local code=$(curl -s -o /dev/null -w "%{http_code}" "https://$DOMAIN" 2>/dev/null || echo "000")
    [[ "$code" =~ ^(200|301|302|401|403)$ ]] && success "✓ HTTP $code" || warn "⚠️  HTTP $code (DNS 可能需几分钟)"
    echo ""
    [ "$ok" = true ] && success "✅ 部署验证通过" || warn "⚠️  部分检查未通过"
}

uninstall() {
    echo -e "${RED}===== 卸载 =====${NC}"
    read -p "确认卸载? (y/n): " -n 1 -r; echo
    [[ ! $REPLY =~ ^[Yy]$ ]] && exit 0
    openclaw gateway stop 2>/dev/null || true
    service_stop
    service_uninstall
    openclaw config unset gateway.port 2>/dev/null || true
    openclaw config unset gateway.bind 2>/dev/null || true
    openclaw config unset gateway.auth.mode 2>/dev/null || true
    openclaw config unset gateway.auth.token 2>/dev/null || true
    rm -f "$OC_CONFIG_DIR/.auth_token" "$LOG_FILE"
    dns_restore
    read -p "卸载 OpenClaw CLI? (y/n): " -n 1 -r; echo
    [[ $REPLY =~ ^[Yy]$ ]] && { [[ "$OS_FAMILY" != "macos" ]] && ! -w "$(npm root -g 2>/dev/null)" && sudo npm uninstall -g openclaw || npm uninstall -g openclaw; } 2>/dev/null || true
    read -p "删除 Cloudflare Tunnel? (y/n): " -n 1 -r; echo
    [[ $REPLY =~ ^[Yy]$ ]] && { local tid=$(cloudflared tunnel list 2>/dev/null | grep "$TUNNEL_NAME" | awk '{print $1}'); [ -n "$tid" ] && cloudflared tunnel delete "$tid"; rm -rf "$HOME/.cloudflared"; } 2>/dev/null || true
    read -p "删除 CF DNS 记录? (y/n): " -n 1 -r; echo
    [[ $REPLY =~ ^[Yy}$ ]] && cloudflared tunnel route dns delete "$TUNNEL_NAME" "$DOMAIN" 2>/dev/null || true
    success "✅ 卸载完成"
    exit 0
}

show_help() {
    cat <<EOF
OpenClaw + Cloudflare Tunnel 部署 v$SCRIPT_VERSION

用法: ./$SCRIPT_NAME [选项]

选项:
  --domain <域名>           访问域名
  --port <端口>             监听端口 (默认 $DEFAULT_PORT)
  --no-access               跳过 CF Access (不推荐)
  --cf-api-token <token>    CF API Token
  --cf-account-id <id>      CF Account ID
  --access-email <email>    Access 白名单邮箱
  --uninstall               卸载
  --debug                   调试模式
  --help                    帮助

环境变量:
  OPENCLAW_TOKEN            安全传递 Token
  CF_API_TOKEN              CF API Token

支持系统:
  macOS 11.0+ (Intel/Apple Silicon)
  Ubuntu 20.04+ / Debian 11+
  CentOS 7+ / RHEL 8+ / Rocky / AlmaLinux
  Fedora 36+
EOF
    exit 0
}

main() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --domain) DOMAIN="$2"; shift 2 ;;
            --port) PORT="$2"; shift 2 ;;
            --no-access) NO_ACCESS=true; shift ;;
            --cf-api-token) CF_API_TOKEN="$2"; shift 2 ;;
            --cf-account-id) CF_ACCOUNT_ID="$2"; shift 2 ;;
            --access-email) ACCESS_EMAIL="$2"; shift 2 ;;
            --uninstall) UNINSTALL=true; shift ;;
            --help) show_help ;;
            --debug) DEBUG=1; shift ;;
            *) error "未知参数: $1" ;;
        esac
    done
    [ "$UNINSTALL" = "true" ] && { detect_os; uninstall; }
    detect_os
    OC_CONFIG_DIR="$HOME/.openclaw"
    CF_CONFIG_DIR="$HOME/.cloudflared"
    LOG_FILE="$OC_CONFIG_DIR/deploy-$TIMESTAMP.log"
    mkdir -p "$OC_CONFIG_DIR"
    touch "$LOG_FILE"; chmod 600 "$LOG_FILE"
    banner
    check_dependencies
    get_user_config
    dns_backup
    dns_set_doh
    install_openclaw
    configure_openclaw
    configure_tunnel
    configure_cf_access
    service_install
    service_start
    sleep 5
    verify_deployment
    echo ""
    echo -e "${GREEN}✅ 部署成功！${NC}"
    echo -e "  🌐 https://$DOMAIN"
    echo -e "  🔑 cat $OC_CONFIG_DIR/.auth_token"
    echo ""
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [[ $EUID -eq 0 ]] && [[ "$(uname)" != "Darwin" ]]; then
        echo -e "${YELLOW}⚠️  不建议用 root，脚本会按需 sudo${NC}"
        read -p "继续? (y/n): " -n 1 -r; echo
        [[ ! $REPLY =~ ^[Yy]$ ]] && exit 1
    fi
    [ "${BASH_VERSINFO[0]}" -lt 3 ] && { echo "需要 Bash 3.0+"; exit 1; }
    main "$@"
fi
