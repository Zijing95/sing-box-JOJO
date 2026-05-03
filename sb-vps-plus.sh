#!/usr/bin/env bash

# sing-box VPS Plus
# Independent VPS script for safer multi-protocol deployment.
# It does not modify the original sb.sh/serv00.sh scripts.

set -Eeuo pipefail
umask 077

SCRIPT_NAME="sb-vps-plus"
SCRIPT_VERSION="2026.05.03-4"
SING_BOX_VERSION="${SING_BOX_VERSION:-1.13.8}"
REPO_RAW_URL="${REPO_RAW_URL:-https://raw.githubusercontent.com/Zijing95/sing-box-JOJO/main/sb-vps-plus.sh}"
BASE_DIR="/etc/s-box-plus"
BIN_PATH="${BASE_DIR}/sing-box"
CONFIG_PATH="${BASE_DIR}/config.json"
CLIENT_PATH="${BASE_DIR}/client-sing-box.json"
MIHOMO_PATH="${BASE_DIR}/mihomo.yaml"
LOON_PATH="${BASE_DIR}/loon.conf"
SHADOWROCKET_PATH="${BASE_DIR}/shadowrocket.conf"
SHADOWROCKET_LINKS_PATH="${BASE_DIR}/shadowrocket-links.txt"
ENV_PATH="${BASE_DIR}/env"
LINKS_PATH="${BASE_DIR}/links.txt"
QR_DIR="${BASE_DIR}/qrcode"
BACKUP_DIR="${BASE_DIR}/backup"
EAST_CT_REPORT="${BASE_DIR}/east-china-telecom.csv"
CERT_PATH="${BASE_DIR}/cert.pem"
KEY_PATH="${BASE_DIR}/private.key"
SERVICE_PATH="/etc/systemd/system/sing-box-plus.service"
CLI_PATH="/usr/local/bin/sbp"

red() { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
plain() { printf '%s\n' "$*"; }

die() {
  red "错误: $*"
  exit 1
}

need_root() {
  [ "$(id -u)" -eq 0 ] || die "请使用 root 运行：sudo bash $0"
}

has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

random_hex() {
  openssl rand -hex "${1:-8}"
}

random_base64() {
  openssl rand -base64 "${1:-24}" | tr -d '\n=+/' | cut -c 1-"${2:-32}"
}

random_port() {
  shuf -i 20000-60000 -n 1
}

install_deps() {
  local pkgs="curl wget tar openssl jq coreutils ca-certificates"
  if has_cmd apt-get; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y ${pkgs} iproute2
  elif has_cmd dnf; then
    dnf install -y ${pkgs} iproute
  elif has_cmd yum; then
    yum install -y epel-release || true
    yum install -y ${pkgs} iproute
  elif has_cmd apk; then
    apk add --no-cache ${pkgs} iproute2
  else
    die "不支持的系统包管理器，请手动安装 curl/wget/tar/openssl/jq/coreutils"
  fi
}

install_optional_tools() {
  if has_cmd qrencode; then
    return
  fi

  yellow "尝试安装二维码工具 qrencode，失败不影响核心安装。"
  if has_cmd apt-get; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y qrencode >/dev/null 2>&1 || true
  elif has_cmd dnf; then
    dnf install -y qrencode >/dev/null 2>&1 || true
  elif has_cmd yum; then
    yum install -y qrencode >/dev/null 2>&1 || true
  elif has_cmd apk; then
    apk add --no-cache qrencode >/dev/null 2>&1 || true
  fi
}

detect_arch() {
  case "$(uname -m)" in
    x86_64 | amd64) printf 'amd64' ;;
    aarch64 | arm64) printf 'arm64' ;;
    *) die "暂不支持架构：$(uname -m)" ;;
  esac
}

download_sing_box() {
  local arch url tmp archive extracted
  arch="$(detect_arch)"
  url="https://github.com/SagerNet/sing-box/releases/download/v${SING_BOX_VERSION}/sing-box-${SING_BOX_VERSION}-linux-${arch}.tar.gz"
  tmp="$(mktemp -d)"
  archive="${tmp}/sing-box.tar.gz"

  yellow "下载 sing-box v${SING_BOX_VERSION} (${arch}) ..."
  curl -fL --retry 3 --connect-timeout 15 -o "${archive}" "${url}" || die "sing-box 下载失败：${url}"
  tar -xzf "${archive}" -C "${tmp}"
  extracted="$(find "${tmp}" -type f -name sing-box | head -n 1)"
  [ -n "${extracted}" ] || die "未找到 sing-box 二进制文件"
  install -m 0755 "${extracted}" "${BIN_PATH}"
  rm -rf "${tmp}"
}

detect_public_ip() {
  local ip4 ip6
  ip4="$(curl -4fsS --max-time 5 https://api.ipify.org || true)"
  ip6="$(curl -6fsS --max-time 5 https://api64.ipify.org || true)"
  if [ -n "${ip4}" ]; then
    printf '%s' "${ip4}"
  elif [ -n "${ip6}" ]; then
    printf '[%s]' "${ip6}"
  else
    printf 'YOUR_SERVER_IP'
  fi
}

normalize_addresses() {
  SERVER_LINK="${SERVER_ADDR}"
  if printf '%s' "${SERVER_ADDR}" | grep -q ':' && ! printf '%s' "${SERVER_ADDR}" | grep -q '^\['; then
    SERVER_LINK="[${SERVER_ADDR}]"
  fi
  SERVER_HOST="${SERVER_LINK#[}"
  SERVER_HOST="${SERVER_HOST%]}"
}

ensure_server_context() {
  if [ -z "${SERVER_ADDR:-}" ]; then
    SERVER_ADDR="$(detect_public_ip)"
  fi
  normalize_addresses
}

ensure_cert() {
  if [ -n "${TLS_CERT_PATH:-}" ] && [ -n "${TLS_KEY_PATH:-}" ]; then
    [ -f "${TLS_CERT_PATH}" ] || die "证书不存在：${TLS_CERT_PATH}"
    [ -f "${TLS_KEY_PATH}" ] || die "私钥不存在：${TLS_KEY_PATH}"
    CERT_PATH="${TLS_CERT_PATH}"
    KEY_PATH="${TLS_KEY_PATH}"
    return
  fi

  if [ ! -s "${CERT_PATH}" ] || [ ! -s "${KEY_PATH}" ]; then
    yellow "未提供真实域名证书，生成自签证书。客户端会使用 insecure=true。"
    openssl req -x509 -newkey rsa:2048 -nodes \
      -keyout "${KEY_PATH}" \
      -out "${CERT_PATH}" \
      -days 3650 \
      -subj "/CN=${TLS_SERVER_NAME}" >/dev/null 2>&1
  fi
}

