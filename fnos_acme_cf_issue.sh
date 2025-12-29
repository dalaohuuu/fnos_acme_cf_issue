#!/usr/bin/env bash
set -euo pipefail

# =========================================================
# FnOS + acme.sh + Cloudflare DNS (dns_cf) 证书自动化（示例脚本）
#
# - 默认 dry-run：只打印将执行的命令，不修改系统
# - --apply 才会真实执行：签发证书、写入飞牛目录、更新DB/配置、重启服务
#
# 配置文件：脚本同目录下 ENV_FILE
# =========================================================

MODE="dry-run"
case "${1:-}" in
  --apply)   MODE="apply" ;;
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
  echo "   请先按 README 使用 tee 创建 ENV_FILE 并填写配置。"
  exit 1
fi

# shellcheck disable=SC1090
source "${ENV_PATH}"

need_var() { [[ -n "${!1:-}" ]] || { echo "❌ 缺少配置变量：$1"; exit 1; }; }

need_var DOMAIN
need_var CF_TOKEN
need_var SSLS_DIR
need_var NGX_CONF
need_var DB_NAME
need_var DB_USER
need_var RELOAD_CMD

WILDCARD="${WILDCARD:-yes}"
DNS_SLEEP="${DNS_SLEEP:-120}"
CERT_SERVER="${CERT_SERVER:-letsencrypt}"
CLEAN_OLD_DAYS="${CLEAN_OLD_DAYS:-90}"

if [[ "${MODE}" == "apply" && $EUID -ne 0 ]]; then
  echo "❌ --apply 需要 root 权限运行（sudo -i 后执行）"
  exit 1
fi

log() { echo -e "$*"; }

run() {
  if [[ "${MODE}" == "apply" ]]; then
    log "▶ $*"
    eval "$@"
  else
    log "[dry-run] $*"
  fi
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "❌ 缺少命令：$1"; exit 1; }
}

# 最基础的命令检查（dry-run 也检查，避免用户 apply 时才踩坑）
for c in curl socat openssl psql sed awk grep date; do
  require_cmd "$c"
done

if [[ ! -f "${NGX_CONF}" ]]; then
  echo "❌ 找不到飞牛 nginx 证书配置文件：${NGX_CONF}"
  exit 1
fi

TT="$(date +%s%3N)"
ACME="/root/.acme.sh/acme.sh"

# ============ dry-run：不执行 acme、不改系统，只展示计划 ============
if [[ "${MODE}" == "dry-run" ]]; then
  log ""
  log "==> 将使用以下配置："
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

  log "==> 计划执行的关键步骤（不会真正执行）："
  log "[dry-run] 安装依赖（若缺失）：curl socat ca-certificates openssl postgresql-client"
  log "[dry-run] 安装 acme.sh（若未安装）：curl https://get.acme.sh | sh"
  if [[ "${WILDCARD}" == "yes" ]]; then
    log "[dry-run] 签发证书：${ACME} --issue --dns dns_cf --dnssleep ${DNS_SLEEP} -d ${DOMAIN} -d *.${DOMAIN} --server ${CERT_SERVER}"
  else
    log "[dry-run] 签发证书：${ACME} --issue --dns dns_cf --dnssleep ${DNS_SLEEP} -d ${DOMAIN} --server ${CERT_SERVER}"
  fi
  log "[dry-run] 解析 acme.sh --info 的 CertCreateTime/NextRenewTime 生成时间戳目录"
  log "[dry-run] 创建目录：${SSLS_DIR}/${DOMAIN}/<timestamp>/"
  log "[dry-run] install-cert 写入：${DOMAIN}.crt/.key/fullchain.crt/issuer_certificate.crt"
  log "[dry-run] 更新数据库：trim_connect.cert（插入/更新 domain=${DOMAIN} 的证书路径与有效期等字段）"
  log "[dry-run] 更新 nginx 配置：${NGX_CONF}"
  log "[dry-run] 清理旧证书目录：${SSLS_DIR}/${DOMAIN}/ 超过 ${CLEAN_OLD_DAYS} 天"
  log "[dry-run] 重启服务：${RELOAD_CMD}"
  log ""
  log "✅ dry-run 完成：如确认无误，请执行："
  log "   sudo -i"
  log "   ./fnos_acme_cf_issue.sh --apply"
  exit 0
fi

# ============ apply：真实执行 ============
log "==> [0/7] 安装依赖（Debian/Ubuntu 系）..."
if command -v apt >/dev/null 2>&1; then
  run "apt update -y"
  run "apt install -y curl socat ca-certificates openssl postgresql-client"
fi

log "==> [1/7] 安装 acme.sh（若未安装）..."
if [[ ! -x "${ACME}" ]]; then
  run "curl https://get.acme.sh | sh"
fi
if [[ ! -x "${ACME}" ]]; then
  echo "❌ acme.sh 未找到或不可执行：${ACME}"
  exit 1
fi

log "==> [2/7] 使用 Cloudflare DNS API 签发证书..."
export CF_Token="${CF_TOKEN}"

ISSUE_ARGS=(--force --log --issue --server "${CERT_SERVER}" --dns dns_cf --dnssleep "${DNS_SLEEP}" -d "${DOMAIN}")
if [[ "${WILDCARD}" == "yes" ]]; then
  ISSUE_ARGS+=(-d "*.${DOMAIN}")
fi
run "${ACME} ${ISSUE_ARGS[*]}"

log "==> [3/7] 解析证书时间并创建飞牛证书目录..."
CertCreateTime="$("${ACME}" --info -d "${DOMAIN}" | grep CertCreateTimeStr= | awk -F= '{print $2}' | sed 's|T| |g; s|Z||g')"
NextRenewTime="$("${ACME}" --info -d "${DOMAIN}" | grep Le_NextRenewTimeStr= | awk -F= '{print $2}' | sed 's|T| |g; s|Z||g')"

CERT_CREATE_SEC="$(date -d "${CertCreateTime}" +%s)"
CERT_CREATE_TT="$(date -d "${CertCreateTime}" +%s%3N)"
CERT_RENEW_TT="$(date -d "${NextRenewTime} 1 month" +%s%3N)"

DOMAIN_SSL_DIR="${SSLS_DIR}/${DOMAIN}/${CERT_CREATE_SEC}"
run "mkdir -p '${DOMAIN_SSL_DIR}'"

log "==> [4/7] install-cert 写入飞牛目录 + 重启服务..."
run "${ACME} --install-cert -d '${DOMAIN}' \
  --cert-file '${DOMAIN_SSL_DIR}/${DOMAIN}.crt' \
  --key-file '${DOMAIN_SSL_DIR}/${DOMAIN}.key' \
  --fullchain-file '${DOMAIN_SSL_DIR}/fullchain.crt' \
  --ca-file '${DOMAIN_SSL_DIR}/issuer_certificate.crt' \
  --reloadcmd \"${RELOAD_CMD}\""

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
  run "psql -U '${DB_USER}' -d '${DB_NAME}' -c \
\"UPDATE cert SET
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
WHERE domain='${DOMAIN}';\""
else
  DOMAIN_ID="$(( $(psql -t -A -U "${DB_USER}" -d "${DB_NAME}" -c "SELECT id FROM cert ORDER BY id ASC;" | awk 'END{print}' | sed '/^\s*$/d') + 1 ))"
  run "psql -U '${DB_USER}' -d '${DB_NAME}' -c \
\"INSERT INTO cert VALUES (
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
);\""
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
