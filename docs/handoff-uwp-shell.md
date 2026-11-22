# 交接说明：UWP 桌面启动链（半成品状态）

> 分支：`feature/uwp-shell-desktop`
> 交接日期：2026-11-22
> 状态：**能出桌面，但有已知功能缺陷**。详见下面「已完成 / 未完成」。

这份文档面向接手的人。目标是让你在 10 分钟内知道：现在能跑什么、跑不起来什么、
哪些坑已经踩过了不用再踩、以及下一步该动哪个文件。

---

## 1. 一句话现状

Explorer 已经能起来、能显示桌面图标。**Ctrl+Alt+Del 无响应、回收站打不开、
输入法不可用**（wb2 的映像同样没有输入法）。StartAllBack 3.6 已集成，
Win11 样式任务栏与开始菜单待真机确认。

---

## 2. 现在能跑什么

| 项 | 状态 |
|---|---|
| PE 启动 → 桌面 | ✅ 能进桌面，回收站等图标可见 |
| Explorer 作为外壳 | ✅ 由 `Winlogon\Shell=explorer.exe` 拉起 |
| 自有启动链 | ✅ `startnet.cmd` → 四个阶段 → hooks，无 PECMD / 无 wb2 运行期依赖 |
| UWP AppX 组件 | ⚠️ 文件与注册表齐了，运行时未逐项验证 |
| StartAllBack 3.6 | ⚠️ 文件与注册表已进镜像，钩子是否真被 explorer 映射未验证 |
| Ctrl+Alt+Del | ❌ 无响应 |
| 回收站 | ❌ 双击打不开 |
| 输入法 | ❌ 不可用（**故意关掉的**，见 §6） |

---

## 3. 目录地图

```
src/
├── uwp/                          UWP 桌面构建链（声明式）
│   ├── manifest.json             配置 + 执行顺序（27 步，唯一入口）
│   ├── filelists/*.txt           文件清单（从 wb2 导入后自己维护）
│   ├── reg/copy/                 整键复制：services.txt + keys.txt
│   ├── reg/values/*.reg          字面值补丁（7 个 .reg）
│   ├── payload/winshell/         WinXShell 二进制 → Program Files\WinXShell
│   ├── payload/apprepository/     StateRepository .srd（AppX 必需）
│   └── README.md                 资产说明
│
├── runtime/MICPE/                运行期脚本 → System32\MICPE
│   ├── startnet.cmd              唯一入口，只 call 四个阶段
│   ├── phases/10-osinit.cmd      wpeinit、隐藏启动文件夹、WinXShell 注册
│   ├── phases/20-preshell.cmd    USERPROFILE/Desktop/APPDATA 环境
│   ├── phases/25-logon.cmd       用 seclogon 建真实登录令牌（关键，见 §5）
│   ├── phases/30-runshell.cmd    拉起 explorer 并轮询确认存活
│   ├── phases/40-postshell.cmd   等任务栏、清 desktop.ini、隐藏控制台
│   ├── hooks/<phase>/*.cmd       你的自定义钩子，按文件名排序执行
│   ├── uwp-diag.cmd              一键状态 dump（排障入口）
│   └── README.md                 启动链与排障说明
│
├── build/lib/
│   ├── UwpChain.ps1              集成脚本：Install-MicpeRuntime 等
│   ├── Wb2List.ps1               清单解析器（wb2 方言）
│   └── Wim.ps1 / Shell.ps1       原生登录、SOFTWARE 蜂巢处理
│
└── filelists/70-logon.txt        LogonUI / 凭据提供程序 / XAML 文件集

app/
├── startallback/                 StartAllBack 3.6（files/ + reg/ + install.bat）
└── start11/                      Start11 1.3.2.0（默认关闭，与 SAB 互斥）

tools/Import-Wb2UwpChain.ps1     只在重新抓 wb2 清单时用一次
scripts/Invoke-LocalBuild.ps1    本地构建入口
```

---

