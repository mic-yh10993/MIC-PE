# MICPE

MICPE 是一个基于 Windows 11 的装机维修盘（WinPE），从 U 盘或光盘启动后进入一个可联网、可轻量办公上网的桌面环境，用于装系统、备份、修复与应急上网。

本项目通过 GitHub Actions 从 UUP dump 的官方 Windows 11 镜像构建，全流程无人工介入，产物为可直接启动的双启（BIOS + UEFI）ISO。

## 原生管理员登录状态

`phase1-admin-logon` 分支已实现基于 `tsdiscon.exe` 的原生登录链路：SYSTEM 阶段完成 PE 初始化、用户配置单元、自动登录注册表和 AppX 服务准备后断开会话，由 Winlogon 建立新的交互式会话并以内置 Administrator（RID 500、空密码）登录；`Userinit` 在认证会话中执行 `logon-admin.cmd`，再启动 Explorer / 任务栏 / 开始菜单 / UWP 组件，启动路径不再经过 PECMD。

旧的 `shutdown /l` + `AutoAdminLogon=0` 方案在 WinPE 中不会触发真实登录，会退回 startnet 的 `cmd.exe` 窗口（即“开机卡在 startnet”）；该方案已移除。

### 黑屏 / SAS 失效修复（对照 WimBuilder2）

仅写几个 `Winlogon` 注册表值不足以让 RID 500 真正登录 —— 同一个映像在 WimBuilder2 下能进入原生 UWP 桌面，是因为它的 `LogonAdmin.bat` / `SwitchToAdmin.bat` 还完成了三件我们此前遗漏的事。现在这些都已补齐：

1. **`secedit /configure` 应用 `unattend.inf`**（`[System Access] EnableAdminAccount=1`）在运行时启用内置 Administrator；否则账户保持禁用，`AutoAdminLogon` 静默失败，新会话无法建立 → 黑屏、Ctrl+Alt+Del 无响应。
2. **`LSAgetRights.exe -c -u Administrator`** 给 RID 500 授予 SYSTEM 级令牌特权（`SeAssignPrimaryTokenPrivilege` / `SeImpersonatePrivilege` / `SeCreateTokenPrivilege` 等）；缺这些时新会话里启动的 shell 会失败并报“引用不存在的令牌”（`STATUS_NO_SUCH_LOGON_SESSION`）。
3. **`UsrClass.dat` + 预建 RID-500 配置文件**：22621+ 没有 `UsrClass.dat` 无法创建管理员配置文件；构建时把 `UsrClass.dat` 放入 Default 与 Administrator 配置目录，并用 `config\Default` 预建 `Users\Administrator\NTUSER.DAT`，运行时写 `RefCount=2` 与 `FirstLogon=0`。

同时按 WimBuilder2 的 `SwitchToAdmin` 补齐了 LogonUI / 凭据提供程序 / XAML 文件（`AuthExt.dll`、`Windows.UI.Xaml*`、`credprovhost.dll`、`Windows.UI.Logon` PRI 等）、`SpecialAccounts\UserList\Guest=0`、`LowRiskFileTypes`，并保留运行时清 `SystemSetupInProgress`（构建期必须为 1，否则开机徽标阶段 0xEF）。这三件 helper 资产随仓库 `assets/logon/` 提供，构建自包含。

**当前状态：代码已实现并通过静态验证（WIM 内账户/令牌/profile/注册表/文件齐备，39 项定向测试全部通过），等待真机/QEMU 运行时确认。** 启动后请在桌面环境检查 `native-logon-bootstrap.log` / `native-logon-session.log`，并确认 `X:\native-logon-probe.txt` 的 `session_non_system=1` 且 `session_sid` 以 `-500` 结尾，才能认定为原生登录。原生登录镜像不会写传统 `micpe-probe.txt`，因此 CI 在该模式下改用静态验证。

目标验收条件、验证步骤和停止条件见 [`docs/native-logon-feasibility.md`](docs/native-logon-feasibility.md)。在这些条件全部通过前，不应把直接启动 `LogonUI.exe`、由 SYSTEM 启动 Explorer，或仅设置 `Shell=explorer.exe` 标记为“原生 Administrator 登录”。

## UWP 桌面构建链

UWP 桌面的文件集和注册表键最早是从 WimBuilder2 的 `Projects/WIN10XPE`
（`zp-UWPAppX` + `00-Shell/Explorer`）扒出来的，但落到本仓库之后**就是本项目自己的
代码**：一个声明式清单定顺序，纯文本清单定文件，注册表按目录分类，运行期脚本是自己
写的四个阶段。构建和开机都不需要 WimBuilder2，也不需要它的图形界面。

- 资产与说明：[`src/uwp/README.md`](src/uwp/README.md)
- 启动链与排障：[`src/runtime/MICPE/README.md`](src/runtime/MICPE/README.md)
- 集成脚本：`src/build/lib/UwpChain.ps1`（`Install-WbUwpChain`）
- 清单解析：`src/build/lib/Wb2List.ps1`（wb2 的 `@dir` / `+ver` / `+if` 方言）
- 导入工具：`tools/Import-Wb2UwpChain.ps1`（只在重新抓清单时用一次）