issue_acme_cert() {
  [ -n "${ACME_DOMAIN:-}" ] || die "在线申请证书需要域名"
  yellow "准备为 ${ACME_DOMAIN} 申请 Let's Encrypt 证书。请确认域名已解析到本机，且 TCP 80 未被占用。"
  read -r -p "继续申请请输入 YES: " confirm || true
  [ "${confirm}" = "YES" ] || die "已取消在线申请证书"

  if ! has_cmd socat; then
    if has_cmd apt-get; then
      DEBIAN_FRONTEND=noninteractive apt-get install -y socat
    elif has_cmd dnf; then
      dnf install -y socat
    elif has_cmd yum; then
      yum install -y socat
    elif has_cmd apk; then
      apk add --no-cache socat
    fi
  fi

  if [ ! -x "${HOME}/.acme.sh/acme.sh" ]; then
    curl -fsSL https://get.acme.sh | sh -s email="${ACME_EMAIL:-admin@${ACME_DOMAIN}}"
  fi

  "${HOME}/.acme.sh/acme.sh" --set-default-ca --server letsencrypt
  "${HOME}/.acme.sh/acme.sh" --issue -d "${ACME_DOMAIN}" --standalone --keylength ec-256
  "${HOME}/.acme.sh/acme.sh" --install-cert -d "${ACME_DOMAIN}" --ecc \
    --fullchain-file "${CERT_PATH}" \
    --key-file "${KEY_PATH}" \
    --reloadcmd "systemctl restart sing-box-plus >/dev/null 2>&1 || true"

  TLS_CERT_PATH="${CERT_PATH}"
  TLS_KEY_PATH="${KEY_PATH}"
  TLS_SERVER_NAME="${ACME_DOMAIN}"
  green "证书已安装到 ${CERT_PATH} 和 ${KEY_PATH}"
}

read_default() {
  local prompt default value
  prompt="$1"
  default="$2"
  read -r -p "${prompt} [${default}]: " value || true
  printf '%s' "${value:-$default}"
}

load_env() {
  if [ -f "${ENV_PATH}" ]; then
    # shellcheck disable=SC1090
    . "${ENV_PATH}"
  fi
}

save_env() {
  cat > "${ENV_PATH}" <<EOF
SERVER_ADDR='${SERVER_ADDR}'
SERVER_LINK='${SERVER_LINK}'
SERVER_HOST='${SERVER_HOST}'
TLS_SERVER_NAME='${TLS_SERVER_NAME}'
REALITY_SERVER_NAME='${REALITY_SERVER_NAME}'
REALITY_DEST='${REALITY_DEST}'
VLESS_PORT='${VLESS_PORT}'
ANYTLS_PORT='${ANYTLS_PORT}'
HY2_PORT='${HY2_PORT}'
TUIC_PORT='${TUIC_PORT}'
UUID='${UUID}'
REALITY_PRIVATE_KEY='${REALITY_PRIVATE_KEY}'
REALITY_PUBLIC_KEY='${REALITY_PUBLIC_KEY}'
REALITY_SHORT_ID='${REALITY_SHORT_ID}'
ANYTLS_PASSWORD='${ANYTLS_PASSWORD}'
HY2_PASSWORD='${HY2_PASSWORD}'
HY2_OBFS='${HY2_OBFS}'
TUIC_PASSWORD='${TUIC_PASSWORD}'
TLS_CERT_PATH='${TLS_CERT_PATH:-}'
TLS_KEY_PATH='${TLS_KEY_PATH:-}'
CERT_MODE='${CERT_MODE:-1}'
ACME_DOMAIN='${ACME_DOMAIN:-}'
ACME_EMAIL='${ACME_EMAIL:-}'
EOF
}

collect_inputs() {
  SERVER_ADDR="$(read_default "服务器公网 IP 或域名" "$(detect_public_ip)")"
  TLS_SERVER_NAME="$(read_default "TLS 伪装/证书域名，建议填你自己的域名" "www.apple.com")"
  REALITY_SERVER_NAME="$(read_default "Reality 握手域名" "www.cloudflare.com")"
  REALITY_DEST="${REALITY_SERVER_NAME}:443"
  VLESS_PORT="$(read_default "VLESS Reality 端口 TCP" "$(random_port)")"
  ANYTLS_PORT="$(read_default "AnyTLS 端口 TCP" "$(random_port)")"
  HY2_PORT="$(read_default "Hysteria2 端口 UDP" "$(random_port)")"
  TUIC_PORT="$(read_default "TUIC v5 端口 UDP" "$(random_port)")"

  plain ""
  plain "TLS 证书模式："
  plain "1. 自签证书（最省事，客户端会 insecure=true）"
  plain "2. 使用已有证书"
  plain "3. 在线申请 Let's Encrypt 证书（需要域名解析到本机，并放行 TCP 80）"
  CERT_MODE="$(read_default "请选择证书模式" "1")"
  TLS_CERT_PATH=""
  TLS_KEY_PATH=""
  ACME_DOMAIN=""
  ACME_EMAIL=""
  case "${CERT_MODE}" in
    1) ;;
    2)
      read -r -p "TLS 证书 fullchain 路径: " TLS_CERT_PATH || true
      read -r -p "TLS 私钥路径: " TLS_KEY_PATH || true
      ;;
    3)
      ACME_DOMAIN="$(read_default "申请证书的域名" "${TLS_SERVER_NAME}")"
      ACME_EMAIL="$(read_default "ACME 邮箱" "admin@${ACME_DOMAIN}")"
      ;;
    *) die "无效证书模式" ;;
  esac
  normalize_addresses

  UUID="$("${BIN_PATH}" generate uuid)"
  local keypair
  keypair="$("${BIN_PATH}" generate reality-keypair)"
  REALITY_PRIVATE_KEY="$(printf '%s\n' "${keypair}" | awk '/PrivateKey:/ {print $2}')"
  REALITY_PUBLIC_KEY="$(printf '%s\n' "${keypair}" | awk '/PublicKey:/ {print $2}')"
  REALITY_SHORT_ID="$(random_hex 8)"
  ANYTLS_PASSWORD="$(random_base64 24 32)"
  HY2_PASSWORD="$(random_base64 24 32)"
  HY2_OBFS="$(random_base64 16 24)"
  TUIC_PASSWORD="$(random_base64 24 32)"
}

