# Token查询

macOS 菜单栏常驻的 AI 额度监控工具。剩余百分比挂在顶部菜单栏，点开是完整面板，
每家服务商的每个额度窗口各画一个环形图，颜色随余量变化。

当前版本 **v2.0.1**。监控 **Grok**、**Codex**、**Gemini Pro** 三家。

---

## v2.0.1 更新（Gemini Pro 不再依赖 Antigravity 在运行）

这一版只修一个 bug：**关掉 Antigravity 桌面版、只开着 Antigravity CLI 或 Gemini
桌面版时，Gemini Pro 额度读不出来。**

原因是原实现走本机 Antigravity 的 `language_server` 接口，而它有两个前提：

- **Gemini 桌面版根本不跑 `language_server`**，只跑它自己的原生进程，所以这条路对它无效。
- **Antigravity CLI 把 `language_server` 内嵌在自己进程里**（进程名就是 `agy`），
  而且它的 CSRF token 只存在于进程内存中 —— 环境变量、日志、钥匙串里都没有，
  外部进程拿不到，本地端口等于用不了。

改法是不再依赖本地端口，直接调 Google 的云端额度接口，凭据从 Antigravity 的登录信息里读
（桌面版写的文件 / CLI 写的钥匙串，两处都读）。**Antigravity 关着也能读。**

细节见下面「Gemini Pro 额度是怎么读到的」。

---

## v2.0 更新（去掉 DeepSeek，新增 Grok，改成环形图）

这一版是一次方向调整：**只保留按「剩余百分比」计量的服务商**，并加上 Grok。

### 去掉了什么

- **DeepSeek 整个移除。** 它是唯一按**金额**计量的服务商（余额、充值/赠送明细、
  按快照差值推算的消耗趋势），和另外三家不是一个模型。为了它，模型里要维护
  `BalanceSnapshot`、`TrendAnalyzer`、趋势页、金额格式化等一整套东西。
  移除后 `BalanceService`、`SnapshotStore`、`TrendAnalyzer`、`TrendView`、
  `CodexCards` 五个文件整体删掉，**「趋势」页签也随之取消** ——
  剩下的三家接口都不提供用量明细，画不出消耗曲线。
- 菜单栏的「当前账号 / 全部账号合计」二选一也取消了：现在没有金额可合计，
  菜单栏改成**轮播显示**（见下）。
- **面板顶部那个「选择当前账号」的下拉也去掉了。** 它存在的理由是总览页只显示
  「当前账号」的额度；总览改成按服务商一屏列出全部账号之后，下拉已经没有任何东西可切，
  留着反而让人以为切换它会改变下面的内容。现在顶部只留标题、上次刷新时间和刷新按钮。

### 新增了什么

- **Grok（xAI）额度监控。** 详见下面「Grok 额度是怎么读到的」。
- **环形进度图。** 每个额度窗口一个环，圆心是剩余百分比，下方是窗口名和重置时刻。
  颜色按余量分三档：**≥50% 绿、≥20% 橙、<20% 红**（和默认预警线 20% 口径一致）。
  剩余为 0 时**不画任何弧**，而不是留一小段圆头 —— 一小段红弧看起来像「还剩一点点」。
  刷新失败时整个环转灰，和实时数据区分开。
- **「有几个窗口就画几个环」的通用结构。** 三家接口给的窗口模型都不一样，
  统一折成 `QuotaWindow` 列表后，总览页不需要为某一家写特例：
  实测 Grok 给 1 个（周）、Codex 免费版给 1 个（月）、Gemini 给 2 个（5 小时 + 7 天）。
- **账号列表容错解码。** 以前整份 JSON 一次性解码，只要有一条解不出来
  （比如旧文件里还留着已移除的 DeepSeek 账号），**整个账号列表会变成空**且没有任何提示。
  现在逐条解码，坏的那条丢掉并记日志、备份成 `accounts.json.broken`，其余照常加载。
- **字段改名带迁移。** `codexAuthPath` / `codexCredentialKind` / `codexAccountID`
  改成了通用的 `authFilePath` / `credentialKind` / `accountIDHint`（Grok 和 Codex 共用）。
  解码时先读新名、读不到再回退旧名，老账号的配置不会因为改名而丢。

### 这一版修掉的问题

- **通知中心在无 bundle 时会崩。** `UNUserNotificationCenter.current()` 在没有 app bundle 时
  **直接抛 NSException**（`bundleProxyForCurrentProcess is nil`），不是返回 nil、也不是 throw ——
  `do/catch` 拦不住。直接用二进制跑（开发调试、离屏渲染验证）就会踩到。现在先判断再调用。