## 4. 怎么构建

```powershell
.\scripts\Invoke-LocalBuild.ps1 -Workspace 'E:\micpe' -Stage wb2 -SkipDownload
```

需要管理员权限（挂载 WIM）。阶段内容：
`base → reseed → explorer → runtimes → components → uwpchain → iso`。

产物：`E:\micpe\out\MICPE.iso`（约 1.85 GB，boot.wim 1.71 GB）。
最近一次构建 SHA256 `7F24C66A79C64C863F3C67141E2CAE9346E0E1EC7062FE83FD3321C92C4F69B6`。

---

## 5. 已经踩过的坑（别再踩一遍）

### 5.1 PECMD 事故 —— 选错启动链

最早一版误用了 wb2 的 `startnet`（回退分支会 `call probe.cmd`，而 `probe.cmd`
带 UTF-8 BOM，且里面有 `start /min cmd` 三个 watcher + 循环拉 explorer）。
症状：`PECMD.EXE not found`、控制台窗口反复弹、`'·'` 不是命令、explorer 无限重启。

**现在**：wb2 分支用本项目自己的 `startnet.cmd`；`Assert-UwpChain` 会拒绝
`PECMD` / `PEMaterial` / `winpeshl.ini` 出现在镜像里。

### 5.2 清单守卫正则 —— 静默丢弃整块文件

wb2 方言里的 `+if "x%VER_202505_LATER%"="x1"` 把一整块文件包住。
旧正则匹配不到**带引号且变量在引号外**的写法 → 整块被静默丢弃 →
`mdmregistration.dll` 缺失 → explorer 静态导入失败（`STATUS_DLL_NOT_FOUND`）
→ 三次尝试全部失败且**没有任何报错**。

**现在**：正则改成容忍 `"x%VAR%"="x1"`；未知变量**直接报错**而不是当空值。
`src/build/lib/Wb2List.ps1` 里有变量表与版本阈值（26100.4061 / 26100.4946）。

> 教训：清单解析器遇到不认识的变量必须响亮地失败。静默跳过 = 缺文件 = 玄学 bug。

### 5.3 `reg query` 误命中 `AutoRestartShell`

```bat
reg query Winlogon /v Shell | find "Shell"
```
会同时命中 `AutoRestartShell`（DWORD `0x1`）。必须过滤 `REG_SZ`。

### 5.4 PE 环境里 `powershell.exe` / `whoami.exe` 不存在

PE 的 `System32` 里没有这两个。`uwp-diag` 里凡是调它们的都要改成
`reg query` / `tasklist` / `dir` 这类 PE 自带工具。

### 5.5 `net start` 对已运行的服务会打印 2182 错误行

这不是失败。诊断脚本里不要因为这行就判定服务没起来。

### 5.6 ACL：AppRepository 与 CredDialogController.dll 写不进去

- `ProgramData\Microsoft\Windows\AppRepository` 属主是 TrustedInstaller
- `System32\Windows.UI.CredDialogController.dll` 同理

原位写入报 Access denied。解法：`Grant-FolderWriteAccess`（takeown +
`icacls /Grant *S-1-5-32-544:(OI)(CI)F` + `attrib -R`）。

### 5.7 MiniNT 补丁

`Windows.UI.CredDialogController.dll` 和 `InputService.dll` 里同长度的
`MiniNT` 字符串改成 `NiniNT`。等长替换，不动文件大小。

### 5.8 编码约定（硬性）

- `.cmd`：**纯 ASCII + CRLF**。中文注释在 CP936 控制台会被截断成半个字符，
  后面的命令直接崩。
- `.reg`：**UTF-16LE + BOM**。且 `Windows Registry Editor Version 5.00`
  必须是第一行 —— 注释插在它前面会导致整个文件被 `reg import` 忽略。

### 5.9 镜像里的 HKCU 是 `config\DEFAULT`