collect_auto_inputs() {
  SERVER_ADDR="${SERVER_ADDR:-$(detect_public_ip)}"
  TLS_SERVER_NAME="${TLS_SERVER_NAME:-www.apple.com}"
  REALITY_SERVER_NAME="${REALITY_SERVER_NAME:-www.cloudflare.com}"
  REALITY_DEST="${REALITY_SERVER_NAME}:443"
  VLESS_PORT="${VLESS_PORT:-$(random_port)}"
  ANYTLS_PORT="${ANYTLS_PORT:-$(random_port)}"
  HY2_PORT="${HY2_PORT:-$(random_port)}"
  TUIC_PORT="${TUIC_PORT:-$(random_port)}"
  CERT_MODE="${CERT_MODE:-1}"
  TLS_CERT_PATH="${TLS_CERT_PATH:-}"
  TLS_KEY_PATH="${TLS_KEY_PATH:-}"
  ACME_DOMAIN="${ACME_DOMAIN:-}"
  ACME_EMAIL="${ACME_EMAIL:-}"
  normalize_addresses

  UUID="${UUID:-$("${BIN_PATH}" generate uuid)}"
  local keypair
  keypair="$("${BIN_PATH}" generate reality-keypair)"
  REALITY_PRIVATE_KEY="${REALITY_PRIVATE_KEY:-$(printf '%s\n' "${keypair}" | awk '/PrivateKey:/ {print $2}')}"
  REALITY_PUBLIC_KEY="${REALITY_PUBLIC_KEY:-$(printf '%s\n' "${keypair}" | awk '/PublicKey:/ {print $2}')}"
  REALITY_SHORT_ID="${REALITY_SHORT_ID:-$(random_hex 8)}"
  ANYTLS_PASSWORD="${ANYTLS_PASSWORD:-$(random_base64 24 32)}"
  HY2_PASSWORD="${HY2_PASSWORD:-$(random_base64 24 32)}"
  HY2_OBFS="${HY2_OBFS:-$(random_base64 16 24)}"
  TUIC_PASSWORD="${TUIC_PASSWORD:-$(random_base64 24 32)}"
}

create_server_config() {
  jq -n \
    --arg vless_port "${VLESS_PORT}" \
    --arg anytls_port "${ANYTLS_PORT}" \
    --arg hy2_port "${HY2_PORT}" \
    --arg tuic_port "${TUIC_PORT}" \
    --arg uuid "${UUID}" \
    --arg reality_dest "${REALITY_DEST}" \
    --arg reality_server_name "${REALITY_SERVER_NAME}" \
    --arg reality_private_key "${REALITY_PRIVATE_KEY}" \
    --arg reality_short_id "${REALITY_SHORT_ID}" \
    --arg anytls_password "${ANYTLS_PASSWORD}" \
    --arg hy2_password "${HY2_PASSWORD}" \
    --arg hy2_obfs "${HY2_OBFS}" \
    --arg tuic_password "${TUIC_PASSWORD}" \
    --arg cert_path "${CERT_PATH}" \
    --arg key_path "${KEY_PATH}" \
    '{
      log: { level: "warn", timestamp: true },
      dns: {
        servers: [
          { tag: "cloudflare", address: "tls://1.1.1.1", detour: "direct" },
          { tag: "google", address: "tls://8.8.8.8", detour: "direct" }
        ],
        final: "cloudflare"
      },
      inbounds: [
        {
          type: "vless",
          tag: "vless-reality-in",
          listen: "::",
          listen_port: ($vless_port | tonumber),
          users: [
            {
              name: "plus",
              uuid: $uuid,
              flow: "xtls-rprx-vision"
            }
          ],
          tls: {
            enabled: true,
            server_name: $reality_server_name,
            reality: {
              enabled: true,
              handshake: {
                server: ($reality_dest | split(":")[0]),
                server_port: (($reality_dest | split(":")[1]) | tonumber)
              },
              private_key: $reality_private_key,
              short_id: [$reality_short_id]
            }
          }
        },
        {
          type: "anytls",
          tag: "anytls-in",
          listen: "::",
          listen_port: ($anytls_port | tonumber),
          users: [
            { name: "plus", password: $anytls_password }
          ],
          tls: {
            enabled: true,
            server_name: "placeholder",
            certificate_path: $cert_path,
            key_path: $key_path
          }
        },
        {
          type: "hysteria2",
          tag: "hy2-in",
          listen: "::",
          listen_port: ($hy2_port | tonumber),
          obfs: {
            type: "salamander",
            password: $hy2_obfs
          },
          users: [
            { name: "plus", password: $hy2_password }
          ],
          ignore_client_bandwidth: true,
          tls: {
            enabled: true,
            certificate_path: $cert_path,
            key_path: $key_path
          }
        },
        {
          type: "tuic",
          tag: "tuic-in",
          listen: "::",
          listen_port: ($tuic_port | tonumber),
          users: [
            { name: "plus", uuid: $uuid, password: $tuic_password }
          ],
          congestion_control: "bbr",
          zero_rtt_handshake: false,
          heartbeat: "10s",
          tls: {
            enabled: true,
            certificate_path: $cert_path,
            key_path: $key_path
          }
        }
      ],
      outbounds: [
        { type: "direct", tag: "direct" },
        { type: "block", tag: "block" }
      ],
      route: {
        final: "direct",
        auto_detect_interface: true
      }
    }' > "${CONFIG_PATH}"

  jq --arg server_name "${TLS_SERVER_NAME}" \
    '(.inbounds[] | select(.tag == "anytls-in") | .tls.server_name) = $server_name' \
    "${CONFIG_PATH}" > "${CONFIG_PATH}.tmp"
  mv "${CONFIG_PATH}.tmp" "${CONFIG_PATH}"
}

