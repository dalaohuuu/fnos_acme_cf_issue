#!/usr/bin/env bash
set -euo pipefail

# =========================================================
# 用法
#   ./fnos_acme_cf_issue.sh            # 等同 --dry-run（默认）
#   ./fnos_acme_cf_issue.sh --dry-run
#   ./fnos_acme_cf_issue.sh --apply    # ⚠️ 真正修改系统
# =========================================================

MODE="dry-run"
[[ "${1:-}" == "--apply" ]] && MODE="apply"
[[ "${1:-}" == "--dry-run" ]] && MODE="dry-run"

echo "==> 运行模式：${MODE}"

# =========================================================
# 载入 .env
# =========================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "❌ 未找到 .env，请先："
  echo "   cp .env.example .env"
  exit 1
fi

# shellcheck disable=SC1090
source "${ENV_FILE}"

# =========================================================
# 工具函数
# =========================================================
need() { [[ -n "${!1:-}" ]] || { echo "❌ 缺少变量：$1"; exit 1; }; }

run() {
  if [[ "${MODE}" == "apply" ]]; then
    echo "▶ $*"
    eval "$@"
  else
    echo "[dry-run] $*"
  fi
}

# =========================================================
# 基本检查
# =========================================================
need DOMAIN
need CF_TOKEN
need SSLS_DIR
need NGX_CONF
need DB_NAME
need DB_USER
need RELOAD_CMD

[[ $EUID -eq 0 ]] || {
  echo "❌ 必须 root 运行（sudo -i）"
  exit 1
}

for c in curl socat openssl psql sed awk grep date; do
  command -v "$c" >/dev/null || { echo "❌ 缺少命令：$c"; exit 1; }
done

# =========================================================
# 时间与 acme.sh
# =========================================================
TT=$(date +%s%3N)
ACME="/root/.acme.sh/acme.sh"

if [[ ! -x "${ACME}" ]]; then
  run "curl https://get.acme.sh | sh"
fi

export CF_Token="${CF_TOKEN}"

# =========================================================
# 1️⃣ 申请证书
# =========================================================
ISSUE_ARGS="--issue --dns dns_cf --dnssleep ${DNS_SLEEP:-120} -d ${DOMAIN}"
[[ "${WILDCARD:-yes}" == "yes" ]] && ISSUE_ARGS+=" -d *.${DOMAIN}"

run "${ACME} --force --log --server ${CERT_SERVER:-letsencrypt} ${ISSUE_ARGS}"

# =========================================================
# 2️⃣ 计算证书时间
# =========================================================
CertCreateTime="$(${ACME} --info -d "${DOMAIN}" | grep CertCreateTimeStr= | cut -d= -f2 | sed 's/T/ /;s/Z//')"
NextRenewTime="$(${ACME} --info -d "${DOMAIN}" | grep Le_NextRenewTimeStr= | cut -d= -f2 | sed 's/T/ /;s/Z//')"

CERT_CREATE_SEC=$(date -d "${CertCreateTime}" +%s)
CERT_CREATE_TT=$(date -d "${CertCreateTime}" +%s%3N)
CERT_RENEW_TT=$(date -d "${NextRenewTime} 1 month" +%s%3N)

DOMAIN_SSL_DIR="${SSLS_DIR}/${DOMAIN}/${CERT_CREATE_SEC}"

run "mkdir -p ${DOMAIN_SSL_DIR}"

# =========================================================
# 3️⃣ 安装证书
# =========================================================
run "${ACME} --install-cert -d ${DOMAIN} \
  --cert-file ${DOMAIN_SSL_DIR}/${DOMAIN}.crt \
  --key-file ${DOMAIN_SSL_DIR}/${DOMAIN}.key \
  --fullchain-file ${DOMAIN_SSL_DIR}/fullchain.crt \
  --ca-file ${DOMAIN_SSL_DIR}/issuer_certificate.crt \
  --reloadcmd \"${RELOAD_CMD}\""

run "chmod 755 ${DOMAIN_SSL_DIR}/*"

# =========================================================
# 4️⃣ 更新数据库
# =========================================================
SQL_UPDATE=\"UPDATE cert SET valid_from=${CERT_CREATE_TT}, valid_to=${CERT_RENEW_TT}, updated_time=${TT} WHERE domain='${DOMAIN}';\"
run "psql -U ${DB_USER} -d ${DB_NAME} -c ${SQL_UPDATE}"

# =========================================================
# 5️⃣ 更新 nginx 配置
# =========================================================
NGX_LINE="{\"host\":\"${DOMAIN}\",\"cert\":\"${DOMAIN_SSL_DIR}/fullchain.crt\",\"key\":\"${DOMAIN_SSL_DIR}/${DOMAIN}.key\"},"

run "cp ${NGX_CONF} ${NGX_CONF}.${TT}.bak"
run "sed -i \"s|{\\\"host\\\":.*${DOMAIN}.*},|${NGX_LINE}|g\" ${NGX_CONF}"

# =========================================================
# 6️⃣ 清理旧证书
# =========================================================
run "find ${SSLS_DIR}/${DOMAIN}/ -mtime +${CLEAN_OLD_DAYS:-90} -type d -exec rm -rf {} \\;"

# =========================================================
# 完成
# =========================================================
echo "✅ 完成（模式：${MODE}）"
echo "证书目录：${DOMAIN_SSL_DIR}"

[[ "${MODE}" == "dry-run" ]] && echo "ℹ️ 未修改系统，使用 --apply 才会真正执行"