PE 特性：没有 `Users\Default\NTUSER.DAT` 这条路径可用（那只是 64 KB 空骨架）。
per-user 设置要写 `PE-DEF` 别名（见 `src/build/lib/Registry.ps1` 的 HiveMap）。

---

## 6. 当前三个缺陷的定位与建议

### 6.1 Ctrl+Alt+Del 无响应

**已排除**：不是注册表问题。镜像里曾**没有 `LogonUI.exe`** —— winlogon 收到
SAS 后要交给 LogonUI 画「Windows 安全」屏，没有它就只能沉默。

**这一版已补**：新增 `src/uwp/filelists/72-logon-ui.txt`（LogonUI.exe +
凭据提供程序宿主 + XAML 运行时 + PRI），以及
`src/uwp/reg/values/60-logon-services.reg`（seclogon / SENS / Appinfo / Schedule
四个服务定义）。

**下一步**：真机验证。如果还无响应，用 `uwp-diag.cmd` 的
`reg query "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v DisableCAD`
和 `dir "%SystemRoot%\System32\LogonUI.exe"` 两行确认。

**临时可用**：Ctrl+Shift+Esc（走 shell，直接起任务管理器）。

### 6.2 回收站打不开

**已排除**：不是缺 CLSID、不是缺 KnownFolder、不是缺 wb2 `NewBrowseDlg`
那套文件（comctl32 / ExplorerFrame / rshx32 / DataExchange / dcomp / d3d11 /
dxgi / chartv / OneCoreUAPCommonProxyStub / actxprxy / StructuredQuery /
prevhost / shellstyle —— 全在）。`$Recycle.Bin` 目录不存在是正常的（X: 是内存盘，
外壳应自建）。

**当前最可能的根因**：外壳跑在 SYSTEM 令牌下，没有真正的登录会话，
`IFileOperation` 一类调用直接静默失败。`phases/25-logon.cmd` 就是为这个加的
—— 用 `runas.exe`（seclogon）建 Administrator 的登录令牌再拉 explorer。
**这一版已加入，但真机未验证。**

**下一步**：看 `X:\MICPE\logs\boot.log` 里 `logon-token.flag` 有没有生成。
生成了说明令牌建成了，回收站还不行就是别的问题；没生成说明 seclogon 那条路
没走通，去查 `60-logon-services.reg` 的服务键是否被正确导入。

**需要用户回答**（上次问过，还没回）：
1. 双击回收站是**彻底没反应**，还是**窗口闪一下就没** / 弹错误框？
2. **双击「此电脑」能正常开窗口吗**？—— 用来区分「所有文件夹窗口都起不来」
   还是「只有回收站」。

### 6.3 输入法不可用

**故意关掉的**（用户 2026-11-22 要求：「先把输入法注入给注释掉，让我能打字先」）。
`src/runtime/MICPE/phases/20-preshell.cmd` 里 ctfmon 的启动块被注释掉了，
原因写在同文件注释里。

wb2 的映像同样没有输入法 —— 这不是我们做错了。

**恢复方法**：取消 `20-preshell.cmd` 里那段注释即可。

---

## 7. StartAllBack / Start11

### StartAllBack 3.6（已启用）

```
app/startallback/
├── install.bat        CI 里跑：files/ → 镜像 Program Files\StartAllBack
├── files/             厂商目录平铺副本（53 个文件，含 Styles/Orbs/Ribbon/lang）
├── reg/software.reg   Classes 注册（49 个键，由 wb2 的 SAB_RegSoftware.reg 转换）
├── reg/default.reg    外观/默认项（手写、可随便改）
└── README.md          为什么、怎么改、坑在哪
```

**关键取舍**：wb2 那份 settings 把皮肤固定在 `Styles\Plain8.msstyles`（Win8 任务栏）。
用户要 Win11 样式，所以 `default.reg` 里**故意不写** `AlterStyle` / `TaskbarStyle`，
让 SAB 保持原生 Win11 皮肤。要换皮就加一行指到 `Windows 7.msstyles`，
或直接替换 `files/Styles/`。

