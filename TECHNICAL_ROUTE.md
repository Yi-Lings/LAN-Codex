# LAN Codex 技术路线

本文面向需要调试、修改或重新发布 LAN Codex 的开发者。内容以当前仓库代码为准。

## 1. 目标与边界

LAN Codex 是 Windows 上的局域网桥接服务：手机通过 HTTP 访问电脑，Node.js 服务再通过本机 Chrome DevTools Protocol（CDP）控制 ChatGPT/Codex 桌面应用。

数据链路如下：

```text
Android APK / 手机浏览器
        |
        | HTTP + token，局域网端口 8787
        v
Node.js 服务（server.js + lan-only-guard.js）
        |
        | HTTP / WebSocket，仅回环地址
        v
ChatGPT/Codex 桌面应用 CDP，端口 39252
        |
        +-- 读取本机 ~/.codex 中的会话和状态数据
```

“LAN only”只描述手机到桥接服务及桥接服务自身的网络边界。ChatGPT/Codex 桌面应用是独立进程，仍需按其正常方式连接官方服务。

## 2. 主要组件

| 组件 | 位置 | 职责 |
| --- | --- | --- |
| WPF 控制面板 | `scripts/windows-wpf-control-panel.ps1` | 管理服务进程、token、连接地址、二维码和 CDP 状态 |
| Windows 启动器 | `windows/LanCodexLauncher.cs` | 编译为 `LAN Codex.exe`，以 STA 模式无控制台启动 WPF 脚本 |
| LAN 服务 | `server.js` | 提供手机页面和本地 API，读取会话并通过 CDP 执行操作 |
| 网络守卫 | `scripts/lan-only-guard.js` | 限制 Node.js 进程的出入站网络范围，并禁用上游授权/中转路由 |
| CDP 启动器 | `scripts/launch-main-codex-cdp.ps1` | 查找并重启 ChatGPT/Codex，开放本机 CDP 端口 |
| 手机前端 | `public/` | 由 LAN 服务直接提供的 HTML、PWA 清单、图标和本地第三方资源 |
| 二维码生成 | `scripts/make-qr.js` | 将带 token 的 LAN URL 生成为本地 GIF |
| 安装器 | `installer/LAN-Codex.iss` | 使用 Inno Setup 生成完整 Windows 安装程序和卸载入口 |

## 3. Windows 控制面板

控制面板默认监听 `8787`，配置保存在：

```text
%LOCALAPPDATA%\LAN Codex\config.json
```

配置包含随机生成的 24 字节 Base64URL token、端口和受控服务 PID。服务日志及临时二维码也位于同一目录。启动服务前，面板会创建 `%USERPROFILE%\.codex-mini`，避免服务首次写入 `state.json` 时因目录不存在而失败。

面板启动 Node.js 时设置的关键环境变量如下：

| 变量 | 当前值/来源 | 作用 |
| --- | --- | --- |
| `HOST` | `0.0.0.0` | 接收局域网连接 |
| `PORT` | 默认 `8787` | 手机访问端口 |
| `MOBILE_TYPER_TOKEN` | 控制面板生成并持久化 | API 访问凭证 |
| `CODEX_MINI_CDP_PORT` | `39252` | 本机桌面应用 CDP 端口 |
| `CODEX_MINI_LOCAL_ONLY` | `1` | 启用服务自身的本地模式 |
| `CODEX_MINI_DISABLE_A1_TUNNEL` | `1` | 禁用上游 tunnel |
| `CODEX_MINI_DISABLE_IMESSAGE_NOTIFY` | `1` | 禁用 iMessage 通知路径 |

面板每 2.5 秒检查服务健康状态和 CDP 页面目标。只有 PID 对应命令行确实包含当前 `server.js` 时，面板才将其视为自己拥有的进程并允许停止。

## 4. CDP 控制链

`scripts/launch-main-codex-cdp.ps1` 查找 Appx/WindowsApps 版或传统安装版 `ChatGPT.exe`/`Codex.exe`，并使用以下关键参数启动：

```text
--remote-debugging-address=127.0.0.1
--remote-debugging-port=39252
--remote-allow-origins=http://127.0.0.1:39252
```

脚本通过 `http://127.0.0.1:39252/json/list` 验证 `app://-/index.html` 主页面及其 `webSocketDebuggerUrl`。服务随后通过该 WebSocket 执行页面选择、线程切换、输入和发送等操作。