create_client_config() {
  local insecure
  normalize_addresses
  insecure="true"
  if [ -n "${TLS_CERT_PATH:-}" ] && [ -n "${TLS_KEY_PATH:-}" ]; then
    insecure="false"
  fi

  jq -n \
    --arg server "${SERVER_ADDR}" \
    --arg server_host "${SERVER_HOST}" \
    --arg tls_server_name "${TLS_SERVER_NAME}" \
    --arg reality_server_name "${REALITY_SERVER_NAME}" \
    --arg vless_port "${VLESS_PORT}" \
    --arg anytls_port "${ANYTLS_PORT}" \
    --arg hy2_port "${HY2_PORT}" \
    --arg tuic_port "${TUIC_PORT}" \
    --arg uuid "${UUID}" \
    --arg reality_public_key "${REALITY_PUBLIC_KEY}" \
    --arg reality_short_id "${REALITY_SHORT_ID}" \
    --arg anytls_password "${ANYTLS_PASSWORD}" \
    --arg hy2_password "${HY2_PASSWORD}" \
    --arg hy2_obfs "${HY2_OBFS}" \
    --arg tuic_password "${TUIC_PASSWORD}" \
    --argjson insecure "${insecure}" \
    '{
      log: { level: "warn", timestamp: true },
      dns: {
        servers: [
          { tag: "remote", address: "https://1.1.1.1/dns-query", detour: "proxy" },
          { tag: "local", address: "223.5.5.5", detour: "direct" }
        ],
        final: "remote"
      },
      inbounds: [
        { type: "mixed", tag: "mixed-in", listen: "127.0.0.1", listen_port: 2080 }
      ],
      outbounds: [
        {
          type: "selector",
          tag: "proxy",
          outbounds: ["vless-reality", "anytls", "hysteria2", "tuic-v5", "direct"]
        },
        {
          type: "vless",
          tag: "vless-reality",
          server: $server_host,
          server_port: ($vless_port | tonumber),
          uuid: $uuid,
          flow: "xtls-rprx-vision",
          tls: {
            enabled: true,
            server_name: $reality_server_name,
            utls: { enabled: true, fingerprint: "chrome" },
            reality: {
              enabled: true,
              public_key: $reality_public_key,
              short_id: $reality_short_id
            }
          }
        },
        {
          type: "anytls",
          tag: "anytls",
          server: $server_host,
          server_port: ($anytls_port | tonumber),
          password: $anytls_password,
          idle_session_check_interval: "30s",
          idle_session_timeout: "30s",
          min_idle_session: 2,
          tls: {
            enabled: true,
            server_name: $tls_server_name,
            insecure: $insecure,
            utls: { enabled: true, fingerprint: "chrome" }
          }
        },
        {
          type: "hysteria2",
          tag: "hysteria2",
          server: $server_host,
          server_port: ($hy2_port | tonumber),
          obfs: {
            type: "salamander",
            password: $hy2_obfs
          },
          password: $hy2_password,
          tls: {
            enabled: true,
            server_name: $tls_server_name,
            insecure: $insecure
          }
        },
        {
          type: "tuic",
          tag: "tuic-v5",
          server: $server_host,
          server_port: ($tuic_port | tonumber),
          uuid: $uuid,
          password: $tuic_password,
          congestion_control: "bbr",
          udp_relay_mode: "native",
          zero_rtt_handshake: false,
          heartbeat: "10s",
          tls: {
            enabled: true,
            server_name: $tls_server_name,
            insecure: $insecure
          }
        },
        { type: "direct", tag: "direct" },
        { type: "block", tag: "block" }
      ],
      route: {
        final: "proxy",
        auto_detect_interface: true
      }
    }' > "${CLIENT_PATH}"
}

create_links() {
  VLESS_LINK="vless://${UUID}@${SERVER_LINK}:${VLESS_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SERVER_NAME}&fp=chrome&pbk=${REALITY_PUBLIC_KEY}&sid=${REALITY_SHORT_ID}&type=tcp#VLESS-Reality-Plus"
  HY2_LINK="hysteria2://${HY2_PASSWORD}@${SERVER_LINK}:${HY2_PORT}?obfs=salamander&obfs-password=${HY2_OBFS}&sni=${TLS_SERVER_NAME}&insecure=1#HY2-Plus"
  TUIC_LINK="tuic://${UUID}:${TUIC_PASSWORD}@${SERVER_LINK}:${TUIC_PORT}?congestion_control=bbr&udp_relay_mode=native&sni=${TLS_SERVER_NAME}&allow_insecure=1#TUIC-v5-Plus"

  cat > "${LINKS_PATH}" <<EOF
sing-box VPS Plus ${SCRIPT_VERSION}

服务器: ${SERVER_ADDR}
sing-box 版本: ${SING_BOX_VERSION}

VLESS Reality:
${VLESS_LINK}

Hysteria2:
${HY2_LINK}

TUIC v5:
${TUIC_LINK}

AnyTLS:
请优先使用 ${CLIENT_PATH} 中的 sing-box 客户端配置。

需要放行的端口:
TCP: ${VLESS_PORT}, ${ANYTLS_PORT}
UDP: ${HY2_PORT}, ${TUIC_PORT}
EOF
}

client_insecure_value() {
  if [ -n "${TLS_CERT_PATH:-}" ] && [ -n "${TLS_KEY_PATH:-}" ]; then
    printf 'false'
  else
    printf 'true'
  fi
}

create_mihomo_config() {
  local insecure
  ensure_server_context
  insecure="$(client_insecure_value)"
  cat > "${MIHOMO_PATH}" <<EOF
mixed-port: 7890
allow-lan: false
mode: rule
log-level: warning
ipv6: true

dns:
  enable: true
  listen: 127.0.0.1:1053
  enhanced-mode: fake-ip
  nameserver:
    - https://1.1.1.1/dns-query
    - https://8.8.8.8/dns-query

proxies:
  - name: VLESS-Reality-Plus
    type: vless
    server: "${SERVER_HOST}"
    port: ${VLESS_PORT}
    uuid: "${UUID}"
    network: tcp
    tls: true
    udp: true
    flow: xtls-rprx-vision
    servername: "${REALITY_SERVER_NAME}"
    client-fingerprint: chrome
    reality-opts:
      public-key: "${REALITY_PUBLIC_KEY}"
      short-id: "${REALITY_SHORT_ID}"

  - name: Hysteria2-Plus
    type: hysteria2
    server: "${SERVER_HOST}"
    port: ${HY2_PORT}
    password: "${HY2_PASSWORD}"
    sni: "${TLS_SERVER_NAME}"
    skip-cert-verify: ${insecure}
    obfs: salamander
    obfs-password: "${HY2_OBFS}"

  - name: TUIC-v5-Plus
    type: tuic
    server: "${SERVER_HOST}"
    port: ${TUIC_PORT}
    uuid: "${UUID}"
    password: "${TUIC_PASSWORD}"
    sni: "${TLS_SERVER_NAME}"
    skip-cert-verify: ${insecure}
    congestion-controller: bbr
    udp-relay-mode: native

proxy-groups:
  - name: PROXY
    type: select
    proxies:
      - VLESS-Reality-Plus
      - Hysteria2-Plus
      - TUIC-v5-Plus
      - DIRECT

rules:
  - GEOIP,LAN,DIRECT
  - MATCH,PROXY
EOF
}