- **占位环的文案分不清状态。** 「还没查到」和「查询失败」原来都写「正在获取」，
  失败的那张卡片会永远在转圈，看不出其实是报错了。现在分成「正在获取」/「无数据」/「无窗口数据」。

---

## Grok 额度是怎么读到的

**接口**（非官方，Grok Build CLI 自己在用）：

```
POST https://grok.com/grok_api_v2.GrokBuildBilling/GetGrokCreditsConfig
Content-Type: application/grpc-web+proto
Authorization: Bearer <access_token>
body: 空帧 00 00 00 00 00
```

**响应是 gRPC-web 包着的 protobuf**，没有公开 `.proto`，字段号是从真实响应里逆出来的：

```
payload
└─ field 1 (message)              ← 配置本体
   ├─ field 1 (fixed32 float)     ← 总已用百分比（0…100）
   ├─ field 4 (message Timestamp) ← 当前周期开始
   ├─ field 5 (message Timestamp) ← 重置时刻
   ├─ field 7 (repeated message)  ← 产品拆分 { 1: id varint, 2: 百分比 fixed32 }
   └─ field 8 (message)           ← 周期元数据（再嵌一套起止时间）
```

几个容易踩的点：

- **百分比是 fixed32 浮点，不是 varint。** 按 varint 读会读出天文数字。
- **`window` 长度要自己算** —— 接口给的是周期起止时间，相减才是秒数（实测 604800 秒 = 7 天）。
- **必须带浏览器 User-Agent。** grok.com 前面挂着 Cloudflare，默认的 `URLSession` UA 会被
  直接拦掉，回 `403 error code: 1010`。代码里对这种情况单独给了「请求被拦下」的提示，
  和真正的无权限（401/403 JSON）区分开。

### 凭据：读 `~/.grok/auth.json`，过期时自动续期

Grok 的 `auth.json` 顶层是「issuer::client_id → 凭据」的映射，键名随登录方式变化，
所以不能写死键名，得扫一遍找那个带 `key` 的条目。

**access_token 只有 6 小时有效期**（`expires_in: 21600`），比 Codex 的 10 天短得多，
不处理的话这个监控工具基本没法用。所以：

- **过期时（提前 10 分钟算）用 refresh_token 换新的**，`POST https://auth.x.ai/oauth2/token`
- **xAI 的 refresh_token 会轮换** —— 换一次就变一个，所以拿到新的**必须写回**，
  否则下次续期会失败
- 写回是**本程序唯一会写别人文件的地方**，规矩定得很死：
  1. 先加 `auth.json.lock` 的文件锁，跟 CLI 自己串行化（CLI 也用这个锁文件）
  2. 拿到锁之后**重新读一遍盘**，只改 `key` / `refresh_token` / `expires_at` 三个字段，
     其余原样保留 —— 绝不整份覆盖，免得抹掉 CLI 新写的别的状态
  3. 原子替换（写临时文件再 rename），权限收到 600
- 写回失败不影响本次请求 —— 内存里的新 token 照样能用，只是下次还得再续一次

**Codex 刻意不续期**（和以前一样）：Codex 的 `refresh_token` 也是轮换的，刷新后必须写回，
但它的 `auth.json` 结构更复杂、风险更高，所以那边只读不写，过期时提示你打开一次 Codex
（它会自己续期）。**两家策略不同是有意的，不要「顺手统一」。**

---

## 界面说明

菜单栏**轮流显示一家**，形如 `GP 94%` → `GR 37%` → `CX 20%` → …
（`GP` = Gemini Pro、`GR` = Grok、`CX` = Codex）。
三家并排写全太长，菜单栏那一格会把旁边的图标挤掉，所以改成轮播，
默认每 5 秒换一家，可在「设置 → 菜单栏 → 轮播间隔」里改成 3/10/30 秒或关掉。

**关掉轮播时**（轮播间隔选「不轮播」），设置页会多出一行「固定显示」，
可以自己指定菜单栏一直显示哪一家；不指定就按 `Gemini Pro → Grok → Codex` 的顺序取第一家。

**颜色跟着当前这一家自己的额度状态走**，不是全局取最严重的那一方。
分档和总览页的环形图**完全一致**（同一个数字在两处必须是同一个颜色）：

| 颜色 | 图标 | 含义 |
|---|---|---|
| 绿色 | 仪表盘 | ≥50% |
| 橙色 | 警告三角 | 20% ~ 50% |
| 红色 | 八角警示 | <20%，或已被服务端熔断 |
| 红色 | 圆圈感叹号 | 取不到数（凭据失效、网络不通、对方应用没开） |
| 灰色 | 旋转箭头 | 还没查到（首次刷新中），图标用系统模板色不额外上色 |

