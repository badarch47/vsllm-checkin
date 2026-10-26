#!/usr/bin/env bash
# ============================================================================
# vsllm.cc 每日自动签到脚本（New API 网关）
#
# 接口：POST /api/user/checkin
#
# 认证方式（二选一，Cookie 优先）：
#   A. VSLLM_COOKIE  浏览器完整 Cookie 串（推荐被 Cloudflare 质询时用）
#      必须包含 cf_clearance（过质询）和 session（登录态），单账号
#   B. VSLLM_ACCESS_TOKENS  访问令牌 Bearer 认证（多账号，英文逗号分隔）
#      令牌获取：登录 vsllm.cc -> 个人资料 -> 安全设置 -> 访问令牌 -> 生成
#      （≠ 令牌页的 sk-xxx API Key！）
#
# 环境变量：
#   VSLLM_ACCESS_TOKENS  可选，访问令牌，多账号用英文逗号分隔
#   VSLLM_COOKIE         可选，浏览器完整 Cookie 串（含 cf_clearance/session 等）
#   CF_COOKIE            VSLLM_COOKIE 的兼容别名（旧配置仍可用）
#   VSLLM_BASE_URL       可选，站点地址，默认 https://vsllm.cc
#   VSLLM_UA             可选，浏览器 User-Agent（被质询时须与签发 Cookie 的浏览器一致）
#   NOTIFY_URL           可选，推送地址（Server酱/Bark，POST title/desp 表单）
#   WECOM_WEBHOOK_URL    可选，企业微信群机器人 Webhook 地址（优先级高于 NOTIFY_URL）
# ============================================================================
set -uo pipefail

BASE_URL="${VSLLM_BASE_URL:-https://vsllm.cc}"
TOKENS="${VSLLM_ACCESS_TOKENS:-}"
VSLLM_COOKIE="${VSLLM_COOKIE:-${CF_COOKIE:-}}"
NOTIFY_URL="${NOTIFY_URL:-}"
WECOM_WEBHOOK_URL="${WECOM_WEBHOOK_URL:-}"
UA="${VSLLM_UA:-Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36}"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

notify() {
  [ -z "${NOTIFY_URL}" ] && [ -z "${WECOM_WEBHOOK_URL}" ] && return 0
  if [ -n "${WECOM_WEBHOOK_URL}" ]; then
    # 企业微信群机器人通知（Webhook JSON，python3 负责 JSON 转义，GitHub Actions 自带）
    local payload
    payload="$(printf '%s\n%s' "$1" "$2" | python3 -c 'import json,sys;print(json.dumps({"msgtype":"text","text":{"content":sys.stdin.read()}},ensure_ascii=False))')"
    curl -sS -m 15 -X POST "${WECOM_WEBHOOK_URL}" \
      -H "Content-Type: application/json" \
      -d "${payload}" >/dev/null 2>&1 || log "企业微信通知发送失败"
    return 0
  fi
  curl -sS -m 15 -X POST "${NOTIFY_URL}" \
    --data-urlencode "title=$1" \
    --data-urlencode "desp=$2" >/dev/null 2>&1 || log "通知发送失败"
}

if [ -z "${TOKENS}" ] && [ -z "${VSLLM_COOKIE}" ]; then
  log "错误：未设置 VSLLM_ACCESS_TOKENS 或 VSLLM_COOKIE"
  log "用法：VSLLM_COOKIE='完整Cookie串' bash checkin.sh  或  VSLLM_ACCESS_TOKENS='访问令牌' bash checkin.sh"
  exit 1
fi

ok=0
total=0
summary=""

do_checkin() {
  local label="$1"; shift
  total=$((total+1))
  log "${label}：签到中 -> ${BASE_URL}/api/user/checkin"
  local resp
  resp="$(curl "$@" 2>&1)" || { log "${label}：网络请求失败"; summary="${summary}${label}：网络请求失败\n"; return; }
  if echo "${resp}" | grep -q "Just a moment"; then
    log "${label}：被 Cloudflare 质询拦截（403），Cookie 已过期或 IP/UA 与签发时不匹配"
    summary="${summary}${label}：Cloudflare 拦截\n"
    return
  fi
  if echo "${resp}" | grep -q '"success"[[:space:]]*:[[:space:]]*true'; then
    msg="$(echo "${resp}" | sed -n 's/.*"message"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
    log "${label}：✅ ${msg:-签到成功}"
    summary="${summary}${label}：✅ ${msg:-签到成功}\n"
    ok=$((ok+1))
  else
    msg="$(echo "${resp}" | sed -n 's/.*"message"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
    log "${label}：⚠️ ${msg:-签到失败}（响应：${resp}）"
    summary="${summary}${label}：⚠️ ${msg:-签到失败}\n"
  fi
}

common_headers=(
  -H "User-Agent: ${UA}"
  -H "Accept: application/json, text/plain, */*"
  -H "Referer: ${BASE_URL%/}/profile"
  -H "Content-Type: application/json"
  -d '{}'
)

if [ -n "${VSLLM_COOKIE}" ]; then
  # 模式 A：浏览器完整 Cookie 串（单账号，Cookie 内含 cf_clearance 过质询 + session 登录态）
  do_checkin "Cookie账号" -sS -m 30 -X POST "${BASE_URL%/}/api/user/checkin" \
    -H "Cookie: ${VSLLM_COOKIE}" "${common_headers[@]}"
else
  # 模式 B：访问令牌 Bearer 认证（多账号）
  IFS=',' read -ra token_list <<< "${TOKENS}"
  for idx in "${!token_list[@]}"; do
    token="$(echo "${token_list[$idx]}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    [ -z "${token}" ] && continue
    do_checkin "账号 $((idx+1))" -sS -m 30 -X POST "${BASE_URL%/}/api/user/checkin" \
      -H "Authorization: Bearer ${token}" "${common_headers[@]}"
  done
fi

log "=============================================="
log "签到汇总：成功 ${ok}/${total}"
log "=============================================="
echo -e "${summary}"

notify "vsllm 签到：${ok}/${total} 成功" "$(echo -e "${summary}")"

[ "${ok}" -gt 0 ]