create_loon_config() {
  local insecure
  ensure_server_context
  insecure="$(client_insecure_value)"
  cat > "${LOON_PATH}" <<EOF
# Loon 配置草案。不同 Loon 版本对 Reality/Hysteria2/TUIC 字段支持不同；
# 如导入失败，请优先使用下方分享链接或 sing-box 客户端配置。

[General]
interface = 0.0.0.0
port = 6152
socks-port = 6153
allow-wifi-access = false
ipv6 = true

[Proxy]
VLESS-Reality-Plus = vless, ${SERVER_HOST}, ${VLESS_PORT}, uuid=${UUID}, tls=true, flow=xtls-rprx-vision, sni=${REALITY_SERVER_NAME}, reality=true, public-key=${REALITY_PUBLIC_KEY}, short-id=${REALITY_SHORT_ID}, client-fingerprint=chrome
Hysteria2-Plus = hysteria2, ${SERVER_HOST}, ${HY2_PORT}, password=${HY2_PASSWORD}, sni=${TLS_SERVER_NAME}, skip-cert-verify=${insecure}, obfs=salamander, obfs-password=${HY2_OBFS}
TUIC-v5-Plus = tuic, ${SERVER_HOST}, ${TUIC_PORT}, uuid=${UUID}, password=${TUIC_PASSWORD}, sni=${TLS_SERVER_NAME}, skip-cert-verify=${insecure}, congestion-controller=bbr, udp-relay-mode=native

[Proxy Group]
PROXY = select, VLESS-Reality-Plus, Hysteria2-Plus, TUIC-v5-Plus, DIRECT

[Rule]
FINAL, PROXY

[Remote Proxy]
# 也可直接导入这些分享链接：
${VLESS_LINK}
${HY2_LINK}
${TUIC_LINK}
EOF
}

create_shadowrocket_config() {
  local insecure
  ensure_server_context
  insecure="$(client_insecure_value)"
  cat > "${SHADOWROCKET_PATH}" <<EOF
# Shadowrocket/小火箭配置草案。不同版本对 Reality/Hysteria2/TUIC 字段支持不同；
# 最稳方式是复制 ${SHADOWROCKET_LINKS_PATH} 里的分享链接逐个导入。

[General]
bypass-system = true
skip-proxy = 127.0.0.1, localhost, *.local
dns-server = system, 1.1.1.1, 8.8.8.8

[Proxy]
VLESS-Reality-Plus = vless, ${SERVER_HOST}, ${VLESS_PORT}, uuid=${UUID}, tls=true, flow=xtls-rprx-vision, sni=${REALITY_SERVER_NAME}, reality=true, public-key=${REALITY_PUBLIC_KEY}, short-id=${REALITY_SHORT_ID}, client-fingerprint=chrome
Hysteria2-Plus = hysteria2, ${SERVER_HOST}, ${HY2_PORT}, password=${HY2_PASSWORD}, sni=${TLS_SERVER_NAME}, skip-cert-verify=${insecure}, obfs=salamander, obfs-password=${HY2_OBFS}
TUIC-v5-Plus = tuic, ${SERVER_HOST}, ${TUIC_PORT}, uuid=${UUID}, password=${TUIC_PASSWORD}, sni=${TLS_SERVER_NAME}, skip-cert-verify=${insecure}, congestion-controller=bbr, udp-relay-mode=native

[Proxy Group]
PROXY = select, VLESS-Reality-Plus, Hysteria2-Plus, TUIC-v5-Plus

[Rule]
FINAL, PROXY
EOF

  cat > "${SHADOWROCKET_LINKS_PATH}" <<EOF
${VLESS_LINK}
${HY2_LINK}
${TUIC_LINK}
EOF
}

create_client_outputs() {
  create_mihomo_config
  create_loon_config
  create_shadowrocket_config
}

create_qrcodes() {
  mkdir -p "${QR_DIR}"
  if ! has_cmd qrencode; then
    yellow "未安装 qrencode，跳过二维码生成。"
    return
  fi

  [ -n "${VLESS_LINK:-}" ] || create_links
  qrencode -o "${QR_DIR}/vless-reality.png" "${VLESS_LINK}" || true
  qrencode -o "${QR_DIR}/hysteria2.png" "${HY2_LINK}" || true
  qrencode -o "${QR_DIR}/tuic-v5.png" "${TUIC_LINK}" || true

  cat > "${QR_DIR}/README.txt" <<EOF
二维码文件:
${QR_DIR}/vless-reality.png
${QR_DIR}/hysteria2.png
${QR_DIR}/tuic-v5.png

终端显示二维码:
sbp qrcode
EOF
}

show_qrcodes() {
  need_root
  if ! has_cmd qrencode; then
    yellow "未安装 qrencode，无法在终端显示二维码。"
    plain "链接文件：${LINKS_PATH}"
    return
  fi
  if [ ! -f "${LINKS_PATH}" ]; then
    die "未找到节点信息，请先安装。"
  fi
  plain "VLESS Reality:"
  awk '/^vless:\/\// {print; exit}' "${LINKS_PATH}" | qrencode -t ansiutf8
  plain "Hysteria2:"
  awk '/^hysteria2:\/\// {print; exit}' "${LINKS_PATH}" | qrencode -t ansiutf8
  plain "TUIC v5:"
  awk '/^tuic:\/\// {print; exit}' "${LINKS_PATH}" | qrencode -t ansiutf8
  plain "PNG 文件目录：${QR_DIR}"
}

create_service() {
  cat > "${SERVICE_PATH}" <<EOF
[Unit]
Description=sing-box plus service
Documentation=https://sing-box.sagernet.org
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=${BIN_PATH} run -c ${CONFIG_PATH}
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF
}

create_cli() {
  cat > "${CLI_PATH}" <<EOF
#!/usr/bin/env bash
bash <(curl -Ls "${REPO_RAW_URL}") "\$@"
EOF
  chmod 0755 "${CLI_PATH}"
}

backup_current_config() {
  mkdir -p "${BACKUP_DIR}"
  if [ ! -e "${CONFIG_PATH}" ] && [ ! -e "${ENV_PATH}" ] && [ ! -e "${LINKS_PATH}" ]; then
    return
  fi

  local backup_file
  backup_file="${BACKUP_DIR}/s-box-plus-$(date +%Y%m%d-%H%M%S).tar.gz"
  tar -czf "${backup_file}" -C "${BASE_DIR}" \
    config.json client-sing-box.json mihomo.yaml loon.conf shadowrocket.conf shadowrocket-links.txt env links.txt cert.pem private.key qrcode 2>/dev/null || true
  if [ -s "${backup_file}" ]; then
    green "已备份当前配置：${backup_file}"
  else
    rm -f "${backup_file}"
  fi
}

