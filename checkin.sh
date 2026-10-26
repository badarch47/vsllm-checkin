#!/usr/bin/env bash
# ============================================================================
# vsllm.cc 每日自动签到脚本（New API 网关）
#
# 接口：POST /api/user/checkin
# 认证：Authorization: Bearer <访问令牌>
#   （访问令牌 ≠ 令牌页的 sk-xxx API Key！）
#   获取：登录 https://vsllm.cc -> 个人资料 -> 安全设置 -> 访问令牌 -> 生成
#
# 环境变量：
#   VSLLM_ACCESS_TOKENS  必填，访问令牌，多账号用英文逗号分隔
#   VSLLM_BASE_URL       可选，站点地址，默认 https://vsllm.cc
#   NOTIFY_URL           可选，推送地址（Server酱/Bark，POST title/desp 表单）
#   WECOM_WEBHOOK_URL    可选，企业微信群机器人 Webhook 地址（优先级高于 NOTIFY_URL）
#   CF_COOKIE            可选，浏览器 Cloudflare 会话 Cookie（被质询时用）
# ============================================================================
set -uo pipefail

BASE_URL="${VSLLM_BASE_URL:-https://vsllm.cc}"
TOKENS="${VSLLM_ACCESS_TOKENS:-}"
NOTIFY_URL="${NOTIFY_URL:-}"
WECOM_WEBHOOK_URL="${WECOM_WEBHOOK_URL:-}"
CF_COOKIE="${CF_COOKIE:-}"

UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"

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

if [ -z "${TOKENS}" ]; then
  log "错误：未设置 VSLLM_ACCESS_TOKENS"
  log "用法：VSLLM_ACCESS_TOKENS='你的访问令牌' bash checkin.sh"
  exit 1
fi

IFS=',' read -ra token_list <<< "${TOKENS}"
ok=0
summary=""
for idx in "${!token_list[@]}"; do
  token="$(echo "${token_list[$idx]}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  [ -z "${token}" ] && continue

  log "账号 $((idx+1))：签到中 -> ${BASE_URL}/api/user/checkin"

  args=(
    -sS -m 30 -X POST "${BASE_URL%/}/api/user/checkin"
    -H "User-Agent: ${UA}"
    -H "Accept: application/json, text/plain, */*"
    -H "Referer: ${BASE_URL%/}/profile"
    -H "Content-Type: application/json"
    -H "Authorization: Bearer ${token}"
    -d '{}'
  )
  [ -n "${CF_COOKIE}" ] && args+=(-H "Cookie: ${CF_COOKIE}")

  resp="$(curl "${args[@]}" 2>&1)" || { log "账号 $((idx+1))：网络请求失败"; summary="${summary}账号$((idx+1))：网络请求失败\n"; continue; }

  if echo "${resp}" | grep -q "Just a moment"; then
    log "账号 $((idx+1))：被 Cloudflare 质询拦截（403），需要浏览器 Cookie 或更换网络"
    summary="${summary}账号$((idx+1))：Cloudflare 拦截\n"
    continue
  fi

  if echo "${resp}" | grep -q '"success"[[:space:]]*:[[:space:]]*true'; then
    msg="$(echo "${resp}" | sed -n 's/.*"message"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
    log "账号 $((idx+1))：✅ ${msg:-签到成功}"
    summary="${summary}账号$((idx+1))：✅ ${msg:-签到成功}\n"
    ok=$((ok+1))
  else
    msg="$(echo "${resp}" | sed -n 's/.*"message"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
    log "账号 $((idx+1))：⚠️ ${msg:-签到失败}（响应：${resp}）"
    summary="${summary}账号$((idx+1))：⚠️ ${msg:-签到失败}\n"
  fi
done

total="${#token_list[@]}"
log "=============================================="
log "签到汇总：成功 ${ok}/${total}"
log "=============================================="
echo -e "${summary}"

notify "vsllm 签到：${ok}/${total} 成功" "$(echo -e "${summary}")"

[ "${ok}" -gt 0 ]