当前服务还会把 `9229` 作为 Codex++ 的备用探测端口；由本项目主动启动的受控应用仍使用 `39252`。CDP 绑定在回环地址，不应改成 `0.0.0.0`。

点击“启动受控 GPT”会提示并关闭现有普通窗口，再带 CDP 参数重新打开。未发送的桌面输入可能因此丢失。

## 5. 手机连接与数据流

控制面板选择活动的 RFC 1918 IPv4 地址，并生成：

```text
http://<电脑局域网 IPv4>:8787/?token=<随机 token>
```

二维码编码的就是这个完整 URL。`server.js` 在 token 正确的 HTML 请求上写入 `codexMiniToken` Cookie；后续请求可通过以下任一方式鉴权：

- `x-mobile-typer-token` 请求头；
- `token` 查询参数；
- `codexMiniToken` Cookie。

手机前端由 `public/` 提供。它调用本机 API读取健康状态、线程列表、历史、实时状态和文件，并通过 `/send`、线程选择/创建等 POST 接口把操作交给服务。服务一部分数据来自 `%USERPROFILE%\.codex` 下的会话、索引和状态文件，交互操作则通过 CDP 落到桌面应用。

Release 中的 Android 交付物是 `Lan-gpt.apk`。当前源码仓库没有 Android Gradle 工程或可重建 APK 的 native 源码，因此 Android 端在本项目中的稳定接口是上述扫码 URL 和 HTTP API。当前发布包只对既有 APK 的图标资源进行替换和重新签名；由于没有原签名私钥，旧签名版本必须卸载后才能安装本项目签名版本。普通手机浏览器也可直接打开同一 URL。

## 6. 安全边界

`scripts/lan-only-guard.js` 由 Node.js 的 `--require` 在 `server.js` 之前加载。它执行以下限制：

- 出站 `net.Socket`、TLS、`fetch`、WebSocket 和 DNS 只允许回环、链路本地及私有地址；
- 来自非私有地址的 HTTP 请求返回 `403`；
- `/codex-mini/license`、`/codex-mini/activate`、`/codex-mini/purchase`、`/codex-mini/relay`、`/codex/notifications` 和 `/codex/push` 返回 `404`；
- stdout/stderr 中出现当前手机 token 时替换为 `[REDACTED]`；
- 强制设置本地模式、禁用 A1 tunnel 和 iMessage 通知的环境标记。

私有地址范围包括 IPv4 的 `10.0.0.0/8`、`172.16.0.0/12`、`192.168.0.0/16`、回环和链路本地地址，以及 IPv6 回环、ULA 和链路本地地址。

需要注意：

- 手机入口使用 HTTP，不提供 TLS。token 能阻止无凭证调用，但不能防止不可信网络上的被动监听；只应在可信、加密且启用了客户端隔离策略评估的局域网使用。
- URL 和二维码包含完整 token，不应公开分享或截图传播。
- token 以明文保存在当前 Windows 用户的 `%LOCALAPPDATA%\LAN Codex\config.json` 中，其保护依赖 Windows 用户账户和文件权限。
- Windows 安装器只为 `8787/TCP` 创建“专用网络”入站规则；改变端口后需自行同步防火墙规则。
- Node.js 网络守卫不限制独立运行的 ChatGPT/Codex 进程。

## 7. 目录结构

```text
.
|-- public/                         # 手机 Web/PWA 前端和本地静态依赖
|-- scripts/
|   |-- lan-only-guard.js           # LAN 网络守卫
|   |-- lan-only-guard-test.js      # 网络守卫测试
|   |-- windows-wpf-control-panel.ps1
|   |-- launch-main-codex-cdp.ps1
|   |-- start-windows-local.ps1     # 前台启动服务
|   |-- make-qr.js
|   |-- windows-installer-lifecycle.ps1
|   `-- build-windows-release.ps1
|-- windows/LanCodexLauncher.cs     # Windows GUI 启动器
|-- installer/LAN-Codex.iss         # Inno Setup 定义
|-- assets/windows/                 # Windows 图标
|-- licenses/                       # 随包第三方许可证
|-- server.js                       # 压缩嵌入的服务运行副本
`-- package.json
```

