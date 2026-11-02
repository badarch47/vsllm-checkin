# vsllm-checkin · vsllm.cc 每日自动签到

基于 [New API](https://github.com/QuantumNous/new-api) 标准签到接口的每日签到工具，支持多账号、企业微信/Server酱通知，**并处理了 vsllm.cc 在签到接口上单独设置的 Cloudflare 人机验证**。

```
POST https://vsllm.cc/api/user/checkin
```

---

## 先说结论（实测，2026-11）

| 结论 | 依据 |
|---|---|
| Cloudflare 质询**只针对 `/api/user/checkin`** | `/api/status` → 200，`POST /api/user/login` → 200，`POST /v1/chat/completions` → 401；而 `GET`/`POST /api/user/checkin` 均 403 + `Cf-Mitigated: challenge` |
| 换 UA、补齐浏览器请求头**无效** | Chrome UA + 全套 `Sec-Fetch-*`/`Sec-CH-UA` 仍 403。这不是指纹判断，是路径规则 |
| `cf_clearance` **不可移植** | 浏览器刚通过验证拿到 `cf_clearance` 后，同一 IP、同一 UA、同一秒内用 curl 回放 → 403；用 `curl_cffi` 模拟 `chrome`/`chrome131`/`chrome124`/`safari` 四种 TLS 指纹 → **全部 403** |
| 可疑 IP 上会升级为**交互式 Turnstile** | 数据中心/代理 IP 打开质询页显示「请验证您是真人」勾选框；点击后 4 秒通过 |
| 通过后**只有那个浏览器实例**能发请求 | 同实例内 `fetch` → 401（已到 New API 后端，说明质询已过） |

**所以：** 把 `cf_clearance` 塞进 curl 的老路子，在本机、同 UA、同 IP 条件下也不成立。正确做法只有一个——**让浏览器自己发这个 POST**。本项目按此重构。

---

## 三种路径怎么选

| 路径 | 命令 | 适用 | 成本 |
|---|---|---|---|
| **A. 本机浏览器（推荐）** | `python checkin.py --mode browser` | 家里电脑 / NAS，有真实家宽 IP | 免费，一次装依赖，之后每日静默通过 |
| **B. 自建 solver** | `python checkin.py --mode solver` | 需要跑在服务器上，且能配住宅代理 | 一台常驻机器 + Docker（Byparr / FlareSolverr） |
| **C. 直连** | `python checkin.py --mode direct` | 站点取消质询，或你的网络未被判定为自动化 | 免费、零依赖，但当前对 vsllm.cc 基本无效 |

GitHub Actions 属于**数据中心 IP + 无显示器**，A 走不通、C 走不通，只有配了住宅出口的 B 才有意义。

---

## 快速开始（方式 A：本机，推荐）

### 1. 安装

```bash
python -m pip install -r requirements.txt
python -m playwright install chromium
```

> 想让通过率更高，把 `requirements.txt` 里的 `playwright` 换成 `patchright`（打过反检测补丁的分支，本项目会自动优先使用它）。

### 2. 登录一次（登录态存进浏览器 profile）

```bash
python checkin.py --login
```

会弹出浏览器窗口，正常登录 vsllm.cc（含真人验证）。脚本检测到 `session` Cookie 后自动保存到 `.vsllm-profile/`，**之后不需要再手动复制任何 Cookie**。

### 3. 每天签到

```bash
python checkin.py
```

未登录态下会先走一次直连（很快），遇到质询自动切到浏览器模式。

### 4. 挂成 Windows 计划任务

`C:\vsllm-checkin.ps1`（UTF-8 保存）：

```powershell
Set-Location 'C:\path\to\vsllm-checkin'
python checkin.py >> 'C:\vsllm-checkin.log' 2>&1
```

`Win+R` → `taskschd.msc` → 创建基本任务 → 每天 01:00 → 启动程序：
程序 `powershell.exe`，参数 `-ExecutionPolicy Bypass -File C:\vsllm-checkin.ps1`。

> 计划任务里**不要**加 `--headless`。无头浏览器几乎必被拦。

---

## 方式 B：自建 solver（FlareSolverr / Byparr）

思路是把「打开浏览器 → 过验证 → 发请求」这整套交给一个常驻服务，脚本只调它的 API。因为请求由 solver 的浏览器发出，天然不存在 Cookie 移植问题。

```bash
# Byparr（Camoufox 内核，2026 年基准测试通过率最高）
docker run -d --name byparr -p 8191:8191 --shm-size=512m ghcr.io/thephaseless/byparr

# 或 FlareSolverr（更老牌，速度更快）
docker run -d --name flaresolverr -p 8191:8191 -e LOG_LEVEL=info ghcr.io/flaresolverr/flaresolverr
```

```bash
export VSLLM_COOKIE='session=...'          # 至少要有 session
export VSLLM_SOLVER_URL='http://127.0.0.1:8191'
python checkin.py --mode solver
```

注意两点：

1. solver 的出口 IP 决定成败。放在数据中心，一样被判定自动化，需要给它配住宅代理。
2. FlareSolverr 的 `/v1` 协议不支持自定义请求头，所以 **solver 模式只支持 Cookie 认证**，Bearer 令牌走不通。

---

## 方式 C：直连（无质询时）

```bash
# 访问令牌（多账号英文逗号分隔）
VSLLM_ACCESS_TOKENS='token1,token2' python checkin.py --mode direct

# 或 Cookie
VSLLM_COOKIE='session=...' python checkin.py --mode direct
```

访问令牌在「个人资料 → 安全设置 → 访问令牌」生成，**不是** `sk-` 开头的 API Key。

---

## 环境变量

| 变量 | 说明 |
|---|---|
| `VSLLM_ACCESS_TOKENS` | 访问令牌，多账号逗号分隔 |
| `VSLLM_COOKIE` | 完整 Cookie 串（`session` 必需；`cf_clearance` 带了也没用，见上） |
| `VSLLM_MODE` | `auto`(默认) / `direct` / `browser` / `solver` |
| `VSLLM_PROFILE_DIR` | 浏览器 profile 目录，默认 `./.vsllm-profile` |
| `VSLLM_HEADLESS` | `1` 开无头，默认 `0`（不建议开） |
| `VSLLM_CHROME` | 指定 Chrome 可执行文件路径（用系统 Chrome 时填） |
| `VSLLM_SOLVER_URL` | solver 地址，如 `http://127.0.0.1:8191` |
| `VSLLM_BASE_URL` | 站点地址，默认 `https://vsllm.cc` |
| `WECOM_WEBHOOK_URL` | 企业微信群机器人 Webhook（优先） |
| `NOTIFY_URL` | 通用推送（Server酱 / Bark，表单 `title`/`desp`） |

---

## 常见问题

**「今天已经签到过了」算失败吗？**
不算。脚本识别`已经签到/已签到/明天再来`并计入成功。

**为什么浏览器模式也提示质询未通过？**
出口 IP 被判为高风险（机房、公共代理、频繁请求）。换家宽 IP，或降低运行频率。数据中心 IP 上，用付费打码也常常过不掉。

**profile 会过期吗？**
`session` 约一个月。过期后重跑一次 `--login` 即可，其它不用动。

**能不能彻底不装浏览器？**
当前站点策略下不能。所有「纯请求过 CF」的方案（`cloudscraper`、`curl_cffi`、自拼 `cf_clearance`）在这条路径上已验证无效。唯一例外是 `cfsolve` 这类项目——它复刻浏览器指纹并在请求层解 Turnstile，属于「不用浏览器但要逆向」，见下节。

---

## 附：相关开源项目（2026-11 状态）

| 项目 | 形态 | 说明 |
|---|---|---|
| [FlareSolverr](https://github.com/FlareSolverr/FlareSolverr) | 自建服务 | 16k★，Selenium + undetected-chromedriver，`/v1` API，生态最成熟 |
| [Byparr](https://github.com/ThePhaseless/Byparr) | 自建服务 | Camoufox 内核，API 与 FlareSolverr 完全兼容，可直接替换 |
| [Theyka/Turnstile-Solver](https://github.com/Theyka/Turnstile-Solver) | 自建服务 | 959★，patchright + 模板匹配点选，专攻 Turnstile |
| [cfsolve](https://github.com/chris124567/cfsolve) | CLI / Rust 库 | **纯请求**解 Turnstile 与质询页，返回 `cf_clearance`；需 Rust 构建 + 浏览器指纹 profile，2026-10 刚开源，成熟度待观察 |
| [patchright](https://github.com/Kaliiiiiiiiii-Vinyzu/patchright) | Python 库 | Playwright 的反检测分支，本项目浏览器模式优先使用 |
| [Camoufox](https://github.com/daijro/camoufox) | 浏览器 | Firefox 内核的反检测浏览器，配合 Playwright 使用 |
| `cloudscraper` / `curl_cffi` | Python 库 | **对本场景无效**：前者只解旧版 IUAM，后者只改 TLS 指纹，而这里是路径规则 + 交互式验证 |

---

## 变更说明（相对旧版）

- 质询判定从 `grep "Just a moment"` 改为 `HTTP 403 + Cf-Mitigated: challenge`，不再受语言/文案变化影响；
- 删除「导出 cf_clearance 交给 curl」的错误指引，改为浏览器内发请求；
- 新增 `--login` 持久化登录态，免去手工复制 Cookie；
- 新增 solver 模式，兼容 FlareSolverr / Byparr；
- `checkin.sh` 保留为转发壳，无 Python 环境时回落到纯 curl 实现。
