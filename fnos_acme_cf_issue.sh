#!/usr/bin/env bash
set -euo pipefail

# =========================================================
# FnOS + acme.sh + Cloudflare DNS (dns_cf) 示例脚本
#
# - 默认 dry-run：只打印将执行的操作，不修改系统
# - --apply 才会真实执行：签发证书、写入飞牛目录、更新DB/配置、重启服务
# - 配置文件：脚本同目录下 ENV_FILE
# - 依赖自动安装：仅处理 socat（Debian/Ubuntu: apt install socat）
# =========================================================

MODE="dry-run"
case "${1:-}" in
  --apply) MODE="apply" ;;
  --dry-run|"") MODE="dry-run" ;;
  *)
    echo "Usage: $0 [--dry-run|--apply]"
    exit 1
    ;;
esac

echo "==> 运行模式：${MODE}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_PATH="${SCRIPT_DIR}/ENV_FILE"

if [[ ! -f "${ENV_PATH}" ]]; then
  echo "❌ 未找到 ENV_FILE：${ENV_PATH}"
  echo "   请先按 README 用 tee 创建 ENV_FILE 并填写配置。"
  exit 1
fi

# shellcheck disable=SC1090
source "${ENV_PATH}"

need() { [[ -n "${!1:-}" ]] || { echo "❌ 缺少配置变量：$1"; exit 1; }; }

need DOMAIN
need CF_TOKEN
need SSLS_DIR
need NGX_CONF
need DB_NAME
need DB_USER
need RELOAD_CMD

WILDCARD="${WILDCARD:-yes}"
DNS_SLEEP="${DNS_SLEEP:-120}"
CERT_SERVER="${CERT_SERVER:-letsencrypt}"
CLEAN_OLD_DAYS="${CLEAN_OLD_DAYS:-90}"

log() { echo -e "$*"; }

# dry-run/ apply 统一的执行封装
run() {
  if [[ "${MODE}" == "apply" ]]; then
    log "▶ $*"
    eval "$@"
  else
    log "[dry-run] $*"
  fi
}

# apply 必须 root
if [[ "${MODE}" == "apply" && $EUID -ne 0 ]]; then
  echo "❌ --apply 需要 root 权限运行（sudo -i 后执行）"
  exit 1
fi

# ============ 仅处理 socat 的依赖 ============
HAVE_SOCAT="yes"
if ! command -v socat >/dev/null 2>&1; then
  HAVE_SOCAT="no"
fi

if [[ "${MODE}" == "dry-run" ]]; then
  if [[ "${HAVE_SOCAT}" == "no" ]]; then
    log "==> dry-run：检测到缺少依赖 socat（不会自动安装）"
    log "    在 --apply 模式下将自动尝试使用 apt 安装 socat"
  else
    log "==> dry-run：依赖 socat 已满足"
  fi
fi

if [[ "${MODE}" == "apply" && "${HAVE_SOCAT}" == "no" ]]; then
  log "==> 安装依赖 socat ..."
  if command -v apt >/dev/null 2>&1; then
    apt update -y
    apt install -y socat
  else
    echo "❌ 未找到 apt，无法自动安装 socat，请手动安装后再运行。"
    exit 1
  fi
fi

# 基本命令检查（不自动装，缺了就提示）
require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "❌ 缺少命令：$1"; exit 1; }
}
for c in curl openssl psql sed awk grep date; do
  require_cmd "$c"
done

if [[ ! -f "${NGX_CONF}" ]]; then
  echo "❌ 找不到飞牛 nginx 证书配置文件：${NGX_CONF}"
  exit 1
fi

TT="$(date +%s%3N)"
ACME="/root/.acme.sh/acme.sh"

export CF_Token="${CF_TOKEN}"

