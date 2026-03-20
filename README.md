# OpenClaw + Cloudflare Tunnel 隐私部署脚本

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](https://opensource.org/licenses/MIT)
[![Platform: Cross-platform](https://img.shields.io/badge/Platform-macOS%20%7C%20Linux-999999.svg)]()
[![Privacy: Enhanced](https://img.shields.io/badge/Privacy-Enhanced-green.svg)](https://github.com/Peters-Pans/deploy-openclaw)

> 🦞 安全部署 OpenClaw + Cloudflare Tunnel，适配中国大陆动态 IPv4 环境  
> **跨平台 (macOS + Linux) | 无需公网 IP | 无需端口转发 | 无需备案**

---

## ✨ 特性

### 跨平台支持 (v3.1)

| 系统 | 包管理 | 服务管理 | 状态 |
|------|--------|----------|------|
| macOS 11.0+ | Homebrew | launchd (LaunchAgents) | ✅ |
| Ubuntu 20.04+ / Debian 11+ | apt | systemd | ✅ |
| CentOS 7+ / RHEL 8+ / Rocky / AlmaLinux | yum | systemd | ✅ |
| Fedora 36+ | dnf | systemd | ✅ |

脚本自动检测 OS，无需手动指定。

### 安全加固

- ✅ **Token 文件存储** (权限 600) — 不输出到终端，不通过命令行传递
- ✅ **日志权限 600** — 写入 `~/.openclaw/` 而非 `/tmp`
- ✅ **DNS 备份恢复** — 修改前自动备份，卸载时自动恢复
- ✅ **端口竞争防护** — 使用 `--force` 启动
- ✅ **可选 CF Access** — 四层防线 (Edge → JWT → cloudflared → Token)

### 隐私保护

- ✅ **真实 IP 完全隐藏** — Cloudflare Tunnel 反向代理
- ✅ **零公网端口暴露** — 仅监听 127.0.0.1
- ✅ **自动 HTTPS** — Cloudflare 自动签发 SSL
- ✅ **DNS 污染防护** — 自动配置 DoH (1.1.1.1)

---

## 🚀 快速开始

### 下载后验证再执行

```bash
# 下载
curl -fsSL https://raw.githubusercontent.com/Peters-Pans/deploy-openclaw/main/deploy-openclaw.sh -o deploy.sh

# 审查
less deploy.sh

# 执行
chmod +x deploy.sh
./deploy.sh
```

### 启用 Zero Trust

```bash
./deploy.sh --domain claw.example.com --enable-access
```

### 安全传递 Token

```bash
OPENCLAW_TOKEN=$(openssl rand -hex 32) ./deploy.sh --domain claw.example.com
```

### 卸载

```bash
./deploy.sh --uninstall
```

---

## 🔒 安全架构

### 默认模式

```
公网 → Cloudflare Edge (DDoS/WAF/SSL) → Tunnel → OpenClaw Token → UI
```

### Zero Trust 模式 (`--enable-access`)

```
公网 → Edge → CF Access (邮箱白名单 + JWT) → cloudflared (Origin JWT 验证) → OpenClaw Token → UI
```

---

## 📁 文件结构

```
~/.openclaw/
├── openclaw.json         # OpenClaw 配置
├── .auth_token           # Token (权限 600)
├── .dns_backup           # DNS 备份 (卸载时恢复)
└── deploy-*.log          # 日志 (权限 600)

~/.cloudflared/
├── config.yml            # Tunnel 配置
├── cert.pem              # CF 认证凭据
├── <tunnel-id>.json      # Tunnel 凭据
└── tunnel.log            # Tunnel 日志

# macOS
~/Library/LaunchAgents/
├── ai.openclaw.gateway.plist
└── com.cloudflare.cloudflared.plist

# Linux
/etc/systemd/system/
├── openclaw-gateway.service
└── cloudflared-tunnel.service
```

---

## ⚙️ 选项

| 选项 | 说明 |
|------|------|
| `--domain <域名>` | 访问域名 |
| `--port <端口>` | 监听端口 (默认 10371) |
| `--enable-access` | 启用 CF Access Zero Trust |
| `--cf-api-token <token>` | CF API Token |
| `--cf-account-id <id>` | CF Account ID |
| `--access-email <email>` | Access 白名单邮箱 |
| `--uninstall` | 卸载 |
| `--debug` | 调试模式 |

| 环境变量 | 说明 |
|----------|------|
| `OPENCLAW_TOKEN` | 安全传递 Token |
| `CF_API_TOKEN` | CF API Token |

---

## 📋 系统要求

- **macOS** 11.0+ (Intel/Apple Silicon)
- **Linux** Ubuntu 20.04+ / Debian 11+ / CentOS 7+ / RHEL 8+ / Fedora 36+
- **Bash** 3.0+
- **网络** 出站 443 端口可达
- **域名** 已托管到 Cloudflare DNS
- **权限** 标准用户 + sudo (Linux)

---

## 📖 License

MIT
