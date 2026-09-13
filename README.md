# NativeHarness (DSH Native)

把 [DeepSeek Harness](https://www.npmjs.com/package/@deepseek-ai/dsh) 的 Web UI 装进一个原生
macOS 窗口：SwiftUI 外壳 + 随取随用的 harness 运行时。它自己管理 harness 的安装、更新、
Node 运行时和插件，打开就能用，不需要你手动 `npm install` 或者常驻一个浏览器标签页。

- **原生窗口**：harness Web UI 跑在 App 自带的窗口里，不是浏览器
- **自我供给运行时**：从 npm registry 拉取 `@deepseek-ai/dsh`，缺 Node 时一键装一份私有 Node，
  不污染系统
- **插件与市场**：设置 → 插件 可直接安装/卸载/修复 profile 的插件
- **会话备份**、**审批中心**、**微信 IM 通道**（把会话接到微信，手机也能收发）
- **手机远控**：在微信里直接远控会话——`/list` 列会话、`/use` 接管任意会话（含桌面新建的）、
  `/history` 看历史、`/say` 续聊、`/stop` 中断、`/answer` 回答 harness 的提问；发 `/help` 看全部
- **微信里切换工作区**：`/workspace` 列出 harness 已登记的工作区（与侧栏同一份数据），
  `/workspace 2`、`/workspace ~/项目/x` 直接切换；切换会解绑当前微信会话，下一条内容在新工作区开新会话
- **手机推送**：主窗口顶部一个按钮，打开后任何会话需要批准或回答时都会推到微信，
  回「批准」/「拒绝」或 `/answer` 即可；关掉就恢复成只有微信会话转发
- **安全启动与恢复模式**：harness 起不来时的两条退路——先摘插件（安全模式·无插件），
  再摘整个 home（干净环境）——以及一个从菜单栏打开的恢复窗口，可回滚到上一次健康启动
- **纯本地**：所有数据都在你自己的用户目录下，没有遥测、没有账号

> ⚠️ **非官方项目**。本仓库是第三方客户端外壳，与 DeepSeek 官方无隶属或背书关系。
> 它下载并运行的 `@deepseek-ai/dsh` 是官方项目，其许可与使用条款以官方为准。
> 另外，应用图标含 DeepSeek 品牌标识、**不在 MIT 许可范围内**，详见 [NOTICE.md](NOTICE.md)。

---

## 环境要求

| | 要求 |
|---|---|
| 系统 | macOS 15 (Sequoia) 或更高 |
| 架构 | **Apple Silicon (arm64)** — 见下方[已知限制](#已知限制) |
| 构建工具 | Xcode 16+（含命令行工具）、Swift 6、**Node.js**（生成 Xcode 工程用，`node` 在 PATH 上） |
| 网络 | 首次启动需要能访问 `registry.npmjs.org` 与 `nodejs.org` |

检查一遍：

```bash
sw_vers          # ProductVersion 需要 >= 15
uname -m         # 需要 arm64
xcodebuild -version
node --version
```

---

## 安装到启动台（Launchpad）

**没有 Apple 开发者账号也能装。** 这个项目用 ad-hoc 签名（`CODE_SIGN_IDENTITY=-`）本地构建，
不需要任何证书、不需要公证（notarization），也不需要付费的开发者账号 —— 因为 App 是你自己
在本机构建的，Gatekeeper 不会拦它。下面的命令做完就能在启动台里看到它。

把仓库克隆到本地，`cd` 进仓库根目录，然后跑三条命令：

```bash
cd /path/to/native-harness
Tools/build.sh release          # ① 构建 Release 版 App
Tools/build.sh install --no-build   # ② 安装进 ~/Applications
Tools/build.sh verify           # ③ 逐项验证
```

如果你的路径和上面不一样，把第一行的 `cd` 换成你自己的仓库路径即可，其余不用改。

**这三条命令分别在做什么：**

1. `Tools/build.sh release` — 用 `xcodebuild` 构建 Release 版，产物落在
   `/tmp/harness-native-build/DSHNative.app`。这是一个自包含的 `.app`，不依赖 Xcode、
   不依赖 DerivedData。
2. `Tools/build.sh install --no-build` — 把上一步的产物 `ditto` 进 `~/Applications`
   （免管理员密码，且启动台会索引这个目录），然后重新注册到 LaunchServices。
3. `Tools/build.sh verify` — 检查「启动台会不会显示它、双击会不会真的启动」：包完整性、
   可执行文件、代码签名、图标、bundle id、LaunchServices 注册。全通过则退出码为 0。

`verify` 成功时长这样：

```
checking /Users/<你>/Applications/DSHNative.app
  [ok]   bundle exists
  [ok]   executable present (arm64)
  [ok]   code signature verifies
  [ok]   app icon declared (AppIcon) and present
  [ok]   bundle id ai.deepseek.nativeharness.DSHNative
  [ok]   registered with LaunchServices — Launchpad will list it
all checks passed
```

然后打开启动台（触控板四指捏合，或 Dock 里的火箭图标），翻到应用页，点 **DSHNative** 启动。
首次启动会下载 harness 运行时，需要一点时间。

### 为什么必须这样装，不能直接在 Xcode 里 Run？

因为 **Xcode 的 ▶ Run 只会把产物写进 DerivedData**，而启动台/聚焦只索引固定几个目录：

| 会被索引 | 不会被索引 |
|---|---|
| `/Applications` | `~/Library/Developer/Xcode/DerivedData/...` |
| `~/Applications` | `~/Documents/...`、`/tmp/...`、桌面、下载 |

Xcode 里没有任何开关能把 App「加进启动台」—— 唯一的路就是把 `.app` 放进上面左边那两个目录，
这正是 `install` 做的事。另外 Debug 产物开了 `ENABLE_DEBUG_DYLIB`，真代码在
`DSHNative.debug.dylib` 里、只有 Xcode 启动时才解析得到，拷出来也没法双击运行，所以必须用
**Release** 构建。

`install` 会把 `Tools/build.sh release` 和复制两步合并；也可以直接用：

```bash
Tools/build.sh install          # = 构建 + 安装
Tools/build.sh install --wait   # 安装后等到 LaunchServices 真正索引到
Tools/build.sh install --system # 装到全局 /Applications（会要管理员密码）
Tools/build.sh install --dock   # 顺便钉到程序坞
```

以后改了代码，重跑 `Tools/build.sh install` 覆盖即可，启动台里还是同一个图标。

---

## 启动之后的第一次运行

App 不会把自己塞进系统目录，它在你的用户目录下维护一棵自己拥有的运行时树（默认
`~/.nativeharness`，可用环境变量 `NATIVE_HARNESS_ROOT` 覆盖）：

| 路径 | 内容 |
|---|---|
| `~/.nativeharness/harness/` | harness 的各个 release、`installs.json`、`current`、日志、检查点 |
| `~/.nativeharness/home/` | 交给 harness 的 `DSH_HOME`：profiles、sessions、settings、credentials |
| `~/.nativeharness/runtime/` | npm 缓存等 |
| `~/.nativeharness/safe-mode/` | 只在进行安全启动时存在：模式标记，以及「干净环境」用的一次性 home |

首次启动如果本机没有可用的 harness release 或 Node，App 会引导你下载安装。
（把 harness 装进 `.app` 内部是行不通的：bundle 有签名封印，往里写会破坏签名。）

### 多开窗口：同一个 harness，同时看两个页面

harness Web UI 没有 URL 路由，页面状态活在 React state 里——所以「同时看两个页面」不是两个
标签页，而是两个窗口，各自持有一份自己的 Web 页面：一个窗口停在会话 A 继续跑，另一个窗口翻到
设置或插件市场，互不干扰。滚动位置、打开的对话、当前会话都是每个窗口自己的。

**Harness ▸ 新建窗口（⌥⌘N）** 可以反复点击，每次多一个窗口。

- 窗口是**同一个 harness 的第二个视图**，不是第二个 harness：会话、工作区、正在跑的那一轮
  都在服务端，两个窗口看到的是同一份数据。所以在一个窗口里发消息，另一个窗口会跟着更新。
- **服务器只有主窗口能启停**。多开的窗口没有 Start / Stop / Restart / Rebuild——两个窗口
  同时按这些按钮等于一个进程有两个主人。harness 没起来时菜单项是灰的，因为那时没有页面可挂。
- 主窗口停掉 harness 时，多开的窗口会显示「harness 未运行」，而不是继续摊着一个已经断掉的页面。

### 可选：让「插件管理 / 命令行工具」可用

任何需要调用 `dsh` 命令的功能（最典型的是 **设置 → 插件** 的安装/卸载）都要求 PATH 上有
`dsh`，否则报 `spawn dsh ENOENT`。装一个不写死版本的 shim：

```bash
Tools/build.sh shim
dsh --version    # 打印当前 harness 版本
```

shim 运行时去读 App 自己的 `installs.json` 拿 active release，所以 App 升级后自动跟着换。

---

## 安全启动与恢复模式

装了插件之后 harness 起不来，是这个 App 最需要处理的一类故障：插件加载器没有逐插件隔离，
一个坏插件会把整次启动带下去，而通常用来关掉它的界面（Web UI）正好打不开。菜单栏
**Harness** 里有三个入口。

### 启动模式：先摘插件，再摘整个 home

| 模式 | 用的 home | 用的 profile | 隔离掉的东西 |
|---|---|---|---|
| 正常启动 | 真实 | `web` | —— |
| **安全模式 · 无插件** | 真实 | `rescue`（官方 web 模板，只有官方 bundle） | 第三方插件 |
| **干净环境** | 一次性 | `web` | 插件 + `home/cordis.patch.yml` + settings + 凭据 + 会话 |

两者都**复用你已经装好的那份 harness release 和 Node**，不下载、不复制。诊断顺序因此是可判定的：

```text
安全模式能起来              → 是某个第三方插件的问题
安全模式起不来、干净环境能起来 → 问题在 home 层（patch / settings / 凭据 / 会话）
两个都起不来                → 问题在 release / Node / 端口等 App 侧，恢复窗口会给结论
```

- **安全模式用的是你的真实 home**，所以 API key、会话和设置都还在——确认是插件问题之后还能继续用。
  代价是：安全模式下的对话会写进真实 `sessions/`。
- **干净环境是一次性 home**（`~/.nativeharness/safe-mode/home`），不含凭据也不读你的设置；
  退出或下次正常启动时整个删掉。要"零副作用诊断"就用它。
- 退出安全模式**不会删除** `rescue` profile：它只有三个声明文件，下次还会用到；
  要删它在恢复窗口里单独操作（需要确认）。
- 菜单栏里还有 `以安全模式重启（无插件）` / `以干净环境重启` / `退出安全模式并重启`。

### 恢复模式窗口（⌥⌘R）

Harness ▸ **恢复模式…**，harness 起不来时也能用。它操作的是**真实** `DSH_HOME`，所以在安全模式
里也照样能修你的正常 profile。四个分区：

1. **启动模式** —— 三个模式的当前状态与切换（切换会写标记并重启 App；创建 `rescue` profile 在
   重启**之前**做，失败会当场报错，而不是让你重启进一个起不来的模式）。
2. **配置检查与修复** —— `检查（不启动）` 只做组合与导入检查；`停用坏插件并重试` 会一轮轮真实启动，
   关掉被启动输出点名的插件（和主窗口的 "Disable Broken Plugins and Retry" 是同一条逻辑）。
3. **回滚** —— 每次 harness 确认在监听之后都会记录一份**声明式配置**的快照（3 个轮换槽：
   profile 的 `package.json` / `pnpm-lock.yaml` / `pnpm-workspace.yaml` / `cordis.patch.yml`，
   以及 `home/settings.yaml` / `home/cordis.patch.yml`）。还原前先给你预览哪些文件会变，还原时
   先停 harness。**不运行 pnpm、不复制 `node_modules`**——依赖可能需要自行重装。
   刻意不备份 `cordis.yml`（harness 每次启动都会重写它）。
4. **数据与诊断** —— 真实 `DSH_HOME`、日志目录、当前 release / Node，打开目录或复制路径。

安全模式下 **微信通道不会启动**，**DSH Market 菜单项禁用**（安全启动里没有任何客户端插件可加载）；
会话备份仍然指向真实 home，因为"把会话恢复回来"本身就是恢复的一部分。

---

## 从源码构建（开发者）

```bash
Tools/build.sh              # 构建所有 target（swift build）
Tools/build.sh test         # 跑测试（swift test）
Tools/build.sh build --target HarnessKit   # 只构建某个 target（注意要显式写 build）
Tools/build.sh xcode DSHNative       # xcodebuild 一个 scheme（Debug）
Tools/build.sh clean        # 清掉构建缓存与产物
Tools/build.sh verify       # 验证已安装的 App
```

**为什么必须经过 `Tools/build.sh` 而不是直接 `swift build`**，有两个真实原因：

1. `swift-driver` 在 `TMPDIR` 含非 ASCII 字符时会 **SIGTRAP 崩溃**。若你的仓库路径含中文
   （比如 `.../Documents/我的项目/...`），直接 `swift build` 会报
   `Failed to parse target info (malformed(json: "", ...))`，看起来像编译器 bug，其实不是。
   脚本把 `TMPDIR` 固定到 ASCII 路径 `/tmp/harness-native-build/tmp`，从而绕开。
2. SwiftPM 会给子进程套自己的 `sandbox-exec` 配置，在受限环境里会因不允许嵌套
   `sandbox_apply` 而失败，所以脚本传 `--disable-sandbox`。

Xcode 工程 `NativeHarness.xcodeproj` 是**生成出来的**（由 `Tools/gen-xcodeproj.mjs`），
`xcode` / `release` 每次都会先重新生成。所以新增源文件后不要手改 `.pbxproj`，重跑一遍命令即可。

### 目录结构

```
Apps/DSHNative/      @main App、窗口与菜单（SwiftUI）
Sources/
  HarnessKit/        领域模型与引擎契约（无 UI 依赖）
  HarnessCore/       Route B：harness 核心的 Swift 重实现
  HarnessRuntime/    运行时供给：安装/更新 harness、Node、插件、release 校验
  HarnessUI/         共享 SwiftUI 界面
  HarnessConsoleUI/  控制台 / 插件 / 市场窗口
  HarnessIM/         微信 IM 通道（协议、批处理、与运行中 harness 通信）
  harnessctl/        命令行工具
  CZstd/             唯一链接 vendored libzstd 的地方
Vendor/zstd/         随仓库附带的 libzstd 静态库
Tools/               构建、安装、验证、工程生成脚本
Tests/               单元测试与 fixture
Spec/                向上游对齐的请求头、工具 schema、会话事件 schema
```

---

## 已知限制

- **仅 Apple Silicon**。`Vendor/zstd/lib/libzstd.a` 只有 arm64 切片，Intel Mac 的
  x86_64 链接会失败（而且失败后仍会留下一个双击无反应的半成品 `.app`）。要在 Intel 上构建，
  需要重新编译 libzstd 为 x86_64 或 universal。
- **未公证、未做 Developer ID 签名**。本机构建即装即用；但如果你把构建产物打包分发，
  别人下载后会被 Gatekeeper 拦（需要 `xattr -dr com.apple.quarantine` 或自行签名/公证）。
- App 图标等品牌素材的授权情况见 [`NOTICE.md`](NOTICE.md)（如存在）。

---

## 排错

| 现象 | 原因与处理 |
|---|---|
| `Failed to parse target info (malformed(json: "", ...))` | 直接跑了 `swift build` 且路径含中文。改用 `Tools/build.sh` |
| `swift build` 报 sandbox / `Operation not permitted` | 脚本已带 `--disable-sandbox`；请勿绕过脚本 |
| 设置 → 插件 报 `spawn dsh ENOENT` | 跑 `Tools/build.sh shim` |
| 启动台里看不到 App | 确认装到了 `~/Applications` 或 `/Applications`，然后 `Tools/build.sh verify` 看哪一项 FAIL |
| 双击 App 没反应 | 多半是半成品包（链接失败的产物仍会被签名）。重跑 `Tools/build.sh install` |
| 想整体搬走运行时目录 | 用 `Tools/relocate-root.sh`（会先退出 App、同卷原子 `mv`，并在旧路径留软链） |

`Tools/build.sh install --quit` 的一个注意点：这个 App 会接管（杀掉旧进程）已在运行的
harness，所以当有浏览器窗口正由同一个 harness 提供服务时，退出它会连带关掉那个窗口。

---

## 卸载

```bash
osascript -e 'tell application id "ai.deepseek.nativeharness.DSHNative" to quit'
rm -rf ~/Applications/DSHNative.app
rm -rf ~/.nativeharness          # 运行时会话、配置、插件全在这里，删前想清楚
rm -f /opt/homebrew/bin/dsh      # 如果装过 shim
```

---

## 许可

本仓库代码以 [MIT](LICENSE) 发布。上游 `@deepseek-ai/dsh` 与 harness 本体不包含在本仓库中，
其许可与条款请见官方项目。