# ============ dry-run：只展示计划 ============
if [[ "${MODE}" == "dry-run" ]]; then
  log ""
  log "==> dry-run 配置预览："
  log "DOMAIN=${DOMAIN}"
  log "WILDCARD=${WILDCARD}"
  log "DNS_SLEEP=${DNS_SLEEP}"
  log "CERT_SERVER=${CERT_SERVER}"
  log "SSLS_DIR=${SSLS_DIR}"
  log "NGX_CONF=${NGX_CONF}"
  log "DB_NAME=${DB_NAME}"
  log "DB_USER=${DB_USER}"
  log "RELOAD_CMD=${RELOAD_CMD}"
  log "CLEAN_OLD_DAYS=${CLEAN_OLD_DAYS}"
  log ""
  log "==> dry-run 计划执行："
  log "[dry-run] 安装 acme.sh（若未安装）：curl https://get.acme.sh | sh"
  if [[ "${WILDCARD}" == "yes" ]]; then
    log "[dry-run] 签发证书：${ACME} --issue --dns dns_cf --dnssleep ${DNS_SLEEP} -d ${DOMAIN} -d *.${DOMAIN} --server ${CERT_SERVER}"
  else
    log "[dry-run] 签发证书：${ACME} --issue --dns dns_cf --dnssleep ${DNS_SLEEP} -d ${DOMAIN} --server ${CERT_SERVER}"
  fi
  log "[dry-run] 证书写入目录：${SSLS_DIR}/${DOMAIN}/{timestamp}/"
  log "[dry-run] 更新数据库：${DB_NAME}.cert（插入/更新 domain=${DOMAIN} 的记录）"
  log "[dry-run] 更新 nginx 配置：${NGX_CONF}"
  log "[dry-run] 清理旧目录：${SSLS_DIR}/${DOMAIN}/ 超过 ${CLEAN_OLD_DAYS} 天"
  log "[dry-run] 重启服务：${RELOAD_CMD}"
  log ""
  log "✅ dry-run 完成：如确认无误，请执行："
  log "   sudo -i"
  log "   ./fnos_acme_cf_issue.sh --apply"
  exit 0
fi

# ===================== apply：真实执行 =====================

log "==> [1/7] 安装 acme.sh（若未安装）..."
if [[ ! -x "${ACME}" ]]; then
  run "curl https://get.acme.sh | sh"
fi
if [[ ! -x "${ACME}" ]]; then
  echo "❌ acme.sh 未找到或不可执行：${ACME}"
  exit 1
fi

log "==> [2/7] 申请证书（Cloudflare DNS）..."
ISSUE_ARGS=(--force --log --issue --server "${CERT_SERVER}" --dns dns_cf --dnssleep "${DNS_SLEEP}" -d "${DOMAIN}")
if [[ "${WILDCARD}" == "yes" ]]; then
  ISSUE_ARGS+=(-d "*.${DOMAIN}")
fi
"${ACME}" "${ISSUE_ARGS[@]}"

log "==> [3/7] 解析证书时间并创建飞牛证书目录..."
CertCreateTime="$("${ACME}" --info -d "${DOMAIN}" | grep CertCreateTimeStr= | awk -F= '{print $2}' | sed 's|T| |g; s|Z||g')"
NextRenewTime="$("${ACME}" --info -d "${DOMAIN}" | grep Le_NextRenewTimeStr= | awk -F= '{print $2}' | sed 's|T| |g; s|Z||g')"

CERT_CREATE_SEC="$(date -d "${CertCreateTime}" +%s)"
CERT_CREATE_TT="$(date -d "${CertCreateTime}" +%s%3N)"
CERT_RENEW_TT="$(date -d "${NextRenewTime} 1 month" +%s%3N)"

DOMAIN_SSL_DIR="${SSLS_DIR}/${DOMAIN}/${CERT_CREATE_SEC}"
run "mkdir -p '${DOMAIN_SSL_DIR}'"

log "==> [4/7] install-cert 写入飞牛目录并重启服务..."
"${ACME}" --install-cert -d "${DOMAIN}" \
  --cert-file      "${DOMAIN_SSL_DIR}/${DOMAIN}.crt" \
  --key-file       "${DOMAIN_SSL_DIR}/${DOMAIN}.key" \
  --fullchain-file "${DOMAIN_SSL_DIR}/fullchain.crt" \
  --ca-file        "${DOMAIN_SSL_DIR}/issuer_certificate.crt" \
  --reloadcmd      "${RELOAD_CMD}"

run "chmod 755 '${DOMAIN_SSL_DIR}/${DOMAIN}.crt' '${DOMAIN_SSL_DIR}/${DOMAIN}.key' '${DOMAIN_SSL_DIR}/fullchain.crt' '${DOMAIN_SSL_DIR}/issuer_certificate.crt'"

log "==> [5/7] 读取证书信息并更新/插入数据库..."
CERT_ISSUED_BY="$(openssl x509 -in "${DOMAIN_SSL_DIR}/${DOMAIN}.crt" -noout -issuer | awk -F' = ' '{print $4}')"
SIG_ALGO="$(openssl x509 -in "${DOMAIN_SSL_DIR}/${DOMAIN}.crt" -noout -text | awk '/Signature Algorithm/ {print $3}' | awk 'END{print}')"

shopt -s nocasematch
case "${SIG_ALGO}" in
  *RSA*)   ALGO_TYPE="RSA" ;;
  *ECDSA*) ALGO_TYPE="ECDSA" ;;
  *ECC*)   ALGO_TYPE="ECC" ;;
  *SM2*)   ALGO_TYPE="SM2" ;;
  *)       ALGO_TYPE="UNKNOW" ;;
esac
shopt -u nocasematch