> 预警线（设置里的「新账号默认预警线」）只用来**发系统通知**，不参与配色。
> 早先菜单栏按「有没有低于预警线」判二值、环形图按三档上色，
> 结果同一个 37% 在面板里是橙环、在菜单栏是绿字 —— 现在统一成上面这一套。

所以同一时刻菜单栏可能是「红色的 Codex」，两秒后切成「绿色的 Gemini」——
看到红色就说明是当前显示的那家出了问题，不是另外两家。

点开后三个页签：

| 页签 | 内容 |
|---|---|
| **总览** | 按服务商分组，**Gemini Pro → Grok → Codex**。每张账号卡片里，**有几个额度窗口就画几个环形图**，下方是窗口名（`5 小时` / `周` / `1 个月`）和重置时刻。Grok 会额外列出周额度的产品拆分；Codex 会显示套餐徽章、额外额度、凭据到期日；每张卡片各带独立的「实时查询」按钮。**一屏列出全部账号**，不需要先选账号 |
| **账号** | 管理账号。**右键**账号可编辑、停用、删除 |
| **设置** | 刷新间隔、菜单栏显示开关与轮播间隔、默认预警线、开机自启、凭据存储、数据位置 |

---

## 安装

提供三种格式，任选其一：

| 文件 | 适合场景 | 安装方式 |
|---|---|---|
| **`Token查询-2.0.1.dmg`** | 分发、分享给别人（Mac 最主流） | 双击打开，把 App 拖进「应用程序」 |
| **`Token查询-2.0.1.pkg`** | 标准安装向导 | 双击，一路「继续」，自动装到「应用程序」 |
| **`Token查询.app`** | 本机快速使用 | 直接拖进「应用程序」 |

> **首次打开**：App 没做 Apple 开发者签名，需要到「应用程序」里**右键**点 Token查询 →「打开」→
> 弹窗里再点一次「打开」。之后双击就正常了。打开后不会出现在 Dock，只在顶部菜单栏显示。

### 首次启动会自动导入

本机装了哪个 CLI 就自动把哪个收进账号列表，**不需要手动操作**：
`~/.grok/auth.json` → Grok、`~/.codex/auth.json` → Codex、Antigravity 已登录 → Gemini Pro。
删掉之后不会再自己冒出来。

---

## 常见问题

**Grok 显示「未检测到 Grok CLI」？**
没找到 `~/.grok` 目录。在终端里跑一次 `grok login` 登录即可。

**Grok 显示「Grok 登录凭据已过期」？**
`access_token` 过期了，而且没有可用的 `refresh_token`。在终端里跑一次 `grok` 或 `grok login`，
它会重新登录，然后回来刷新。

**Grok 显示「请求被 grok.com 拦下」？**
Cloudflare 的风控拦了这次请求。稍后重试；若持续出现，说明非浏览器访问方式已被封。

**Codex 显示「连不上 chatgpt.com」？**
额度接口挂在 `chatgpt.com` 上，国内直连不通，需要让 Codex 能正常联网（例如开启代理）。

**Gemini Pro 显示「本机没有找到 Antigravity 的登录凭据」？**
本机没登录过 Antigravity。打开一次 Antigravity（**桌面版或 CLI 都行**）登录即可 ——
之后**关掉它也能正常读额度**，凭据是登录时落盘的，程序自己会续期。

**Gemini Pro 显示「未检测到 Antigravity」？**
既没有可用凭据，也没探测到 Antigravity 在运行。同上，登录一次即可。

**Gemini Pro 显示「无法读取 Antigravity 的运行状态」？**
进程探测被系统拦下了（`ps` 起不来），同时也读不到 Antigravity 的日志。
和「没开」是两回事，别去反复重启一个本来就正常的应用。

**Codex 只显示「1 个月」，没有 5 小时和周？**
那是账号套餐决定的。免费版只有一个按月的窗口；付费套餐才会给
5 小时 + 周两个窗口，届时两个环会自动都画出来。**界面不写死窗口数量**，
接口给几个就画几个。

**想重新打包：**

```bash
bash build.sh
```

一次生成 `Token查询.app` + `Token查询-2.0.1.dmg` + `Token查询-2.0.1.pkg`。
需要 macOS 自带 Command Line Tools（**不需要**完整 Xcode）。

---

## 技术说明

- SwiftUI + Swift Package Manager，原生 macOS 应用，**不需要完整 Xcode**
- 菜单栏常驻（`LSUIElement`），不占 Dock；兼容 macOS 14 及以上
- 三家都是按「剩余百分比」计量的额度，**没有金额、没有消耗趋势**
- 网络请求失败后退避 15 分钟（手动「实时查询」不受限制）；
  「对方应用没开 / 没登录」这类临时状态不退避

