#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""vsllm.cc 每日签到（New API 网关 / 带 Cloudflare 托管控质询处理）。

设计依据（实测结论，详见 README「Cloudflare 说明」）：
  * 站点对 /api/user/checkin 单独下发了 Managed Challenge，其余接口不受影响；
  * 该质询在可疑 IP 上会升级为「请验证您是真人」的交互式 Turnstile；
  * cf_clearance **不可移植**——同一 IP、同一 UA、甚至用 curl_cffi 对齐 TLS 指纹，
    回放该 Cookie 依旧 403。只有发起质询的那个浏览器实例能通过。
  => 因此正确做法是「让浏览器自己发这个 POST」，而不是「导出 Cookie 交给 curl」。

认证方式（二选一，Cookie 优先）：
  VSLLM_ACCESS_TOKENS  访问令牌，多账号英文逗号分隔
  VSLLM_COOKIE         浏览器完整 Cookie 串（至少含 session；cf_clearance 建议不要带）

环境变量：
  VSLLM_BASE_URL       站点地址，默认 https://vsllm.cc
  VSLLM_MODE           auto|direct|browser|solver，默认 auto
  VSLLM_PROFILE_DIR    浏览器持久化 profile 目录，默认 ./.vsllm-profile
  VSLLM_HEADLESS       1 启用无头；默认 0（无头几乎必被拦）
  VSLLM_CHROME         指定 Chrome/Chromium 可执行文件路径（可选）
  VSLLM_BROWSER_TIMEOUT  单账号浏览器流程超时秒数，默认 90
  VSLLM_SOLVER_URL     自建 solver 地址，如 http://127.0.0.1:8191（FlareSolverr/Byparr 兼容）
  VSLLM_UA             直连模式 User-Agent
  NOTIFY_URL           通用推送地址（表单 title/desp）
  WECOM_WEBHOOK_URL    企业微信群机器人 Webhook（优先于 NOTIFY_URL）