list_backups() {
  if [ ! -d "${BACKUP_DIR}" ]; then
    yellow "暂无备份。"
    return 1
  fi
  find "${BACKUP_DIR}" -maxdepth 1 -type f -name '*.tar.gz' | sort -r
}

restore_backup() {
  need_root
  local latest backup_file
  latest="$(list_backups | head -n 1 || true)"
  [ -n "${latest}" ] || die "暂无可恢复备份"
  plain "最新备份：${latest}"
  backup_file="$(read_default "要恢复的备份文件" "${latest}")"
  [ -f "${backup_file}" ] || die "备份文件不存在：${backup_file}"
  read -r -p "恢复会覆盖当前 ${BASE_DIR} 配置，确认请输入 YES: " confirm || true
  [ "${confirm}" = "YES" ] || die "已取消"
  mkdir -p "${BASE_DIR}"
  tar -xzf "${backup_file}" -C "${BASE_DIR}"
  if [ -x "${BIN_PATH}" ] && [ -f "${CONFIG_PATH}" ]; then
    "${BIN_PATH}" check -c "${CONFIG_PATH}" || die "恢复后的配置检查失败，未重启服务"
    systemctl restart sing-box-plus || true
  fi
  green "已恢复备份：${backup_file}"
}

show_firewall_tips() {
  need_root
  load_env
  plain "需要放行的端口："
  plain "TCP: ${VLESS_PORT:-VLESS端口}, ${ANYTLS_PORT:-AnyTLS端口}"
  plain "UDP: ${HY2_PORT:-Hysteria2端口}, ${TUIC_PORT:-TUIC端口}"
  plain ""

  if has_cmd ufw; then
    plain "UFW 状态："
    ufw status || true
    plain "可参考命令："
    plain "ufw allow ${VLESS_PORT:-端口}/tcp"
    plain "ufw allow ${ANYTLS_PORT:-端口}/tcp"
    plain "ufw allow ${HY2_PORT:-端口}/udp"
    plain "ufw allow ${TUIC_PORT:-端口}/udp"
  elif has_cmd firewall-cmd; then
    plain "firewalld 状态："
    firewall-cmd --state || true
    plain "可参考命令："
    plain "firewall-cmd --permanent --add-port=${VLESS_PORT:-端口}/tcp"
    plain "firewall-cmd --permanent --add-port=${ANYTLS_PORT:-端口}/tcp"
    plain "firewall-cmd --permanent --add-port=${HY2_PORT:-端口}/udp"
    plain "firewall-cmd --permanent --add-port=${TUIC_PORT:-端口}/udp"
    plain "firewall-cmd --reload"
  else
    yellow "未检测到 ufw/firewalld。请检查系统防火墙、云厂商安全组或 iptables/nftables。"
  fi

  plain ""
  yellow "甲骨文云还必须在控制台 Security List 或 NSG 同时放行这些端口。"
}

show_listening_ports() {
  plain "当前监听端口："
  if has_cmd ss; then
    ss -lntup 2>/dev/null | grep -E "(:${VLESS_PORT:-0}|:${ANYTLS_PORT:-0}|:${HY2_PORT:-0}|:${TUIC_PORT:-0})\\b" || true
  elif has_cmd netstat; then
    netstat -lntup 2>/dev/null | grep -E "(:${VLESS_PORT:-0}|:${ANYTLS_PORT:-0}|:${HY2_PORT:-0}|:${TUIC_PORT:-0})\\b" || true
  else
    yellow "未检测到 ss/netstat，无法显示监听端口。"
  fi
}

show_bbr_status() {
  plain "TCP 拥塞控制："
  sysctl net.ipv4.tcp_congestion_control 2>/dev/null || true
  sysctl net.core.default_qdisc 2>/dev/null || true
  if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -qi bbr; then
    green "BBR 已启用。"
  else
    yellow "BBR 未启用或无法确认。可后续单独增加安全启用选项。"
  fi
}

show_reverse_routes_to_china_telecom() {
  local targets target name ip
  targets="
上海电信DNS 202.96.209.133
上海电信节点 101.95.206.10
江苏电信DNS1 218.2.2.2
江苏电信DNS2 218.4.4.4
中国电信DNS 114.114.114.114
"

  plain "VPS -> 华东/江苏电信 反向路由参考："
  if has_cmd traceroute; then
    while read -r name ip; do
      [ -n "${name}" ] || continue
      plain ""
      plain "${name} (${ip})"
      traceroute -n -w 1 -q 1 -m 12 "${ip}" 2>/dev/null || true
    done <<EOF
${targets}
EOF
  elif has_cmd tracepath; then
    while read -r name ip; do
      [ -n "${name}" ] || continue
      plain ""
      plain "${name} (${ip})"
      tracepath -n -m 12 "${ip}" 2>/dev/null || true
    done <<EOF
${targets}
EOF
  else
    yellow "未安装 traceroute/tracepath，跳过反向路由。"
  fi
}

show_nanjing_ct_local_commands() {
  load_env
  ensure_server_context
  plain "请在南京电信本地电脑运行以下命令，结果最有判断价值："
  plain ""
  plain "macOS/Linux:"
  plain "ping -c 50 ${SERVER_HOST}"
  plain "mtr -rwzc 100 ${SERVER_HOST}"
  plain "nc -vz ${SERVER_HOST} ${VLESS_PORT:-443}"
  plain "nc -vz ${SERVER_HOST} ${ANYTLS_PORT:-8443}"
  plain ""
  plain "Windows PowerShell:"
  plain "ping ${SERVER_HOST} -n 50"
  plain "tracert ${SERVER_HOST}"
  plain "Test-NetConnection ${SERVER_HOST} -Port ${VLESS_PORT:-443}"
  plain "Test-NetConnection ${SERVER_HOST} -Port ${ANYTLS_PORT:-8443}"
  plain ""
  plain "UDP 协议（Hysteria2/TUIC）不能只看 ping，重点看客户端连接后的丢包、抖动和晚高峰速度。"
}

