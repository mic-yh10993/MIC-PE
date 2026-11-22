# MICPE 运行期启动链

这个目录里的东西会被构建**原样**复制到镜像的 `%SystemRoot%\System32\MICPE`。
仓库里看到的目录结构，就是开机后 `X:\Windows\System32\MICPE` 的结构，没有中间层、
没有生成步骤、没有第三方运行时。改这里任意一行、重新构建，就是全部的定制流程。

```
src/runtime/MICPE/
├── startnet.cmd            唯一入口，只负责按顺序调用阶段
├── phases/
│   ├── 10-osinit.cmd       wpeinit、隐藏空的“启动”文件夹、WinXShell 注册
│   ├── 20-preshell.cmd     USERPROFILE / Desktop / Programs
│   ├── 25-logon.cmd        给 shell 弄一个真正的登录令牌（Administrator）
│   ├── 30-runshell.cmd     读 Winlogon 的 Shell，拉起 explorer 并轮询
│   └── 40-postshell.cmd    等任务栏、清 desktop.ini、隐藏控制台 / 留故障控制台
├── hooks/                  你自己的启动钩子（见 hooks/README.md）
│   ├── osinit/  preshell/  shell/  postshell/
├── uwp-diag.cmd            一键状态 dump（服务、进程、注册表、日志）
├── uwp-start-shell.cmd     手动再拉一次 shell，并打印 explorer 退出码
├── UsrClass.dat            登录 profile 模板（来自 assets/logon）
└── README.md
```

## 为什么入口在 System32

