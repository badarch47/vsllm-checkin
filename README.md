# vsllm-checkin · vsllm.cc 每日自动签到

基于 New API 网关标准签到接口的每日自动签到项目，支持**多账号、多站点**，开箱即用 **GitHub Actions** 每天定时执行，可选 Server酱/Bark 推送结果。

## 原理

vsllm.cc 由开源项目 [New API](https://github.com/QuantumNous/new-api) 搭建，签到走的是标准接口：

```
POST https://vsllm.cc/api/user/checkin
```

认证二选一（脚本自动处理）：

- **访问令牌**：`Authorization: Bearer <访问令牌>`（适合网络未被质询时，支持多账号）
- **浏览器 Cookie 串**：`Cookie: cf_clearance=...; session=...`（适合被 Cloudflare 质询时，见下方说明）

每天只能签到一次，奖励为平台设定的随机额度，发放到账户余额，到账可能有延迟。

## 获取访问令牌（关键！）

1. 登录 https://vsllm.cc
2. 进入「个人资料」→「安全设置」→「访问令牌」
3. 点击「生成新令牌」并复制

> ⚠️ **注意**：这里用的「访问令牌」是个人资料页安全设置里生成的**账户级令牌**，不是「令牌」页里以 `sk-` 开头的 API Key，两者不能混用。若改用方式 B 的浏览器 Cookie 模式，则无需此令牌。

## 方式一：GitHub Actions 每日自动签到（推荐）

1. 把本项目推送到自己的 GitHub 仓库（可先 Fork）。
2. 进入仓库 `Settings → Secrets and variables → Actions → New repository secret`，添加：

   | Secret 名称 | 必填 | 说明 |
   |---|---|---|
   | `VSLLM_ACCESS_TOKENS` | ✅ | 访问令牌；多账号用英文逗号分隔，如 `token1,token2` |
   | `VSLLM_BASE_URL` | ❌ | 站点地址，默认 `https://vsllm.cc`（支持其他 New API 站） |
   | `NOTIFY_URL` | ❌ | 推送地址，如 Server酱 `https://sctapi.ftqq.com/<SENDKEY>.send` |
   | `WECOM_WEBHOOK_URL` | ❌ | 企业微信群机器人 Webhook 地址（设置了则优先于 `NOTIFY_URL`） |
   | `VSLLM_COOKIE` | ❌ | 浏览器完整 Cookie 串（含 `cf_clearance`、`session` 等），被 Cloudflare 拦截时用 |
   | `VSLLM_UA` | ❌ | 浏览器 User-Agent，须与签发 Cookie 的浏览器一致 |
   | `CF_COOKIE` | ❌ | `VSLLM_COOKIE` 的兼容别名（旧配置仍可用） |

3. 打开仓库 `Actions` 页，确认工作流已启用（Fork 的仓库默认可能禁用，需手动 Enable）。
4. 点击 `vsllm 每日签到 → Run workflow` 手动测试一次，或直接等定时任务：**每天北京时间 01:00** 自动执行。

> ⚠️ **GitHub Actions 对被 Cloudflare 质询的站点基本不可行**：无论加几个 Cookie（`cf_clearance` 等）都会因出口 IP 与签发时不匹配而被拦，见「Cloudflare 说明」。被质询时请改用方式三本机定时任务。

## 方式二：本地运行

**方式 A：访问令牌**

```bash
VSLLM_ACCESS_TOKENS='你的访问令牌' bash checkin.sh
```

**方式 B：浏览器完整 Cookie 串（被 Cloudflare 拦截时用）**

```bash
VSLLM_COOKIE='cf_clearance=...; session=...' VSLLM_UA='你的浏览器UA' bash checkin.sh
```

Windows PowerShell 方式 B：

```powershell
$env:VSLLM_COOKIE='cf_clearance=...; session=...'
$env:VSLLM_UA='你的浏览器UA'
bash checkin.sh
```

## 方式三：本机定时任务（Windows，被 Cloudflare 拦截时的首选）

1. 先把方式 B 本地跑通。
2. 把运行命令写成 `C:\vsllm-checkin.ps1`（UTF-8 编码）：

   ```powershell
   $env:VSLLM_COOKIE='cf_clearance=...; session=...'
   $env:VSLLM_UA='你的浏览器UA'
   bash 'C:\Users\Administrator\Doubao\chats\2026-10-26\new-chat\vsllm-checkin\checkin.sh'
   ```

3. `Win+R` → `taskschd.msc` → 创建基本任务 → 触发器「每天 01:00」→ 操作「启动程序」：程序填 `powershell.exe`，参数填 `-ExecutionPolicy Bypass -File C:\vsllm-checkin.ps1`。
4. Cookie 过期后（见下方说明）重新提取并更新 ps1 文件即可。

## 多账号

`VSLLM_ACCESS_TOKENS` 用英文逗号分隔多个令牌即可，脚本会逐个签到并汇总结果：

```
VSLLM_ACCESS_TOKENS='token1,token2,token3' bash checkin.sh
```

## 结果通知

设置 `NOTIFY_URL` 后，签到结束会向该地址 POST `title` / `desp` 表单。支持：

- Server酱：`https://sctapi.ftqq.com/<SENDKEY>.send`
- Bark：`https://api.day.app/<DEVICE_KEY>/`
- 企业微信机器人、钉钉自定义机器人等任何接受表单 POST 的地址

### 企业微信群机器人（推荐）

1. 在目标企业微信群 → 群设置 → 群机器人 → 添加机器人 → 新建，复制 Webhook 地址（形如 `https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key=xxxx`）
2. 填到 Secret `WECOM_WEBHOOK_URL`（本地运行则设同名环境变量）
3. 签到结束后向该群推送「签到汇总 + 各账号明细」文本消息
4. 优先级：设置了 `WECOM_WEBHOOK_URL` 时走企业微信，未设置则回落 `NOTIFY_URL`；两者都为空时不推送

## Cloudflare 说明（重要）

实测 vsllm.cc 对**非浏览器客户端**启用 Cloudflare 托管质询（"Just a moment..."）：普通 curl 直接访问 `/api/user/checkin` 会返回 403 质询页，脚本已内置识别并在日志中明确提示。

### 为什么加了 cf_clearance 还是被拦？

- `cf_clearance` 与**签发它的 IP 和 User-Agent 绑定**：谁解决了质询，这个 Cookie 就只对该 IP + 浏览器 UA 有效。
- GitHub Actions 每次运行都换一个 Azure 数据中心出口 IP，与你在家浏览器签发的 `cf_clearance` 不匹配 → **必然被拦**。把截图里所有 Cookie（`aff`、`cf_clearance`、`newapi_vid`、`session`）都加上也没用，这是站点边缘策略，不是登录问题。
- 因此被质询时，**本机跑才可行**（本机 IP 与浏览器一致）。本机 Cookie 模式关键只有两个：`cf_clearance`（过 Cloudflare）+ `session`（登录态），其余非必需。

### 提取浏览器完整 Cookie 串（含 HttpOnly）

`session` 和 `cf_clearance` 都是 HttpOnly，`document.cookie` 拿不到，要用下面方法：

1. 浏览器登录 vsllm.cc
2. F12 →「网络」→ 刷新页面，点击任意一条发往 `vsllm.cc` 的请求（如 `/api/user/self`）
3. 右键 →「复制」→「Copy as cURL」
4. 在命令里找到 `-H 'Cookie: ...'`，`Cookie:` 后到下一个 `'` 之间的整段就是完整 Cookie 串（形如 `cf_clearance=...; session=...; newapi_vid=...`）
5. 顺便复制 `-H 'User-Agent: ...'` 的值填给 `VSLLM_UA`（必须与浏览器一致，否则 cf_clearance 失效）

### Cookie 有效期

- `cf_clearance`：通常几天到一个月，过期后需重新提取
- `session`：约一个月（登录态），过期后需重新登录再提取
- 建议在 Cookie 失效前定期更新 `VSLLM_COOKIE`；也可配合企业微信通知，失败时及时感知

## 常见问题

- **"今天已经签到过了，请明天再来"**：属正常响应，说明当天已签到，不算失败。
- **提示需要人机验证（验证码）**：New API 支持对签到接口开启 Turnstile 人机验证，若站点启用了该策略，脚本无法自动通过，需在浏览器手动签到。
- **脚本报"Cloudflare 拦截"**：Cookie 模式多为 `cf_clearance` 过期或 IP/UA 与签发时不匹配（GitHub Actions 出口 IP 不同则必然拦截，见上节）；令牌模式则确认当前网络是否被质询。查看运行日志确认是否出现 "Just a moment"。
- **令牌失效**：重置访问令牌后需同步更新 `VSLLM_ACCESS_TOKENS`。