score_east_ct_result() {
  local avg loss jitter route_ok score level
  avg="$1"
  loss="$2"
  jitter="$3"
  route_ok="$4"
  score=100

  if [ "${avg}" -gt 120 ]; then score=$((score - 35)); elif [ "${avg}" -gt 90 ]; then score=$((score - 20)); elif [ "${avg}" -gt 70 ]; then score=$((score - 10)); fi
  if [ "${loss}" -gt 3 ]; then score=$((score - 40)); elif [ "${loss}" -gt 1 ]; then score=$((score - 25)); elif [ "${loss}" -gt 0 ]; then score=$((score - 10)); fi
  if [ "${jitter}" -gt 30 ]; then score=$((score - 25)); elif [ "${jitter}" -gt 20 ]; then score=$((score - 15)); elif [ "${jitter}" -gt 10 ]; then score=$((score - 8)); fi
  if [ "${route_ok}" != "y" ] && [ "${route_ok}" != "Y" ]; then score=$((score - 20)); fi
  [ "${score}" -lt 0 ] && score=0

  if [ "${score}" -ge 85 ]; then
    level="优秀，建议保留这个 IP"
  elif [ "${score}" -ge 70 ]; then
    level="可用，晚高峰再复测一次"
  elif [ "${score}" -ge 55 ]; then
    level="一般，建议尝试换 IP 或换区域"
  else
    level="较差，不建议保留"
  fi

  plain "评分：${score}/100，结论：${level}"
}

record_east_ct_result() {
  need_root
  load_env
  ensure_server_context
  local avg loss jitter route_ok note now
  avg="$(read_default "南京电信 ping 平均延迟 ms，只填整数" "80")"
  loss="$(read_default "丢包率百分比，只填整数，例如 0/1/3" "0")"
  jitter="$(read_default "抖动 ms，只填整数；不知道填 10" "10")"
  route_ok="$(read_default "路由是否直去亚洲且未明显绕美国/欧洲？y/n" "y")"
  note="$(read_default "备注，例如 东京-甲骨文-晚高峰" "east-ct-test")"
  now="$(date '+%Y-%m-%d %H:%M:%S')"

  mkdir -p "${BASE_DIR}"
  if [ ! -f "${EAST_CT_REPORT}" ]; then
    plain "time,server,avg_ms,loss_percent,jitter_ms,route_ok,note" > "${EAST_CT_REPORT}"
  fi
  plain "${now},${SERVER_HOST:-unknown},${avg},${loss},${jitter},${route_ok},${note}" >> "${EAST_CT_REPORT}"
  score_east_ct_result "${avg}" "${loss}" "${jitter}" "${route_ok}"
  green "已记录：${EAST_CT_REPORT}"
}

show_east_ct_records() {
  need_root
  if [ -f "${EAST_CT_REPORT}" ]; then
    cat "${EAST_CT_REPORT}"
  else
    yellow "暂无华东电信测试记录。"
  fi
}

east_china_telecom_check() {
  need_root
  load_env
  ensure_server_context
  plain "南京电信 / 华东电信优化检测"
  plain "服务器：${SERVER_HOST}"
  plain "目标判断：东京/韩国优秀通常 50-90ms、丢包 0%、抖动 <10ms；晚高峰 >3% 丢包建议换 IP。"
  plain ""
  show_bbr_status
  plain ""
  show_listening_ports
  plain ""
  show_firewall_tips
  plain ""
  show_reverse_routes_to_china_telecom
  plain ""
  show_nanjing_ct_local_commands
}

east_ct_menu() {
  clear || true
  plain "南京电信 / 华东电信优化检测"
  plain "1. 一键检测本 VPS 状态、端口、反向路由"
  plain "2. 显示南京本地测速命令"
  plain "3. 记录一次南京电信测试结果并评分"
  plain "4. 查看历史测试记录"
  plain "0. 返回"
  plain ""
  read -r -p "请选择: " choice || true
  case "${choice}" in
    1) east_china_telecom_check ;;
    2) show_nanjing_ct_local_commands ;;
    3) record_east_ct_result ;;
    4) show_east_ct_records ;;
    0) menu ;;
    *) die "无效选择" ;;
  esac
}

install_all() {
  need_root
  mkdir -p "${BASE_DIR}"
  backup_current_config
  install_deps
  install_optional_tools
  download_sing_box
  collect_inputs
  if [ "${CERT_MODE:-1}" = "3" ]; then
    issue_acme_cert
  fi
  ensure_cert
  save_env
  create_server_config
  create_client_config
  create_links
  create_client_outputs
  create_qrcodes
  create_service
  "${BIN_PATH}" check -c "${CONFIG_PATH}" || die "配置检查失败，未启动服务"
  systemctl daemon-reload
  systemctl enable --now sing-box-plus
  create_cli
  green "安装完成。快捷命令：sbp"
  show_info
  show_firewall_tips
}

install_auto() {
  need_root
  mkdir -p "${BASE_DIR}"
  backup_current_config
  install_deps
  install_optional_tools
  download_sing_box
  collect_auto_inputs
  if [ "${CERT_MODE:-1}" = "3" ]; then
    issue_acme_cert
  fi
  ensure_cert
  save_env
  create_server_config
  create_client_config
  create_links
  create_client_outputs
  create_qrcodes
  create_service
  "${BIN_PATH}" check -c "${CONFIG_PATH}" || die "配置检查失败，未启动服务"
  systemctl daemon-reload
  systemctl enable --now sing-box-plus
  create_cli
  green "无交互安装完成。快捷命令：sbp"
  show_info
  show_firewall_tips
}

rebuild_after_change() {
  ensure_server_context
  backup_current_config
  if [ "${CERT_MODE:-1}" = "3" ]; then
    issue_acme_cert
  fi
  ensure_cert
  save_env
  create_server_config
  create_client_config
  create_links
  create_client_outputs
  create_qrcodes
  "${BIN_PATH}" check -c "${CONFIG_PATH}" || die "配置检查失败，已取消应用修改"
  systemctl restart sing-box-plus
  green "修改已应用并重启服务。"
  show_info
}