`winpeshl.exe` 只会执行 `%SystemRoot%\System32\startnet.cmd`，文件名写死。所以只有
`startnet.cmd` 这一份被额外复制到 `System32\`，它本身不做任何实际工作，四行 `call`
指向 `phases\`。镜像里同时保留 `System32\MICPE\startnet.cmd` 副本，方便对照。

`winpeshl.ini` 的优先级高于 `startnet.cmd`，一旦存在就会绕过整条链。构建里
`Install-MicpeRuntime` 会删掉它，`Assert-UwpBootChain` 会在打包前再确认一次。

## 五个阶段

| 阶段 | 时机 | 做的事 | 不做的事 |
|---|---|---|---|
| `10-osinit` | 内核起来、尚无用户环境 | `wpeinit.exe`（设备/网络/DHCP）、`Fix-DriveLetters.cmd`（把已装 Windows 留在 C:）、隐藏空启动文件夹、`WinXShell -regist -noaction` | 不碰用户目录、不启动 shell |
| `20-preshell` | 环境变量就绪、shell 之前 | 设 `USERPROFILE=X:\Users\Default` `Desktop` `Programs` `APPDATA` `TEMP` | 不启动窗口，避免抢占前台 |
| `25-logon` | shell 之前 | 起 `seclogon`/`Themes`/`SENS`/`Appinfo`，启用内置 Administrator，克隆 profile，用 `runas` 走 Secondary Logon 给 shell 一个**真正的登录令牌** | 失败不阻断：留不下 `logs\logon-token.flag`，`30-runshell` 照旧用 SYSTEM 拉 explorer |
| `30-runshell` | 环境就绪 | 读 `HKLM\...\Winlogon\Shell`，启动 `explorer.exe`，最多轮询 20 秒确认存活 | 不重试、不循环重启（那会变成满屏弹窗）；`25-logon` 已经拉起过 explorer 时不再拉第二个；WinXShell 只在 Shell 不是 explorer 时才作为外壳启动，不常驻 `-regist -daemon`（`40-postshell` 只用它做等任务栏、隐藏控制台的一次性调用） |
| `40-postshell` | shell 起来之后 | `Taskbar:WaitForReady()`、清 `desktop.ini`、隐藏控制台；shell 没起来则**保留控制台**并打印日志位置 | 不静默失败 |

### 为什么需要 `25-logon`

用 SYSTEM 令牌跑起来的 explorer 只是个“能画图标的进程”：它没有登录会话、没有用户
profile，`打开文件夹窗口 / 回收站 / shell 命名空间` 这些需要真实会话的功能会静默失败。
WimBuilder2 的映像是 Client 底子，开机走真正的登录（Winlogon 登录 Administrator，
再由 `Shell=explorer.exe` 起外壳），所以它没有这个问题。

WinPE 里没法走那条路（会话是 Setup 模式启动的），所以这里用 Secondary Logon 服务
（`seclogon`）直接造一个登录令牌：`runas.exe` → `CreateProcessWithLogonW` → 一个属于
Administrator 的 LSA 登录会话；新进程继承当前控制台的桌面（`WinSta0\Default`），
所以外壳是看得见的。服务定义来自 `src/uwp/reg/values/60-logon-services.reg`，
`seclogon` 在 PE 底子只是空壳（只有 Start 没有 ImagePath/ServiceDll），不补上就永远起不来。

这一步全是尽力而为：任何一步失败都只是退回原来的 SYSTEM 外壳路径，桌面照常出现。

### 输入法为什么默认关掉

`20-preshell` 里 `ctfmon.exe` 的启动被**注释掉**了（2026-11-22 用户要求）：
在 PE 会话里起 ctfmon 之后整个键盘输入失效，连普通英文都打不出来。
输入法不是打字的前提，先让它待在注释里；等外壳稳定之后再放开。

变量是在 `startnet.cmd` 的同一个 cmd 进程里传递的：四个阶段都**不用** `setlocal`，
所以 `20-preshell` 设的 `USERPROFILE` 能被 `30-runshell` 和 explorer 继承。改脚本时
请保持这个约定，一旦加上 `setlocal`，后面阶段就看不到这些变量。

## 日志与排障

| 文件（镜像内） | 内容 |
|---|---|
| `...\MICPE\logs\boot.log` | 四个阶段的时间戳流水，包含每次 hook 调用 |
| `...\MICPE\logs\uwp-shell.log` | `uwp-start-shell.cmd` 手动拉 shell 的退出码 |
| `...\MICPE\logs\uwp-diag.log` | `uwp-diag.cmd` 的完整 dump |

`uwp-diag.cmd` 运行后会额外把日志复制到第一个可写卷的根目录（`?:\micpe-uwp-diag.log`），
因为 `X:` 是内存盘，重启就没了，而测试机通常能读物理盘。

开机黑屏 / 只有壁纸时，按这个顺序看：

1. 屏幕上有没有控制台。`40-postshell` 在 shell 没起来时**不会**隐藏窗口，会打印
   `MICPE: the desktop shell did not start.` 和日志路径 —— 有这段说明链跑到了最后。
2. 控制台里跑 `X:\Windows\System32\MICPE\uwp-start-shell.cmd`，看 `explorer_exit=`
   —— `0xC0000135/-1073741515` 缺 DLL，`0xC0000142/-1073741502` DLL 初始化失败，
   `0xC0000005/-1073741819` 访问违例。
3. 跑 `uwp-diag.cmd`，重点看 `StateRepository`、`AppXSvc`、`Themes` 三个服务和
   `HKLM\SOFTWARE\Microsoft\Windows\DWM\OneCoreNoBootDWM`（必须是 0）。
4. 完全没有任何控制台、也进不去桌面，说明 `startnet.cmd` 没被执行：检查镜像里
   `System32\startnet.cmd` 是否存在、`winpeshl.ini` 是否被人加回来了。

脚本全部是**纯 ASCII + CRLF**，这是有意的：控制台代码页是 CP936，`.cmd` 里出现中文
在某些代码页下会把一行命令截断，报出 `'xxx' 不是内部或外部命令` 这种看不懂的错。
中文说明写 README，不要写进 `.cmd`。

## 定制

- **加点开机动作**：往 `hooks\<阶段>\` 丢一个 `.cmd`，按文件名排序执行，不用改任何
  其他文件。见 `hooks/README.md`。
- **改某个阶段的行为**：直接编辑对应 `phases\*.cmd`，注释里写了每一步的原因。
- **换外壳**：`30-runshell.cmd` 里的分支就是全部逻辑 —— 把 `Winlogon\Shell` 改成
  `WinXShell.exe`，它就会走 WinXShell 分支（需要 `Program Files\WinXShell` 在位）。
- **不要 PECMD**：这条链里没有 PECMD，也没有 WimBuilder2 的 `PEStartupMain.bat`。
  构建末尾的 `Assert-UwpBootChain` 会在 `startnet.cmd` 出现 `PECMD` 或 `PEMaterial`
  字样时直接让构建失败，防止又把外部启动框架混进来。

## 依赖的镜像内容

启动链本身很小，但它假设镜像里有这些（都由 `src/uwp/manifest.json` 的步骤保证）：

| 依赖 | 谁装的 | 缺了会怎样 |
|---|---|---|
| `Windows\explorer.exe` + DLL 集 | `60/61-shell-explorer*.txt` | 桌面起不来，`40-postshell` 留控制台 |
| `System32\ctfmon.exe` | 文件清单 | 无输入法语言栏 |
| `Program Files\WinXShell\WinXShell.exe` | `src/uwp/payload/winshell` | 控制台不隐藏、不等任务栏（桌面仍可用） |
| `ProgramData\...\AppRepository\*.srd` | `src/uwp/payload/apprepository` | `StateRepository` 起不来，UWP 全部不可用 |
| 服务与 AppModel 注册表树 | `reg/copy/*.txt` | 外壳启动后无任务栏/无开始菜单 |