EXIST_DOMAIN="$(psql -t -A -U "${DB_USER}" -d "${DB_NAME}" -c "SELECT domain FROM cert WHERE domain='${DOMAIN}';" | sed '/^\s*$/d' || true)"

if [[ -n "${EXIST_DOMAIN}" ]]; then
  psql -U "${DB_USER}" -d "${DB_NAME}" -c \
"UPDATE cert SET
  valid_from=${CERT_CREATE_TT},
  valid_to=${CERT_RENEW_TT},
  encrypt_type='${ALGO_TYPE}',
  issued_by='${CERT_ISSUED_BY}',
  last_renew_time=${TT},
  des='由acme.sh(dns_cf)自动生成的证书（示例脚本）',
  private_key='${DOMAIN_SSL_DIR}/${DOMAIN}.key',
  certificate='${DOMAIN_SSL_DIR}/${DOMAIN}.crt',
  issuer_certificate='${DOMAIN_SSL_DIR}/issuer_certificate.crt',
  status='suc',
  created_time=${TT},
  updated_time=${TT}
WHERE domain='${DOMAIN}';" >/dev/null
else
  DOMAIN_ID="$(( $(psql -t -A -U "${DB_USER}" -d "${DB_NAME}" -c "SELECT id FROM cert ORDER BY id ASC;" | awk 'END{print}' | sed '/^\s*$/d') + 1 ))"
  psql -U "${DB_USER}" -d "${DB_NAME}" -c \
"INSERT INTO cert VALUES (
  ${DOMAIN_ID},
  '${DOMAIN}',
  '*.${DOMAIN},${DOMAIN}',
  ${CERT_CREATE_TT},
  ${CERT_RENEW_TT},
  '${ALGO_TYPE}',
  '${CERT_ISSUED_BY}',
  ${TT},
  '由acme.sh(dns_cf)自动生成的证书（示例脚本）',
  0,
  null,
  'upload',
  null,
  '${DOMAIN_SSL_DIR}/${DOMAIN}.key',
  '${DOMAIN_SSL_DIR}/${DOMAIN}.crt',
  '${DOMAIN_SSL_DIR}/issuer_certificate.crt',
  'suc',
  ${TT},
  ${TT}
);" >/dev/null
fi

log "==> [6/7] 更新飞牛 nginx 证书配置..."
run "cp -fL '${NGX_CONF}' '${NGX_CONF}.${TT}.bak'"

NETWORK_GATEWAY_CERT="{\"host\":\"${DOMAIN}\",\"cert\":\"${DOMAIN_SSL_DIR}/fullchain.crt\",\"key\":\"${DOMAIN_SSL_DIR}/${DOMAIN}.key\"},"

if grep -qE "${DOMAIN}" "${NGX_CONF}"; then
  run "sed -i \"s|{\\\"host\\\":.*${DOMAIN}.*},|${NETWORK_GATEWAY_CERT}|g\" '${NGX_CONF}'"
else
  run "awk '{gsub(/^./,\"\"); print}' '${NGX_CONF}' > /tmp/fn_ngw_cert"
  run "sed -i \"1i[${NETWORK_GATEWAY_CERT}\" /tmp/fn_ngw_cert"
  run "sed -i ':a;N;\$!ba;s/\\n//g' /tmp/fn_ngw_cert"
  run "cp -fL /tmp/fn_ngw_cert '${NGX_CONF}'"
  run "rm -f /tmp/fn_ngw_cert"
fi

grep -qE "${DOMAIN_SSL_DIR}" "${NGX_CONF}" || { echo "❌ nginx 配置写入失败：未发现 ${DOMAIN_SSL_DIR}"; exit 1; }

log "==> [7/7] 清理旧证书目录与旧备份..."
run "find '${SSLS_DIR}/${DOMAIN}/' -mtime +${CLEAN_OLD_DAYS} -type d -exec rm -rf {} \\; >/dev/null 2>&1 || true"
run "find '$(dirname "${NGX_CONF}")' -mtime +${CLEAN_OLD_DAYS} -name '$(basename "${NGX_CONF}").*.bak' -exec rm -rf {} \\; >/dev/null 2>&1 || true"

run "cat > '${SSLS_DIR}/${DOMAIN}/sslpath.conf' <<EOF
DOMAIN=${DOMAIN}
CERT_CREATE_TT=${CERT_CREATE_TT}
CERT_RENEW_TT=${CERT_RENEW_TT}
ALGO_TYPE=${ALGO_TYPE}
CERT_ISSUED_BY=${CERT_ISSUED_BY}
TT=${TT}
DOMAIN_SSL_DIR=${DOMAIN_SSL_DIR}
EOF"

log "✅ 完成：${DOMAIN_SSL_DIR}"