发布机可在项目根目录另放 `lan_gpt_android.apk`。该文件被 `.gitignore` 排除，不进入源码历史。

当前 `server.js` 会解压 Base64/Gzip 数据并通过 `vm.Script` 运行嵌入源码。文件头提到的 `scripts/build-protected-runtime.js` 并未包含在当前仓库中，也没有单独的未压缩服务端源文件。因此，前端和 Windows 脚本可直接修改；若要修改服务核心，必须先补齐可审计的服务源码及确定性的重新打包流程，不能只编辑外层加载器。

## 8. 从源码运行

要求：Windows 10/11、PowerShell 5.1、ChatGPT/Codex 桌面应用。`package.json` 声明 Node.js `>=18.20.0`，但 Windows 启动与发布脚本实际要求 Node.js 20 或更高版本，因此开发环境应使用 Node.js 20+。

本项目没有 npm 第三方依赖，不需要安装依赖即可执行脚本。

```powershell
# 打开 WPF 控制面板；默认服务端口为 8787
npm run windows:panel

# 以前台方式启动 LAN 服务，便于查看日志
npm run windows:start

# 关闭并重新打开受控 ChatGPT/Codex，启用 39252 CDP
npm run windows:cdp
```

`npm start` 也会加载网络守卫并启动服务，但 `server.js` 自身默认端口是 `8788`；若要与正式 Windows 配置一致，应先设置 `PORT=8787`，或使用上述 Windows 脚本。

## 9. 检查与测试

```powershell
# 检查 server.js 外层加载器和网络守卫的 JavaScript 语法
npm run check

# 验证 token 脱敏、私有地址判定、公共 fetch 拦截、入站拦截和授权路由禁用
npm test

# 无需展示窗口的控制面板状态检查
powershell -STA -NoProfile -ExecutionPolicy Bypass `
  -File scripts/windows-wpf-control-panel.ps1 -SmokeTest
```

涉及完整连接链的修改还应人工验证：服务健康检查通过、`39252/json/list` 能发现主页面、手机扫码后能列出线程并发送消息、停止服务后端口释放。

## 10. Windows 构建与发布

构建机还需要：

- Node.js 20+；
- Windows 自带的 .NET Framework 64 位 C# 编译器；
- Inno Setup 6。

执行：

```powershell
npm run build:windows
```

构建脚本会：

1. 将运行文件复制到 `.runtime/release-stage/LAN Codex`；
2. 把当前 `node.exe` 和 Node.js 许可证嵌入发布目录；
3. 用 `csc.exe` 编译 `LAN Codex.exe`；
4. 用 Inno Setup 生成安装器；
5. 生成 portable、source 压缩包和 SHA-256 校验文件。

默认输出位于 `dist/`：

```text
LAN-Codex-Setup-<version>.exe
LAN-Codex-Portable-<version>.zip
LAN-Codex-Source-<version>.zip
Lan-gpt.apk                         # 根目录存在 lan_gpt_android.apk 时生成
SHA256SUMS.txt
```

安装器以管理员权限运行，添加仅限 Windows“专用网络”的 `8787/TCP` 防火墙规则，安装后启动服务。卸载时 `windows-installer-lifecycle.ps1` 先核对服务 PID/命令行再停止进程，随后移除防火墙规则和 `%LOCALAPPDATA%\LAN Codex`，Inno Setup 提供标准 `unins000.exe`。

Android APK 不由 `build:windows` 编译；若根目录存在 `lan_gpt_android.apk`，构建脚本会将其复制为 `dist/Lan-gpt.apk`，并把它写入 `SHA256SUMS.txt`。发布前仍需单独确认 APK 的来源和哈希。

## 11. 修改时的最低验证要求

- 修改 `public/`：至少验证手机宽度、顶部安全区、扫码首次连接和刷新后的 Cookie 鉴权。
- 修改控制面板或启动脚本：验证首次启动、重复启动、端口占用、停止和卸载流程。
- 修改鉴权或网络守卫：先扩充 `scripts/lan-only-guard-test.js`，再运行 `npm test`。
- 修改 CDP 逻辑：同时验证传统安装版和可用的 WindowsApps 版，并确认 CDP 仍只监听回环地址。
- 发布前：运行 `npm run check`、`npm test` 和 `npm run build:windows`，再独立计算所有 Release 资产的 SHA-256。