**验证方法**：`uwp-diag.cmd` 里的 `tasklist /m /fi "imagename eq explorer.exe"`
能直接证明 explorer 有没有把 SAB 的钩子 DLL 真的映射进进程。

### Start11 1.3.2.0（默认关闭）

文件到位。`install.bat` 会把 `hooks/50-start11.cmd` 投进
`System32\MICPE\hooks\postshell` —— Start11 不是「注册即生效」，必须有个进程起。

钩子里有两条判断：目录不存在就退；检测到 `StartAllBackX64.dll` 也退
（两个外壳会抢任务栏）。

**已知缺口**：它的 shell 钩子类 `{6A451C0A-9597-4915-BCCE-6E859BC996B2}`
（`Start10Shell Class`）对应的 CLSID 注册**还没写**（没有可信清单，不猜）。
真机验证发现缺什么就补哪儿，`app/start11/README.md` 里有说明。

---

## 8. 排障入口

真机进桌面后先跑：

```
X:\System32\MICPE\uwp-diag.cmd
```

它会打印：服务状态、进程、注册表、`$Recycle.Bin` 是否存在、LogonUI 是否在、
Winlogon `DisableCAD`、SAB 文件与设置、以及 explorer 的模块列表。

日志位置：`X:\MICPE\logs\`（`boot.log` 等）。

手工再拉一次 shell：`X:\System32\MICPE\uwp-start-shell.cmd`
（会打印 explorer 的退出码含义：0xC0000135 缺 DLL / 0xC0000142 初始化失败 /
0xC0000005 访问违例）。

---

## 9. 想改点什么，改哪里

| 想做的事 | 改哪里 |
|---|---|
| 改启动顺序 / 加步骤 | `src/uwp/manifest.json`（27 步，`kind` 决定类型） |
| 改某个阶段的逻辑 | `src/runtime/MICPE/phases/*.cmd` |
| 加自己的启动钩子 | `src/runtime/MICPE/hooks/<phase>/*.cmd`，按文件名排序执行 |
| 改装了哪些文件 | `src/uwp/filelists/*.txt`（一行一个路径，相对镜像根） |
| 改注册表 | `src/uwp/reg/values/*.reg`（字面值）或 `reg/copy/*.txt`（整键复制） |
| 换外壳 | `manifest.json` 的 `startAllBack` / `start11` 两个布尔 |
| 换 StartAllBack 版本 | 覆盖 `app/startallback/files/` |
| 改外观 | `app/startallback/reg/default.reg` |

**不需要**碰构建脚本。manifest 是声明式的，加一步就是加一条 JSON。

---

## 10. 已知的未决问题清单

- [ ] 回收站打不开 —— 根因待 §6.2 的两个用户回答确认
- [ ] Ctrl+Alt+Del —— LogonUI 已补，待真机验证
- [ ] 输入法 —— 故意关闭，待用户决定何时恢复
- [ ] StartAllBack 钩子是否真被 explorer 映射 —— 待 `tasklist /m` 确认
- [ ] Start11 的 CLSID 注册缺失 —— 待补
- [ ] UWP AppX 组件运行时未逐项验证（文件齐 ≠ 能跑）
- [ ] `sud.dll` / `van.dll` 在本介质 `install.wim` 里**不存在**（wb2 的 SAB 清单
      要求它们），故未加 —— 如果真机 SAS 有问题，这里是第一个要查的

---

## 11. 提交历史说明

这个分支包含两个相对独立的工作：

1. `phase1-admin-logon` 的 4 个提交（原生登录链路，来自 main 之后的实验分支）
2. 本分支新增的 UWP 桌面构建链（27 步 manifest + 四阶段启动链 + app 组件）

两者都保留在这个分支里，方便对照。CI 里的 `-NativeLogonExperiment` 开关
把两者隔开：原生登录模式下跳过 QEMU probe，改跑静态验证。
