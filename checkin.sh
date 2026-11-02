#!/usr/bin/env bash
# ============================================================================
# vsllm.cc 每日签到 —— 入口脚本
#
# 本文件现在只是「转发壳」：有 Python 就交给 checkin.py（推荐路径，能过 Cloudflare
# 质询），没有 Python 才回落到下面的纯 curl 实现（仅适用于未被质询的网络环境）。
#
# 推荐用法：
#   VSLLM_ACCESS_TOKENS='访问令牌' python3 checkin.py
#   VSLLM_COOKIE='session=...' python3 checkin.py --mode browser
#
# 本脚本等价于上面第二条命令，额外参数会原样透传，例如：
#   VSLLM_COOKIE='session=...' bash checkin.sh --mode browser --debug
# ============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY_BIN=""
for candidate in python3 python; do
  if command -v "${candidate}" >/dev/null 2>&1; then
    if "${candidate}" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)' 2>/dev/null; then
      PY_BIN="${candidate}"
      break
    fi
  fi
done

if [ -n "${PY_BIN}" ] && [ -f "${SCRIPT_DIR}/checkin.py" ]; then
  exec "${PY_BIN}" "${SCRIPT_DIR}/checkin.py" "$@"
fi

# ---------------------------------------------------------------------------
# 回退实现：纯 curl（无 Python 时）
# 注意：cf_clearance 与浏览器实例绑定，无法移植到 curl。此路径只有在网络未被
# 质询时才有意义；一旦返回 403 + Cf-Mitigated: challenge，请改用 Python 模式。
# ---------------------------------------------------------------------------
BASE_URL="${VSLLM_BASE_URL:-https://vsllm.cc}"
TOKENS="${VSLLM_ACCESS_TOKENS:-}"
VSLLM_COOKIE="${VSLLM_COOKIE:-${CF_COOKIE:-}}"
NOTIFY_URL="${NOTIFY_URL:-}"
WECOM_WEBHOOK_URL="${WECOM_WEBHOOK_URL:-}"
UA="${VSLLM_UA:-Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36}"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

notify() {
  [ -z "${NOTIFY_URL}" ] && [ -z "${WECOM_WEBHOOK_URL}" ] && return 0
  if [ -n "${WECOM_WEBHOOK_URL}" ]; then
    local payload
    payload="$(printf '%s\n%s' "$1" "$2" | python3 -c 'import json,sys;print(json.dumps({"msgtype":"text","text":{"content":sys.stdin.read()}},ensure_ascii=False))' 2>/dev/null)" || return 0
    curl -sS -m 15 -X POST "${WECOM_WEBHOOK_URL}" -H "Content-Type: application/json" -d "${payload}" >/dev/null 2>&1 || log "企业微信通知发送失败"
    return 0
  fi
  curl -sS -m 15 -X POST "${NOTIFY_URL}" \
    --data-urlencode "title=$1" --data-urlencode "desp=$2" >/dev/null 2>&1 || log "通知发送失败"
}

if [ -z "${TOKENS}" ] && [ -z "${VSLLM_COOKIE}" ]; then
  log "错误：未设置 VSLLM_ACCESS_TOKENS 或 VSLLM_COOKIE"
  exit 1
fi

ok=0; total=0; summary=""
tmp_body="$(mktemp)"; tmp_hdr="$(mktemp)"
trap 'rm -f "${tmp_body}" "${tmp_hdr}"' EXIT

do_checkin() {
  local label="$1"; shift
  total=$((total+1))
  log "${label}：签到中 -> ${BASE_URL%/}/api/user/checkin"
  local code
  code="$(curl -sS -m 30 -o "${tmp_body}" -D "${tmp_hdr}" -w '%{http_code}' "$@" 2>/dev/null)" || {
    log "${label}：网络请求失败"; summary="${summary}${label}：网络请求失败\n"; return; }

  # 质询判定：状态码 + Cf-Mitigated 头（比 grep 页面文案可靠）
  if [ "${code}" = "403" ] && grep -qi '^cf-mitigated:[[:space:]]*challenge' "${tmp_hdr}"; then
    log "${label}：被 Cloudflare 质询（cf_clearance 不可移植，请改用 python3 checkin.py --mode browser）"
    summary="${summary}${label}：Cloudflare 拦截\n"
    return
  fi

  local resp msg
  resp="$(cat "${tmp_body}")"
  msg="$(printf '%s' "${resp}" | sed -n 's/.*"message"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
  if printf '%s' "${resp}" | grep -q '"success"[[:space:]]*:[[:space:]]*true'; then
    log "${label}：✅ ${msg:-签到成功}"; summary="${summary}${label}：✅ ${msg:-签到成功}\n"; ok=$((ok+1))
  elif printf '%s' "${msg}" | grep -qE '已经签到|已签到|明天再来'; then
    log "${label}：✅ ${msg}"; summary="${summary}${label}：✅ ${msg}\n"; ok=$((ok+1))
  else
    log "${label}：⚠️ ${msg:-签到失败}（HTTP ${code}）"; summary="${summary}${label}：⚠️ ${msg:-签到失败}\n"
  fi
}

common_headers=(
  -H "User-Agent: ${UA}"
  -H "Accept: application/json, text/plain, */*"
  -H "Referer: ${BASE_URL%/}/profile"
  -H "Origin: ${BASE_URL%/}"
  -H "Content-Type: application/json"
  -d '{}'
)

if [ -n "${VSLLM_COOKIE}" ]; then
  do_checkin "Cookie账号" -X POST "${BASE_URL%/}/api/user/checkin" \
    -H "Cookie: ${VSLLM_COOKIE}" "${common_headers[@]}"
else
  IFS=',' read -ra token_list <<< "${TOKENS}"
  for idx in "${!token_list[@]}"; do
    token="$(echo "${token_list[$idx]}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    [ -z "${token}" ] && continue
    do_checkin "账号 $((idx+1))" -X POST "${BASE_URL%/}/api/user/checkin" \
      -H "Authorization: Bearer ${token}" "${common_headers[@]}"
  done
fi

log "=============================================="
log "签到汇总：成功 ${ok}/${total}"
log "=============================================="
echo -e "${summary}"
notify "vsllm 签到：${ok}/${total} 成功" "$(echo -e "${summary}")"
[ "${ok}" -gt 0 ]