change_config_menu() {
  need_root
  [ -x "${BIN_PATH}" ] || die "未安装 sing-box plus"
  load_env
  ensure_server_context
  plain "修改配置"
  plain "1. 修改服务器地址/IP"
  plain "2. 修改 TLS SNI/证书域名"
  plain "3. 修改 Reality 握手域名"
  plain "4. 修改四个协议端口"
  plain "5. 重新生成 UUID"
  plain "6. 重新生成全部密码和 Reality 密钥"
  plain "7. 修改/申请证书"
  plain "0. 返回"
  plain ""
  read -r -p "请选择: " choice || true
  case "${choice}" in
    1)
      SERVER_ADDR="$(read_default "服务器公网 IP 或域名" "${SERVER_HOST}")"
      ;;
    2)
      TLS_SERVER_NAME="$(read_default "TLS SNI/证书域名" "${TLS_SERVER_NAME}")"
      ;;
    3)
      REALITY_SERVER_NAME="$(read_default "Reality 握手域名" "${REALITY_SERVER_NAME}")"
      REALITY_DEST="${REALITY_SERVER_NAME}:443"
      ;;
    4)
      VLESS_PORT="$(read_default "VLESS Reality TCP 端口" "${VLESS_PORT}")"
      ANYTLS_PORT="$(read_default "AnyTLS TCP 端口" "${ANYTLS_PORT}")"
      HY2_PORT="$(read_default "Hysteria2 UDP 端口" "${HY2_PORT}")"
      TUIC_PORT="$(read_default "TUIC v5 UDP 端口" "${TUIC_PORT}")"
      ;;
    5)
      UUID="$("${BIN_PATH}" generate uuid)"
      green "已重新生成 UUID：${UUID}"
      ;;
    6)
      UUID="$("${BIN_PATH}" generate uuid)"
      local keypair
      keypair="$("${BIN_PATH}" generate reality-keypair)"
      REALITY_PRIVATE_KEY="$(printf '%s\n' "${keypair}" | awk '/PrivateKey:/ {print $2}')"
      REALITY_PUBLIC_KEY="$(printf '%s\n' "${keypair}" | awk '/PublicKey:/ {print $2}')"
      REALITY_SHORT_ID="$(random_hex 8)"
      ANYTLS_PASSWORD="$(random_base64 24 32)"
      HY2_PASSWORD="$(random_base64 24 32)"
      HY2_OBFS="$(random_base64 16 24)"
      TUIC_PASSWORD="$(random_base64 24 32)"
      green "已重新生成 UUID、密码和 Reality 密钥。"
      ;;
    7)
      plain "TLS 证书模式："
      plain "1. 自签证书"
      plain "2. 使用已有证书"
      plain "3. 在线申请 Let's Encrypt 证书"
      CERT_MODE="$(read_default "请选择证书模式" "${CERT_MODE:-1}")"
      case "${CERT_MODE}" in
        1)
          TLS_CERT_PATH=""
          TLS_KEY_PATH=""
          ;;
        2)
          TLS_CERT_PATH="$(read_default "TLS 证书 fullchain 路径" "${TLS_CERT_PATH:-${CERT_PATH}}")"
          TLS_KEY_PATH="$(read_default "TLS 私钥路径" "${TLS_KEY_PATH:-${KEY_PATH}}")"
          ;;
        3)
          ACME_DOMAIN="$(read_default "申请证书的域名" "${TLS_SERVER_NAME}")"
          ACME_EMAIL="$(read_default "ACME 邮箱" "admin@${ACME_DOMAIN}")"
          ;;
        *) die "无效证书模式" ;;
      esac
      ;;
    0) menu ;;
    *) die "无效选择" ;;
  esac
  rebuild_after_change
}

regenerate_client_outputs() {
  need_root
  load_env
  ensure_server_context
  create_links
  create_client_outputs
  create_qrcodes
  green "客户端配置已重新生成。"
  show_info
}

show_info() {
  need_root
  load_env
  if [ -f "${LINKS_PATH}" ]; then
    plain ""
    cat "${LINKS_PATH}"
  else
    yellow "未找到节点信息，请先安装。"
  fi
  plain ""
  plain "服务状态：systemctl status sing-box-plus --no-pager"
  plain "查看日志：journalctl -u sing-box-plus -f"
  plain "客户端配置：${CLIENT_PATH}"
  plain "Mihomo/Clash 配置：${MIHOMO_PATH}"
  plain "Loon 配置草案：${LOON_PATH}"
  plain "小火箭配置草案：${SHADOWROCKET_PATH}"
  plain "小火箭分享链接：${SHADOWROCKET_LINKS_PATH}"
  plain "二维码目录：${QR_DIR}"
}

restart_service() {
  need_root
  [ -x "${BIN_PATH}" ] || die "未安装 sing-box plus"
  "${BIN_PATH}" check -c "${CONFIG_PATH}" || die "配置检查失败，已取消重启"
  systemctl restart sing-box-plus
  green "已重启 sing-box-plus"
}

show_status() {
  need_root
  systemctl status sing-box-plus --no-pager || true
}

show_logs() {
  need_root
  journalctl -u sing-box-plus -n 100 --no-pager || true
}

uninstall_all() {
  need_root
  yellow "此操作只会删除 ${BASE_DIR}、${SERVICE_PATH}、${CLI_PATH}，不会修改原 sb.sh/serv00.sh。"
  read -r -p "确认卸载请输入 YES: " confirm || true
  [ "${confirm}" = "YES" ] || die "已取消"
  systemctl disable --now sing-box-plus >/dev/null 2>&1 || true
  rm -f "${SERVICE_PATH}" "${CLI_PATH}"
  systemctl daemon-reload
  rm -rf "${BASE_DIR}"
  green "已卸载 sing-box plus"
}

menu() {
  clear || true
  plain "sing-box VPS Plus ${SCRIPT_VERSION}"
  plain "1. 安装/重新安装"
  plain "2. 查看节点信息"
  plain "3. 检查配置并重启"
  plain "4. 查看服务状态"
  plain "5. 查看最近日志"
  plain "6. 显示二维码"
  plain "7. 防火墙/安全组提示"
  plain "8. 恢复配置备份"
  plain "9. 南京电信/华东电信优化检测"
  plain "10. 修改端口/UUID/SNI/证书"
  plain "11. 重新生成客户端配置"
  plain "12. 卸载"
  plain "0. 退出"
  plain ""
  read -r -p "请选择: " choice || true
  case "${choice}" in
    1) install_all ;;
    2) show_info ;;
    3) restart_service ;;
    4) show_status ;;
    5) show_logs ;;
    6) show_qrcodes ;;
    7) show_firewall_tips ;;
    8) restore_backup ;;
    9) east_ct_menu ;;
    10) change_config_menu ;;
    11) regenerate_client_outputs ;;
    12) uninstall_all ;;
    0) exit 0 ;;
    *) die "无效选择" ;;
  esac
}

case "${1:-}" in
  auto) install_auto ;;
  install) install_all ;;
  info) show_info ;;
  change) change_config_menu ;;
  clients | output) regenerate_client_outputs ;;
  restart) restart_service ;;
  status) show_status ;;
  logs) show_logs ;;
  qrcode | qr) show_qrcodes ;;
  firewall) show_firewall_tips ;;
  restore) restore_backup ;;
  east-ct | nanjing-ct) east_ct_menu ;;
  uninstall) uninstall_all ;;
  *) menu ;;
esac