### 两个编译上的坑

**一、`@State` 用不了。** Command Line Tools 自带的 macOS SDK 把 SwiftUI 的 `@State`
改成了宏，而宏实现只随完整 Xcode 分发，纯 CLT 环境会报
`external macro implementation type 'SwiftUIMacros.StateMacro' could not be found`。
工程的 `LocalState.swift` 用 `@StateObject` 实现了一份等价替代。**全项目一律用 `@LocalState`。**

**二、菜单栏弹窗里的 `ScrollView` 必须给固定高度。** 只设 `maxHeight` 会塌缩成 0，
把页签一起吞掉。`PanelView.contentScroll` 给的是 540。

### 探测要起子进程，绝不能放在 SwiftUI 的 body 里

判断「本机能不能读 Gemini Pro 额度」现在主要看**有没有登录凭据**（读文件 / 钥匙串），
进程探测只是兜底 —— 后者要跑 `ps` / `lsof`，而且**是同步等待**的。
结果缓存在 `AppState.geminiAvailable` 里，只在刷新时后台更新，界面只读缓存值 ——
写在 body 里等于每次重绘都 fork 一个进程，面板会卡到没法用。

### 凭据存储

只有「粘贴 access_token」方式的账号才存在本机加密文件里（`CredentialStore`）：

- 密钥派生：`HKDF-SHA256(IOPlatformUUID, salt) → 32 字节`
- 加密：`AES-GCM`，`sealedBox.combined` 直接 base64 存进 JSON
- 两个文件都是 600 权限。注意 `.atomic` 写盘是「写临时文件再改名」，
  新文件权限跟着 umask 走（通常 644），所以 `AppPaths.write` 必须在写完后再
  `setAttributes` 一次，不能指望 write 的 options 带权限
- `credentials.vault.json` 存 salt 和种子来源。**如果这个文件被删而 `credentials.json` 还在，
  绝不能新建密钥** —— 那会静默生成一个解不开已存凭据的新密钥。代码里显式拒绝

**安全性是明确降级的**：本机其他程序仍可解密（它同样读得到 `IOPlatformUUID`）。
防住的是文件被拷走 / 云同步 / 备份 / 误发。换来的是不再每次启动弹密码框。

---

## 已知限制

- **三家的接口都不是官方公开 API**，厂商改版后可能失效：
  Grok 走 `grok.com/grok_api_v2.GrokBuildBilling/GetGrokCreditsConfig`，
  Codex 走 `chatgpt.com/backend-api/wham/usage`，
  Gemini Pro 走 `daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary`
- **Grok 只有周额度，没有 5 小时窗口。** 接口只回一个 7 天周期，
  换请求体也不影响返回。界面上会老实显示成一个环，不编一个窗口出来
- **Grok 的产品拆分只有数字 id**（实测见过 2/4/5/8），可读名字定义在服务端下发的描述符里，
  本机二进制里查不到。所以只对能确定的 id 起名（`1` = API、`2` = Grok Build），
  其余显示成「分项 N」，**不编一个可能错的名字**
- **Gemini Pro 需要本机登录过 Antigravity**（桌面版或 CLI 都行）：凭据在
  `~/.gemini/jetski-standalone-oauth-token`（桌面版写）或登录钥匙串
  （`service=gemini / account=antigravity`，CLI 写）里，程序读它去调 Google 云端接口。
  **登录一次之后，关掉 Antigravity 也能读** —— 用桌面版、CLI 还是 Gemini 桌面版都不影响。
  程序不保存 Google 凭据、不碰登录状态；续期拿到的新 token 只在内存里用，**不回写**
- **Grok 的 access_token 只有 6 小时**。本程序会在过期时帮它续期并写回 `auth.json`；
  如果续期也失败（refresh_token 失效），需要手动跑一次 `grok login`
- 换机器或换主板后需重新填入粘贴型凭据
- 未做 Apple 开发者签名与公证。从网上下载的副本首次打开会被 Gatekeeper 拦下
- 轮询间隔低于 1 分钟可能触发服务端风控，默认 5 分钟

---

## 自己构建

```bash
bash build.sh
```

一次产出 `dist/` 下的 `Token查询.app`、`Token查询-2.0.1.dmg`、`Token查询-2.0.1.pkg`。
App 是 ad-hoc 签名，首次打开需按上面「安装」里的说明放行一次。

程序不需要注册任何账号，所有数据只存在本机。

---

## 许可证

MIT License，见 [LICENSE](LICENSE)。
