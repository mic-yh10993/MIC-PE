# UWP 构建链

这个目录是 MICPE 的 **UWP 桌面构建链**。第一步的素材来自
[WimBuilder2](https://github.com/slorelee/wimbuilder2) 的 `Projects/WIN10XPE`
（那套文件集和注册表键是它试出来的），但落到本仓库之后就是**本项目的声明式清单**：
一个 `manifest.json` 定顺序，`filelists/*.txt` 定文件，`reg/**` 定注册表，
运行期脚本在 `src/runtime/MICPE/`，全部是可以直接读、直接改的代码。

构建期和运行期都**不需要** WimBuilder2：它没有出现在镜像里，也没有出现在构建流程里。
导入器只在重新抓清单时用一次。

- 集成脚本：`src/build/lib/UwpChain.ps1`
- 构建期消费的资产：本目录
- 运行时脚本：`src/runtime/MICPE/` → 安装到 `%SystemRoot%\System32\MICPE`
- 导入工具：`tools/Import-Wb2UwpChain.ps1`（把 wb2 的 .bat 翻译成下面的清单）

## 复现的 WimBuilder2 配置

| 选项 | 取值 | 说明 |
|---|---|---|
| UWP 配置 | 默认 | 使用 `zp-UWPAppX` 默认文件集，不做额外增删 |
| WinXShell 外壳 | **explorer** | Shell 槽位指向 Explorer，`opt[shell.app]=explorer` |
| UWP 组件 | **全开** | Taskbar / Settings / TaskManager / ShellComponents 全启用 |
| 外壳里的开始菜单 | **不打开** | 不含 `za-StartMenu`（Classic Shell），`11-StartMenu` 也不应用 |
| StartAllBack | **已启用** | `app/startallback/` 提供 3.6 x64 复制品，Win11 样式任务栏与开始菜单；由 `startAllBack: true` 控制 |
| Start11 | **备用，默认关** | `app/start11/` 提供 1.3.2.0；与 StartAllBack 互斥（两个外壳会抢任务栏），需手动改 `start11: true` 且关掉 `startAllBack` |
| 壁纸 | 项目原有 | `assets/wallpaper.jpg`，由 `50-brand.reg` + Brand 步骤负责 |

`manifest.json` 是这套配置的机器可读版本，`startMenu: false` 与 `classicShellStartMenu: false`
两处控制开始菜单，`startAllBack: true` / `start11: false` 控制用哪套第三方外壳。

## 目录结构

```
src/uwp/
├── manifest.json              配置 + 执行顺序（唯一入口）
├── filelists/                 从 wb2 AddFiles 块导入的文件清单（自动生成）
│   ├── 10-appx-runtime.txt            AppX 运行时 CLR/UCRT 垫片
│   ├── 11-appx-system.txt             AppX 系统层（服务、WinRT、输入）
│   ├── 20-appx-services.txt           AppX 服务宿主 / StateRepository
│   ├── 30-appx-apps.txt               UWP 应用运行时
│   ├── 31-appx-apps-extra.txt         第二轮补充
│   ├── 40-appx-core.txt               AppX 部署核心 + AppRepository
│   ├── 41-appx-shellcomponents.txt    任务栏 / XAML 外壳 / SystemResources
│   ├── 42-appx-taskmgr.txt            UWP 任务管理器
│   ├── 50-taskbar.txt                 原生任务栏
│   ├── 51-startmenu.txt               UWP 开始菜单（默认不应用）
│   ├── 52-settings.txt                UWP 设置
│   ├── 60-shell-explorer.txt          Explorer 外壳公共文件
│   ├── 70-dwm.txt                     桌面窗口管理器
│   └── 61-shell-explorer-app.txt      explorer.exe 及其 DLL 集
├── reg/
│   ├── copy/                  从源镜像整键复制的清单（自动生成）
│   │   ├── services.txt               58 个服务键（AppXSvc 等）
│   │   ├── keys.txt                   39 个注册表树（AppModel / Appx / ...）
│   │   └── report.txt                 每个源文件贡献了多少条（审计用）
│   └── values/                手写的字面值补丁
│       ├── 10-shell-explorer.reg      外壳槽位 + Winlogon + 快捷方式图标
│       ├── 20-taskbar.reg             任务栏搜索框 / 任务视图
│       ├── 30-services-allowstart.reg Setup\AllowStart（Themes、CoreMessaging）
│       ├── 40-themes-default.reg      默认用户的可视样式（否则桌面是黑的）
│       └── 50-wb2-shell-runtime.reg   DWM 合成、SYSTEM 配置文件、ProfSvc/Appinfo
├── payload/                   二进制资产（不是脚本，不能手写）
│   ├── winshell/              WinXShell（隐藏控制台、等任务栏、备用外壳）
│   └── apprepository/         StateRepository 的两个 .srd 数据库
└── README.md
```

运行期脚本不在这里，在 `src/runtime/MICPE/`，它有自己的
[README](../runtime/MICPE/README.md)：那一份才是开机链的说明文档。

## 清单文件格式

`filelists/*.txt` 每行一个**镜像相对路径**，正斜杠分隔：

```
Windows/System32/AppXDeploymentClient.dll
Windows/SystemApps/Microsoft.UI.Xaml.CBS_8wekyb3d8bbwe/
```

- 以 `/` 结尾表示**整棵目录树**（构建时单独调用 wimlib 递归提取）
- `#` 开头是注释
- 源镜像里不存在的条目由 `wimlib --nullglob` 跳过，不中断整批

> wb2 自己也不统一：`\Program Files\WindowsApps\` 带尾斜杠，`\Windows\SystemApps` 不带。
> 两种都是目录，wimlib 对目录路径一律递归提取，所以行为一致；尾斜杠只影响构建日志里
> 是否单独开一个提取批次。

`reg/copy/*.txt` 每行一个 `HKLM\...` 键路径。构建时从源 `install.wim` 的
`SYSTEM`/`SOFTWARE` 蜂巢 `reg export` 出来、改写根路径、再 `reg import` 进目标蜂巢 ——
这就是 wb2 的 `RegCopy`：值、值类型、子键、默认值都和源镜像一模一样，不是手写近似。

`reg/values/*.reg` 使用**挂载后的蜂巢地址**：

| 地址 | 对应 |
|---|---|
| `HKEY_LOCAL_MACHINE\PE-SOFT` | 目标镜像的 `SOFTWARE` |
| `HKEY_LOCAL_MACHINE\PE-SYS` | 目标镜像的 `SYSTEM` |
| `HKEY_LOCAL_MACHINE\PE-DEF` | 目标镜像的 `DEFAULT` |

## 执行顺序

`UwpChain.ps1` 按 `manifest.json` 的 `steps` 顺序跑：

1. 运行时 → 系统层 → 服务宿主 → 应用运行时（两轮）→ AppX 核心
2. 外壳组件 → 任务管理器 → 任务栏 → 设置
3. Explorer 外壳（公共文件 + explorer 应用集）→ DWM → **LogonUI / 凭据提供程序 / XAML 运行时**
4. 注册表：整键复制（服务 + 注册表树）→ 字面值补丁（外壳 / 任务栏 / AllowStart /
   主题默认 / DWM 与 SYSTEM 配置文件 / 登录服务定义 / NewBrowseDlg 外壳扩展）
5. 运行期：`src/runtime/MICPE/` → `System32\MICPE`，`startnet.cmd` → `System32\`，
   WinXShell → `Program Files\WinXShell`，两个 `.srd` → `ProgramData\...\AppRepository`
6. 组件（`app` 步骤）：`app/startallback/install.bat` 把文件铺到
   `Program Files\StartAllBack`，再导入它自己的 `reg/*.reg`。是否执行由 manifest
   根上的 `"startAllBack": true` 决定；`app/start11/` 同理，默认 `false`
7. 结构断言：`AppXDeploymentClient/Server`、`Windows.UI.Xaml`、`System32\MICPE` 必须
   存在；`AppXSvc / AppReadiness / ClipSVC` 三个服务键必须已复制；外壳前置文件
   （`explorer.exe`、`MDMRegistration.dll`、`shell32.dll`、`twinui.pcshell.dll`、
   `Windows.UI.Xaml.dll`、`CoreMessaging.dll`）必须落地；开机链必须指向
   `MICPE\phases`，且不含 `PECMD` / `PEMaterial`

### 第 3、4 步里两个不是从 wb2 抄来的补丁

| 步骤 | 为什么要有 |
|---|---|
| `72-logon-ui.txt` | **Ctrl+Alt+Del**。SAS 由 winlogon 交给 LogonUI；只有 WinPE 底子时镜像里根本没有 LogonUI，winlogon 只能把桌面切到 Winlogon 桌面然后无人应答 —— 表现就是「一按就卡死」。这套文件（LogonUI.exe、凭据提供程序宿主、XAML 运行时）来自 install.wim，和 wb2 映像里那份同源 |
| `60-logon-services.reg` | **登录令牌**。`seclogon` 在 PE 底子里是空壳（只有 Start，没有 ImagePath / ServiceDll），`SENS` / `Appinfo` / `Schedule` 干脆不存在。`src/runtime/MICPE/phases/25-logon.cmd` 用它们走 Secondary Logon 给 shell 造一个真正的 Administrator 登录令牌 —— 用 SYSTEM 令牌跑的 explorer 打开文件夹/回收站会静默失败 |
| `61-newbrowsedlg.reg` | wb2 `SharedPatch NewBrowseDlg` 里的属性页处理程序注册，缺了「属性 → 安全」页 |

## 重新导入（升级到新版 WimBuilder2）

```powershell
# 解压新版 WimBuilder2 后：
.\tools\Import-Wb2UwpChain.ps1 -Wb2Root E:\wb2 -OutRoot .\src\uwp -Build 26300
```

导入器负责 wb2 方言的求值，构建期只读「干净清单」：

| wb2 语法 | 导入时如何处理 |
|---|---|
| `@\Windows\System32\` | 记录当前基础目录 |
| `\Windows\...` | 转成镜像相对路径 |
| `a.dll,b.dll` | 拆成多条 |
| `\Windows\Fonts\` | 保留结尾 `/`，构建时递归整树 |
| `%CatRoot%\x.cat` | 展开成 `Windows/System32/CatRoot/{F750E6C3-...}/x.cat` |
| `+ver >= 22621` / `+ver*` | 按 `-Build` 求值，满足则保留，否则丢弃 |
| `+if "%X%"="1"` / `<>` / `Or` | 按 `manifest` 的 profile 变量求值 |
| `call RegCopyEx Services "A,B"` | 记进 `reg/copy/services.txt` |
| `call RegCopy <key>` | 记进 `reg/copy/keys.txt`（自动补 `HKLM\`、合并重复反斜杠） |

注意：`+ver` 和 `+if` 是**两种独立**的条件，wb2 里 `+ver ... +ver*` 用一条 `-if` 收尾，
导入器按「版本窗口」和「布尔块」分别跟踪，不共用栈。

## 二次开发

### 加一个文件

不需要动 wb2，直接编辑对应 `filelists/*.txt`（文件头写了「自动生成，勿手改」，
如果要长期保留，请连同 `tools/Import-Wb2UwpChain.ps1` 的 `$jobs` 表一起改，
否则下次导入会覆盖）。

### 加一步

在 `manifest.json` 的 `steps` 里加一项：

```json
{ "name": "我的补丁", "kind": "values", "file": "40-my.reg" }
```

支持的 `kind`：`files`（`file` 指 filelists 下的名字）、`regcopy`（`services` + `keys`）、
`values`（`file` 指 reg/values 下的名字）、`runtime`（`dir` 指仓库内目录）、
`app`（`install` 指组件目录里的 `install.bat`，`reg` 是同一组件的 `.reg` 列表）。

加 `"enabled": false` 可以关掉一步而不删它；`"requiresStartMenu": true` 会在
`startMenu=false` 时自动跳过；`"requiresFeature": "<flag>"` 读取 manifest 根上的
同名布尔值，`false` 时整步跳过——外壳替代品就是用这个开关整套进出的。

`app` 步骤的意义：组件的文件、注册表、启动项都留在 `app/<组件名>/`，这里只写
一句"装它"。加一个新组件不需要改 `UwpChain.ps1`。

### 改运行时行为

去 `src/runtime/MICPE/`。那是本项目自己的启动链（`startnet.cmd` + `phases/` +
`hooks/`），完整说明、日志位置、排障顺序都写在
[`src/runtime/MICPE/README.md`](../runtime/MICPE/README.md) 里。

一句话版本：加点开机动作 → 往 `src/runtime/MICPE/hooks/<阶段>/` 丢 `.cmd`；
改开机顺序或某一步行为 → 直接编辑 `phases/*.cmd`；改完 `-Stage wb2` 重新构建即可，
不需要 WimBuilder2，也不需要调它的图形界面选项。

镜像里没有 PECMD，也没有 wb2 的 `PEMaterial` 目录。构建末尾的 `Assert-UwpBootChain`
会在 `startnet.cmd` 出现 `PECMD` / `PEMaterial` 字样时直接让构建失败。

### 导入器什么时候用

`tools/Import-Wb2UwpChain.ps1` 只在「升级 WimBuilder2、想重新抓一遍文件清单和注册表
键」时用，它是**离线翻译工具**，构建期完全不调用 wb2。日常改东西不需要它，
直接改 `filelists/*.txt`、`reg/**` 就够；只是下次重新导入会覆盖 `filelists/`，所以
长期要留的增删请同步写进导入器的 `$jobs` 表。

### 对齐 wb2：守卫求值必须严格

清单里的 `+if` 是 wb2 的条件语法，本项目用 `Get-Wb2DefaultVars` 复刻它的变量
（`VER[3]` / `VER[4]`、`VER_202505_LATER`、`opt[shell.app]`…），阈值直接照抄
`Projects/WIN10XPE/main.bat`：26100.4061 起 `VER_202505_LATER=1`，26100.4946 之后
`VER_202508_LATER=1`。

两条硬规则（v2 的教训）：

- 守卫里出现变量表没有的变量 → **导入直接报错**，不再默认当空串。早期实现把
  `+if "x%VER_202505_LATER%"="x1"` 静默判成 false，于是 `mdmregistration.dll` 和
  `SystemSettings.DataModel.dll` 整块被丢掉；explorer.exe 静态导入
  `MDMRegistration.dll`，结果 shell 连进程都起不来（三次尝试、无任何报错）。
- 构建末尾 `Measure-UwpChainCompleteness` 逐条统计每个 filelist 的
  `present/total`，并断言 shell 前置文件（`explorer.exe`、`MDMRegistration.dll`、
  `shell32.dll`、`twinui.pcshell.dll`、`Windows.UI.Xaml.dll`、`CoreMessaging.dll`）。
  带 `*`/`?` 的条目按通配符匹配，因为 wb2 的清单本来就有 `CatRoot\*.cat` 这类模式。

## 已知边界

- 这是 **UWP 桌面所需的最小文件集**，不是完整的 Windows。Win32 控制面板、IE、
  .NET Framework 等由别的步骤（`30-runtimes.txt` / `40-components.txt`）负责。
- `51-startmenu.txt` 被导入但默认不应用。要在测试时打开开始菜单，把
  `manifest.json` 里对应步骤的 `enabled` 改成 `true`，并把 `startMenu` 改成 `true`。
- `41-appx-shellcomponents.txt` 里包含 `\Windows\SystemApps` 整树，体积主要来自这里；
  想减体积优先裁这个目录，而不是删 System32 里的 DLL。