复现的配置：**UWP 默认配置 / WinXShell 外壳槽位选 Explorer / UWP 组件全开 /
外壳里的开始菜单不打开 / 使用 StartAllBack 3.6（Win11 样式任务栏与开始菜单）**。
这份配置机器可读地记在 `src/uwp/manifest.json`。

新增阶段 `wb2`（不动原有 m1–m7）：

```powershell
.\scripts\Invoke-LocalBuild.ps1 -Workspace 'E:\micpe' -Stage wb2 -SkipDownload
```

阶段内容：`base → reseed → explorer → runtimes → components → uwpchain → iso`。
`uwpchain` 与旧的 `uwp` 是**替代关系**，不是串联关系（两者装的是同一套 AppX 文件）。

注册表分两类存放，便于二次开发：

| 目录 | 内容 | 来源 |
|---|---|---|
| `src/uwp/reg/copy/` | `services.txt`（58 个服务键）、`keys.txt`（39 个注册表树） | 从 wb2 `RegCopy`/`RegCopyEx` 提取，构建时从源 `install.wim` 整键复制 |
| `src/uwp/reg/values/` | 5 个手写字面值补丁（外壳槽位、任务栏、`Setup\AllowStart`、主题默认、DWM/SYSTEM 配置文件） | 人工维护 |

### 启动链（自己的四个阶段，不走 PECMD）

`src/runtime/MICPE/` 整棵树会原样落到 `%SystemRoot%\System32\MICPE`，其中只有
`startnet.cmd` 额外复制一份到 `System32\`（`winpeshl.exe` 的文件名是写死的）：

```
System32\startnet.cmd          四行 call，把控制权交给下面的阶段
System32\MICPE\phases\10-osinit.cmd      wpeinit、隐藏空启动文件夹、WinXShell 注册
System32\MICPE\phases\20-preshell.cmd    USERPROFILE/Desktop/Programs、ctfmon
System32\MICPE\phases\30-runshell.cmd    读 Winlogon Shell、起 explorer、轮询存活
System32\MICPE\phases\40-postshell.cmd   等任务栏、隐藏控制台 / 保留故障控制台
System32\MICPE\hooks\<阶段>\*.cmd        你自己的钩子，按名排序执行
```

- **不用 PECMD**：M2 那份 `src/shell/startnet.cmd` 仍在（m1–m7 阶段还靠它的 PECMD.INI 链），
  但 wb2 阶段既不安装 `PECMD.EXE`/`PECMD.INI`，也不引用它们。
- **不带 CI 探针**：`probe.cmd` 与三个 watchdog 只属于 m\* 阶段的 CI 镜像。wb2 是产品镜像，
  这些文件不注入（v1 镜像正是因为把探针打进去了，开机会不停弹 cmd 窗口、反复重启 explorer）。
- **失败要看得见**：`30-runshell` 只尝试一次、最多轮询 20 秒，不做重试循环；shell 没起来时
  `40-postshell` 保留控制台并打印日志位置，而不是留一块黑屏。
- **构建期兜底**：`Assert-UwpBootChain` 校验根 `System32\startnet.cmd` 依次调四个阶段、
  不含 `PECMD` / `PEMaterial`、且没有 `winpeshl.ini` 抢启动，回归会直接让构建失败。

定制方式只有一条：改 `src/runtime/MICPE/` 里的文件（或在 `hooks/` 里加钩子），重新构建。
没有需要点的选项，也没有需要另外装的上游工程。

## 系统要求

- **内存：至少 4 GB**。`boot.wim` 会完整载入内存盘，这是 WinPE 的固有工作方式；2 GB 内存的机器**无法**进入桌面。
- 架构：仅 x64（amd64）。不提供 ARM64。
- 语言：简体中文。

## 功能

- 原生 Explorer 桌面、任务栏与开始菜单
- 原生 UWP 支持：设置、照片、新版媒体播放器
- 网络：有线 DHCP 自动获取，`PENetwork` 作为兜底配置工具
- 微软拼音输入法
- 一键装机工具 `MICPE-Setup`：开机自动扫描装机源并弹窗
- 预装维护工具：DiskGenius、Dism++、WinNTSetup、GhostCGI、7-Zip、Everything、BOOTICE、CPU-Z 等

## 装机源发现协议（`install.mic`）

MICPE 只认标记文件，不猜：

1. 卷根存在 `install.mic` 的卷**就是**装机源卷
2. `install.mic` 是纯文本，首行是显示用的系统名（例如 `MICPE 定制系统 v1`）
3. 装机映像固定位于该卷的 `sources\install.wim`
4. 没有标记时降级匹配：`sources\install.wim` → `install.wim` → `sources\install.esd` → `*.esd`

任何自行封装的系统 ISO 只要保持与原版微软 ISO 同构（`sources\install.wim`）并放入 `install.mic`，就可以被 MICPE 直接识别。

## 本地构建（推荐，无需 GitHub Actions）

用仓库自带的 `scripts/Invoke-LocalBuild.ps1`，从**管理员 PowerShell 7** 会话运行。它会注入本地工具链（wimlib / 7-Zip / oscdimg / QEMU）、从你提供的 Windows 11 ISO 取 `install.wim` + `boot.wim`、构建原生登录镜像，并可选地用 QEMU 启动验证。

前置条件：

- 管理员权限（`dism /Mount-Image` 需要）
- 工作区卷至少 35 GB 空闲（`install.wim` 约 8 GB，加上挂载展开与 ISO）
- 工具已放在 `C:\Users\S-I-M\WorkBuddy\2026-11-21-16-33-41\.tmp-ref\tools\bin`（7z / wimlib-imagex / oscdimg）和 `.tmp-ref\qemu`（QEMU + OVMF 固件）——脚本顶部路径可按实际位置改

```powershell
# 首次完整构建 + QEMU 验证（2 vCPU / 4 GB）
cd <仓库根目录>
.\scripts\Invoke-LocalBuild.ps1 -Workspace 'F:\micpe' -NativeLogonExperiment -Verify

