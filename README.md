# MICPE

MICPE 是一个基于 Windows 11 的装机维修盘（WinPE），从 U 盘或光盘启动后进入一个可联网、可轻量办公上网的桌面环境，用于装系统、备份、修复与应急上网。

本项目通过 GitHub Actions 从 UUP dump 的官方 Windows 11 镜像构建，全流程无人工介入，产物为可直接启动的双启（BIOS + UEFI）ISO。

## 原生管理员登录状态

`phase1-admin-logon` 分支目前仍处于原生登录可行性验证阶段，**尚未实现或证明 WinPE 中的真实交互式 Administrator 登录**。当前 Explorer 注册表配置和启动脚本不能作为真实登录已完成的证据：`startnet.cmd` 仍由 WinPE 启动链执行，现有实现曾通过 PECMD 启动桌面；`20-explorer.reg` 将 `Userinit` 留空；`src/filelists/70-logon.txt` 目前只是文件清单，不能单独建立 Winlogon 登录会话。

目标验收条件、验证步骤和停止条件见 [`docs/native-logon-feasibility.md`](docs/native-logon-feasibility.md)。在这些条件全部通过前，不应把直接启动 `LogonUI.exe`、由 SYSTEM 启动 Explorer，或仅设置 `Shell=explorer.exe` 标记为“原生 Administrator 登录”。

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

## 构建

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
