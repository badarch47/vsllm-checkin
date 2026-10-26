# vsllm-checkin · vsllm.cc 每日自动签到

基于 New API 网关标准签到接口的每日自动签到项目，支持**多账号、多站点**，开箱即用 **GitHub Actions** 每天定时执行，可选 Server酱/Bark 推送结果。

## 原理

vsllm.cc 由开源项目 [New API](https://github.com/QuantumNous/new-api) 搭建，签到走的是标准接口：

```
POST https://vsllm.cc/api/user/checkin
Authorization: Bearer <访问令牌>
```

每天只能签到一次，奖励为平台设定的随机额度，发放到账户余额，到账可能有延迟。

## 获取访问令牌（关键！）

1. 登录 https://vsllm.cc
2. 进入「个人资料」→「安全设置」→「访问令牌」
3. 点击「生成新令牌」并复制

> ⚠️ **注意**：这里用的「访问令牌」是个人资料页安全设置里生成的**账户级令牌**，不是「令牌」页里以 `sk-` 开头的 API Key，两者不能混用。

## 方式一：GitHub Actions 每日自动签到（推荐）

1. 把本项目推送到自己的 GitHub 仓库（可先 Fork）。
2. 进入仓库 `Settings → Secrets and variables → Actions → New repository secret`，添加：

   | Secret 名称 | 必填 | 说明 |
   |---|---|---|
   | `VSLLM_ACCESS_TOKENS` | ✅ | 访问令牌；多账号用英文逗号分隔，如 `token1,token2` |
   | `VSLLM_BASE_URL` | ❌ | 站点地址，默认 `https://vsllm.cc`（支持其他 New API 站） |
   | `NOTIFY_URL` | ❌ | 推送地址，如 Server酱 `https://sctapi.ftqq.com/<SENDKEY>.send` |
   | `CF_COOKIE` | ❌ | 浏览器 Cloudflare 会话 Cookie（见下方说明） |

3. 打开仓库 `Actions` 页，确认工作流已启用（Fork 的仓库默认可能禁用，需手动 Enable）。
4. 点击 `vsllm 每日签到 → Run workflow` 手动测试一次，或直接等定时任务：**每天北京时间 06:20** 自动执行。

## 方式二：本地运行

Linux / macOS / Git Bash：

```bash
VSLLM_ACCESS_TOKENS='你的访问令牌' bash checkin.sh
```

Windows PowerShell：

```powershell
$env:VSLLM_ACCESS_TOKENS='你的访问令牌'
bash checkin.sh
```

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

## Cloudflare 说明（重要）

实测 vsllm.cc 对**非浏览器客户端**启用 Cloudflare 托管质询（"Just a moment..."）：普通 curl 直接访问 `/api/user/checkin` 会返回 403 质询页，脚本已内置识别并在日志中明确提示。

- 如果你的网络/GitHub Actions 出口 IP 被质询，签到会失败——这是站点侧的防爬策略，脚本无法绕过。
- 可尝试方案：
  1. 浏览器登录后复制 `cf_clearance` 等 Cookie，填入 `CF_COOKIE` 环境变量（Cookie 会过期，需定期更新）；
  2. 在未被质询的网络环境（如家用宽带）运行，或改用 Windows 任务计划程序每天定时执行；
  3. 若站点为白名单放行 API 路径，后续可直接去掉 Cookie 配置。

## 常见问题

- **"今天已经签到过了，请明天再来"**：属正常响应，说明当天已签到，不算失败。
- **提示需要人机验证（验证码）**：New API 支持对签到接口开启 Turnstile 人机验证，若站点启用了该策略，脚本无法自动通过，需在浏览器手动签到。
- **GitHub Actions 里脚本报 403**：大概率是 Cloudflare 质询（见上节），查看运行日志确认是否出现 "Just a moment"。
- **令牌失效**：重置访问令牌后需同步更新 `VSLLM_ACCESS_TOKENS`。