# 重建复用已提取的 wim（跳过 8 GB 提取，快很多）
.\scripts\Invoke-LocalBuild.ps1 -Workspace 'F:\micpe' -NativeLogonExperiment -SkipDownload -Verify

# 换源 ISO / 换阶段 / 改虚拟机配置
.\scripts\Invoke-LocalBuild.ps1 -Workspace 'F:\micpe' -SourceIso 'D:\win11.iso' -Stage m7 -NativeLogonExperiment -Verify -CpuCount 2 -MemoryMb 4096
```

产物为 `<Workspace>\out\MICPE.iso`；每次构建都会在 `<Workspace>\logs\invoke-localbuild-<时间戳>.log` 自动保存完整构建日志（成功或失败都落盘）。QEMU 验证结果在 `<Workspace>\verify-out\`（`share\micpe-probe.txt` 里 `session_non_system=1` 且 `session_sid` 以 `-500` 结尾才算真正 Administrator 登录）；原生登录镜像也可以用 `scripts\Invoke-NativeLogonVerify.ps1` 单独验证。源码 ISO 默认取自 `C:\Users\S-I-M\Downloads\Windows11_Client_x64_zh-cn_26300_9457.iso`。

注意：26300 的 `install.wim` 只在 WinSxS 中保存 `tsdiscon.exe` / `tscon.exe`，且是 DCS 压缩流，wimlib 提取出来不是可执行的 PE 文件。构建脚本改为从构建主机的 `System32` 复制这两个文件，并在复制前用 Authenticode 验证签名必须为有效的 Microsoft 签名。

## CI 构建（GitHub Actions）

在本仓库的 Actions 页面手动触发 `Build MICPE`：

| 输入 | 说明 |
|---|---|
| `stage` | 构建到哪一期（`m1`–`m7` 或 `all`），每期都可独立出 ISO |
| `build` | UUP dump 构建号，默认 `26300`（Windows 11 26H2） |
| `office` | 是否内置 Office 2016 绿色版（默认关，占约 330 MB） |
| `chrome` | 是否内置 Chrome（默认关，占约 280 MB） |
| `verify` | 验证档位：`full`（含 QEMU 运行时验证）/ `static` / `none` |

构建完成后，ISO 以 7-Zip 分卷形式发布到 Release。下载全部 `.001`、`.002`… 分卷到同一目录，用 7-Zip 打开 `.001` 解压即可。

## 验证

CI 分三档自验证，不依赖人工：

- **L1 静态**：Pester 单测、PowerShell 语法、清单与注册表文件可解析
- **L2 结构**：WIM 可挂载、体积断言、注册表键存在、ISO 可回读、BCD 可解析
- **L3 运行时**：QEMU 冷启动真实 PE，通过 `vvfat` 回写通道读取 PE 内自检结果（`probe.txt`），并用 monitor 截图判定桌面是否绘制

运行时验证的产物（`probe.txt`、`shot*.png`、`qemu.log`）作为 artifact 上传，失败原因可直接从 `probe.txt` 的 `key=value` 读出。

## 许可

本仓库自有代码以 [GPL-3.0](LICENSE) 发布。

**不包含在 GPL 覆盖范围内**的第三方组件：

| 组件 | 用途 | 来源 |
|---|---|---|
| Windows 11 系统文件 | PE 底座与 UWP 栈 | UUP dump 下载的微软官方镜像 |
| PENetwork | 网络配置工具 | 第三方免费软件 |
| PECMD | PE 脚本解释器 | 第三方免费软件 |
| DiskGenius / Dism++ / WinNTSetup / GhostCGI / 7-Zip / Everything / BOOTICE / CPU-Z / MEMTEST / Snapshot / Imagine / WimTools / GoHash / WinosInfo | 维护工具 | 各自官网或原作者发布 |

这些二进制不出现在 git 仓库中，而是通过 CI 从 Release 资产或上游下载后注入镜像。仓库中只保留构建脚本、文件清单与配置。

## 作者

SYSTEM-Intel-MIC · <https://space.bilibili.com/1978487514>