"""

from __future__ import annotations

import argparse
import json
import os
import random
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass

DEFAULT_UA = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
)

CHALLENGE_MARKERS = (
    "Just a moment",
    "_cf_chl_opt",
    "cf-challenge",
    "challenge-platform",
    "请稍候",
    "正在进行安全验证",
    "请验证您是真人",
)
ALREADY_DONE_MARKERS = ("已经签到", "已签到", "明天再来")


@dataclass
class Result:
    ok: bool
    message: str
    detail: str = ""


@dataclass
class Account:
    label: str
    token: str = ""
    cookie: str = ""


# --------------------------------------------------------------------------- #
# HTTP 基础
# --------------------------------------------------------------------------- #
def http_request(
    url: str,
    method: str = "POST",
    headers: dict[str, str] | None = None,
    body: bytes = b"",
    timeout: int = 30,
) -> tuple[int, dict[str, str], str]:
    data = body if method.upper() not in ("GET", "HEAD") else None
    req = urllib.request.Request(url, data=data, headers=headers or {}, method=method.upper())
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, dict(resp.headers), resp.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as exc:
        return exc.code, dict(exc.headers or {}), exc.read().decode("utf-8", "replace")
    except Exception as exc:  # noqa: BLE001
        return 0, {}, f"{type(exc).__name__}: {exc}"


def header(headers: dict[str, str], name: str) -> str:
    for key, value in headers.items():
        if key.lower() == name.lower():
            return value
    return ""


def is_challenge(status: int, headers: dict[str, str], body: str) -> bool:
    """Cf-Mitigated: challenge 是权威信号，文案匹配只作兜底。"""
    if status not in (403, 503):
        return False
    if header(headers, "cf-mitigated").lower() == "challenge":
        return True
    return any(marker in body for marker in CHALLENGE_MARKERS)


def judge(status: int, body: str) -> Result:
    try:
        data = json.loads(body)
        message = str(data.get("message") or "") if isinstance(data, dict) else ""
        success = bool(data.get("success")) if isinstance(data, dict) else False
    except Exception:  # noqa: BLE001
        message, success = "", False

    if status == 200 and success:
        return Result(True, message or "签到成功", body)
    if message and any(marker in message for marker in ALREADY_DONE_MARKERS):
        return Result(True, f"{message}（今日已完成）", body)
    if status == 401:
        return Result(False, "未登录：session / 访问令牌无效或已过期", body)
    if status == 0:
        return Result(False, f"网络请求失败：{body}", body)
    if message:
        return Result(False, message, body)
    return Result(False, f"HTTP {status}：{body[:200]}", body)


def parse_cookie_string(cookie: str, host: str) -> list[dict]:
    items = []
    for pair in cookie.split(";"):
        pair = pair.strip()
        if not pair or "=" not in pair:
            continue
        name, value = pair.split("=", 1)
        items.append({"name": name.strip(), "value": value.strip(), "domain": host, "path": "/"})
    return items


# --------------------------------------------------------------------------- #
# 模式一：直连（未被质询时最快，零依赖）
# --------------------------------------------------------------------------- #
def checkin_direct(base: str, account: Account, ua: str) -> tuple[Result, bool]:
    headers = {
        "User-Agent": ua,
        "Accept": "application/json, text/plain, */*",
        "Content-Type": "application/json",
        "Referer": f"{base}/profile",
        "Origin": base,
    }
    if account.cookie:
        headers["Cookie"] = account.cookie
    elif account.token:
        headers["Authorization"] = f"Bearer {account.token}"

    status, resp_headers, body = http_request(
        f"{base}/api/user/checkin", headers=headers, body=b"{}", timeout=30
    )
    if is_challenge(status, resp_headers, body):
        return Result(False, "被 Cloudflare 质询拦截"), True
    return judge(status, body), False


# --------------------------------------------------------------------------- #
# 模式二：本地浏览器（推荐）
# --------------------------------------------------------------------------- #
def load_driver():
    """优先 patchright（反检测补丁），回退官方 playwright。"""
    try:
        from patchright.sync_api import sync_playwright  # type: ignore

        return sync_playwright, "patchright"
    except ImportError:
        pass
    try:
        from playwright.sync_api import sync_playwright  # type: ignore

        return sync_playwright, "playwright"
    except ImportError:
        return None, ""


def click_turnstile(page, timeout: int = 20) -> bool:
    """交互式 Turnstile：按 iframe 坐标派发带轨迹的真实鼠标事件。"""
    deadline = time.time() + timeout
    frame = None
    while time.time() < deadline:
        frame = next(
            (f for f in page.frames if "challenges.cloudflare.com" in (f.url or "")), None
        )
        if frame:
            break
        time.sleep(0.8)
    if not frame:
        return False

    try:
        box = frame.frame_element().bounding_box()
    except Exception:  # noqa: BLE001
        box = None
    if not box:
        return False

    tx, ty = box["x"] + 30, box["y"] + box["height"] / 2
    sx, sy = tx - 260, ty + 150
    for i in range(1, 19):
        ratio = i / 18
        page.mouse.move(
            sx + (tx - sx) * ratio + random.uniform(-1.5, 1.5),
            sy + (ty - sy) * ratio + random.uniform(-1.5, 1.5),
        )
        time.sleep(random.uniform(0.01, 0.03))
    page.mouse.click(tx, ty, delay=random.randint(60, 120))
    return True


def _launch_kwargs(profile_dir: str, headless: bool) -> dict:
    kwargs: dict = {
        "user_data_dir": os.path.abspath(profile_dir),
        "headless": headless,
        "no_viewport": True,
        "args": [
            "--disable-blink-features=AutomationControlled",
            "--no-first-run",
            "--no-default-browser-check",
            "--window-size=1280,900",
        ],
    }
    chrome = os.environ.get("VSLLM_CHROME", "").strip()
    if chrome:
        kwargs["executable_path"] = chrome
    return kwargs


def login_flow(base: str, profile_dir: str, timeout: int = 300) -> int:
    """打开持久化 profile 的浏览器，让用户手动登录一次，登录态留在 profile 里。"""
    sync_playwright, _ = load_driver()
    if not sync_playwright:
        print("未安装 playwright / patchright，无法打开浏览器", file=sys.stderr)
        return 1

    with sync_playwright() as pw:
        ctx = pw.chromium.launch_persistent_context(**_launch_kwargs(profile_dir, False))
        try:
            page = ctx.pages[0] if ctx.pages else ctx.new_page()
            page.goto(f"{base}/login", wait_until="commit", timeout=60000)
            print("已打开登录页。请在弹出的窗口中完成登录（含 Cloudflare 真人验证）。")
            print(f"登录态会保存到：{os.path.abspath(profile_dir)}")
            deadline = time.time() + timeout
            while time.time() < deadline:
                names = [c["name"] for c in ctx.cookies(base)]
                if "session" in names:
                    print("✅ 检测到 session，登录态已保存，之后无需再传 Cookie。")
                    time.sleep(2)
                    return 0
                time.sleep(2)
            print("⚠️ 超时未检测到 session（登录未完成？）", file=sys.stderr)
            return 1
        finally:
            ctx.close()


def checkin_browser(base: str, account: Account, profile_dir: str, headless: bool,
                    timeout: int = 90) -> Result:
    sync_playwright, driver = load_driver()
    if not sync_playwright:
        return Result(False, "未安装 playwright / patchright，无法使用浏览器模式")

    target = f"{base}/api/user/checkin"
    host = urllib.parse.urlparse(base).hostname or "vsllm.cc"
    api_headers: dict[str, str] = {"Content-Type": "application/json"}
    if account.token:
        api_headers["Authorization"] = f"Bearer {account.token}"

    with sync_playwright() as pw:
        try:
            ctx = pw.chromium.launch_persistent_context(**_launch_kwargs(profile_dir, headless))
        except Exception as exc:  # noqa: BLE001
            return Result(
                False,
                f"浏览器启动失败：{type(exc).__name__}。请先 playwright install chromium，"
                "或用 VSLLM_CHROME 指定浏览器路径",
            )
        try:
            if account.cookie:
                ctx.add_cookies(parse_cookie_string(account.cookie, host))
            page = ctx.pages[0] if ctx.pages else ctx.new_page()
            page.goto(target, wait_until="commit", timeout=timeout * 1000)

            # 自校验循环：以「页内 POST 是否仍返回质询页」为准，不依赖 title 文案
            deadline = time.time() + timeout
            last_status, last_body = 0, ""
            while time.time() < deadline:
                probe = page.evaluate(
                    """async ({headers}) => {
                        const r = await fetch('/api/user/checkin', {
                            method: 'POST', headers, body: '{}', credentials: 'include',
                        });
                        return {status: r.status, body: await r.text()};
                    }""",
                    {"headers": api_headers},
                )
                last_status, last_body = probe["status"], probe["body"]
                if not is_challenge(last_status, {}, last_body):
                    return judge(last_status, last_body)
                click_turnstile(page, timeout=6)
                page.wait_for_timeout(1500)

            return Result(
                False,
                "Cloudflare 质询未通过：出口 IP 被判定为自动化，或需人工点选真人验证",
                f"last_status={last_status} body={last_body[:160]}",
            )
        finally:
            ctx.close()


# --------------------------------------------------------------------------- #
# 模式三：自建 solver（FlareSolverr / Byparr，API 兼容）
# --------------------------------------------------------------------------- #
def checkin_solver(base: str, account: Account, solver_url: str, timeout: int = 90) -> Result:
    """由 solver 内的真实浏览器完成 POST；因此同样规避 Cookie 不可移植问题。

    FlareSolverr 的 /v1 协议不支持自定义请求头，故 solver 模式只支持 Cookie 认证。
    """
    if account.token and not account.cookie:
        return Result(False, "solver 模式仅支持 Cookie 认证（Bearer 需自定义请求头）")

    host = urllib.parse.urlparse(base).hostname or "vsllm.cc"
    payload = {
        "cmd": "request.post",
        "url": f"{base}/api/user/checkin",
        "postData": "{}",
        "maxTimeout": timeout * 1000,
        "cookies": parse_cookie_string(account.cookie, host),
    }
    status, _, body = http_request(
        solver_url.rstrip("/") + "/v1",
        headers={"Content-Type": "application/json"},
        body=json.dumps(payload).encode(),
        timeout=timeout + 30,
    )
    if status != 200:
        return Result(False, f"solver 调用失败：HTTP {status} {body[:160]}")

    try:
        data = json.loads(body)
    except Exception:  # noqa: BLE001
        return Result(False, f"solver 返回非 JSON：{body[:160]}")
    if data.get("status") != "ok":
        return Result(False, f"solver 报错：{data.get('message', body[:160])}")

    solution = data.get("solution") or {}
    content = solution.get("response") or ""
    code = int(solution.get("status") or 0)
    if is_challenge(code, {}, content):
        return Result(False, "solver 内部仍被质询：检查其出口 IP 与浏览器指纹")
    return judge(code, content)


# --------------------------------------------------------------------------- #
# 通知
# --------------------------------------------------------------------------- #
def notify(title: str, desp: str) -> None:
    wecom = os.environ.get("WECOM_WEBHOOK_URL", "").strip()
    generic = os.environ.get("NOTIFY_URL", "").strip()
    if wecom:
        payload = json.dumps(
            {"msgtype": "text", "text": {"content": f"{title}\n{desp}"}}, ensure_ascii=False
        ).encode()
        http_request(wecom, headers={"Content-Type": "application/json"}, body=payload, timeout=15)
    elif generic:
        body = urllib.parse.urlencode({"title": title, "desp": desp}).encode()
        http_request(
            generic,
            headers={"Content-Type": "application/x-www-form-urlencoded"},
            body=body,
            timeout=15,
        )


# --------------------------------------------------------------------------- #
# 主流程
# --------------------------------------------------------------------------- #
def main() -> int:
    parser = argparse.ArgumentParser(description="vsllm.cc 每日签到")
    parser.add_argument("--base-url", default=os.environ.get("VSLLM_BASE_URL", "https://vsllm.cc"))
    parser.add_argument(
        "--mode",
        default=os.environ.get("VSLLM_MODE", "auto"),
        choices=["auto", "direct", "browser", "solver"],
    )
    parser.add_argument(
        "--headless", action="store_true", default=os.environ.get("VSLLM_HEADLESS") == "1"
    )
    parser.add_argument("--login", action="store_true", help="打开浏览器手动登录一次并保存登录态")
    parser.add_argument("--debug", action="store_true")
    args = parser.parse_args()

    base = args.base_url.rstrip("/")
    ua = os.environ.get("VSLLM_UA", DEFAULT_UA).strip() or DEFAULT_UA
    cookie = (os.environ.get("VSLLM_COOKIE") or os.environ.get("CF_COOKIE") or "").strip()
    tokens = [t.strip() for t in os.environ.get("VSLLM_ACCESS_TOKENS", "").split(",") if t.strip()]
    solver_url = os.environ.get("VSLLM_SOLVER_URL", "").strip()
    profile_dir = os.environ.get("VSLLM_PROFILE_DIR", ".vsllm-profile")
    browser_timeout = int(os.environ.get("VSLLM_BROWSER_TIMEOUT", "90"))

    if args.login:
        return login_flow(base, profile_dir)

    if not cookie and not tokens and args.mode in ("direct", "solver"):
        print("错误：未设置 VSLLM_ACCESS_TOKENS 或 VSLLM_COOKIE", file=sys.stderr)
        return 1

    if cookie:
        accounts = [Account("Cookie账号", cookie=cookie)]
    elif tokens:
        accounts = [Account(f"账号 {i + 1}", token=t) for i, t in enumerate(tokens)]
    else:
        # 无凭据：依赖 --login 保存在 profile 里的登录态
        accounts = [Account("Profile账号")]

    results: list[tuple[Account, Result]] = []
    for account in accounts:
        stamp = time.strftime("%H:%M:%S")
        print(f"[{stamp}] {account.label}：签到中 -> {base}/api/user/checkin")

        if args.mode in ("auto", "direct") and (account.token or account.cookie):
            result, challenged = checkin_direct(base, account, ua)
            if not challenged:
                results.append((account, result))
                print(f"  → {'✅' if result.ok else '⚠️'} {result.message}")
                continue
            print("  → 被 Cloudflare 质询，进入浏览器升级流程")

        if args.mode == "direct":
            results.append((account, Result(False, "被 Cloudflare 质询（direct 模式不升级）")))
            continue

        if args.mode in ("auto", "solver") and solver_url:
            result = checkin_solver(base, account, solver_url)
        else:
            result = checkin_browser(base, account, profile_dir, args.headless, browser_timeout)

        results.append((account, result))
        print(f"  → {'✅' if result.ok else '⚠️'} {result.message}")
        if args.debug and result.detail:
            print(f"     detail: {result.detail[:400]}")

    ok_count = sum(1 for _, r in results if r.ok)
    summary = "\n".join(f"{a.label}：{'✅' if r.ok else '⚠️'} {r.message}" for a, r in results)
    print("=" * 46)
    print(f"签到汇总：成功 {ok_count}/{len(results)}")
    print(summary)
    print("=" * 46)

    notify(f"vsllm 签到：{ok_count}/{len(results)} 成功", summary)
    return 0 if ok_count > 0 else 1


if __name__ == "__main__":
    sys.exit(main())
