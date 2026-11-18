# payload.md — 三个 payload 包的来源、哈希与分卷方法（M5，打包轮已改）

MICPE 的三个预装包直接提交在仓库 `app/` 文件夹里，构建时拼回、
验 SHA256 才用。**不再走 GitHub Release**（用户决定 2026-11-17
15:07）：旧的三个 Release（`payload-v1` / `chrome-v1` / `office-v1`，
2026-11-17 14:44 发布）已于分卷版验证通过后删除；`Get-PayloadReleaseAsset`
的下载路径已退役，唯一包来源就是 `app/` 树。

## 包清单

| 包 | 仓库路径 | 拼回后大小 | SHA256（拼回后的归档） |
| --- | --- | --- | --- |
| payload | `app/payload/micpe-payload.7z`（单文件） | 28,564,811 B（解压后约 56 MB） | `c95737c250d34244a548d12c983f8c73aa479271d4889201429fac5c9960319e` |
| chrome | `app/chrome/chrome-slim.7z.001`、`.002` | 125,367,407 B（解压后约 440 MB） | `df82dc28b2e0615656dae8b362eab15dd0d8efea7941a78a5e79d0f1a95ca626` |
| office | `app/office/office2016-slim.7z.001`、`.002` | 167,504,937 B（解压后约 454 MB） | `8a5ec5d7d8b77303029769f2f9e043b5f6c98e0cdd7cf5d6b56dc8e2ef6301f7` |

哈希钉在 `src/build/lib/Payload.ps1` 的 `$script:PayloadHashes` 里，
钉的是**拼回后的归档**（不是单个分卷）；构建时 `Get-AppPackageArchive`
拼回再逐个验，mismatch 直接报错停下。重打归档必须同 commit 更新 pin，
绝不静默放宽。分卷用 `split -b 95M`（GitHub 单文件上限 100 MB），
`.gitignore` 对 `app/` 里的包文件放行。

## 来源（全部已核实，2026-11-17）

材料出自用户提供的参考包 `~/workspace/MIC-PE-recovery/MIC-PE.7z`
（691,681,071 字节，逐片 SHA 全过），已解包到
`~/workspace/micpe-m5-material/`。`/root/micpe-ref/` 在本机不存在，
plan.md 里引用它的几行已在 M5 改掉，不要再引用。

- **payload**：`PE预装软件/直接塞入programfiles/`（112 个文件，
  55,092,430 字节）+ DSI 的 PECMD.EXE。打包方法见“发布方法”，
  用 `New-PayloadArchive` 可复现（两次连续构建哈希一致）。
  内含：`7-zip`（目录名必须小写，GhostCGI 硬编码依赖）、PENetwork、
  DiskGenius、WinNTSetup（含 `unattend/Win10_x64.xml`）、GhostCGI、
  Dism++、Everything 等。`Program Files\MICPE\PECMD.EXE` 是 DSI 的
  PECMD.EXE，不是 GhostCGI 自带的副本。
- **chrome**：`PE预装软件/安装包/googlechromestandaloneenterprise64.msi`，
  Google Chrome 企业版独立安装包，151.0.7922.138（Google LLC，
  WiX Toolset 6.0.2.0，x64），164,831,232 字节，SHA256
  `0ec77319d917eb232f1b1b52e0f6f6178eacb2d5abff1517f5c17d50a0a2db1a`。
  第三方专有安装包，原样分发。**精简**（打包轮）：从 MSI 提取出的文件
  树上删掉 `Locales/` 里除 en-US、zh-CN 各 4 个 `.pak` 之外的 212 个
  语言包（约 45 MB），删掉 `WidevineCdm/` 整个目录（DRM 插件，约 22 MB），
  其余保留；重打 `chrome-slim.7z`（顶层 `Chrome-bin/`），95 MB 分卷。
- **office**：`PE预装软件/安装包/Office.7z`，Office 2016 绿色精简版，
  170,364,185 字节，SHA256
  `8bb9a924b72e5d70968121d1ed88df8bea74823e4f8aed1598d766b2a3cb7caf`，
  解压后约 474 MB，顶层目录 `Office2016/`，内含
  `Office16/WINWORD.EXE`、`EXCEL.EXE`、`POWERPNT.EXE`。
  第三方专有软件，原样分发。**精简**（打包轮）：删掉 Access 相关
  36 个文件（`MSACCESS.EXE` 15,794,848 字节、`MSACC.OLB`、
  `ACEDAO.DLL` ×2、`ACECORE.DLL`、`ACCESS12.ACC`、`TellMeAccess.nrr`、
  `AccessWeb/`、`MsAccessLogo*` 图标等，共约 20 MB），删掉厂商原有的
  安装卸载脚本 `!)inst.cmd`、`-)unist.cmd`（自写集成脚本，不用厂商的）；
  `OSPP.VBS` 保留；重打 `office2016-slim.7z`（顶层 `Office2016/`），
  95 MB 分卷。

## PECMD.EXE 供应（M5 定案）

- **用哪个**：DSI 附带的副本
  `dsi/DSI-安装备份-源码/make/PECMD.EXE`（PE32+ x64 GUI，
  1,077,760 字节，文件日期 2024-06-06），SHA256
  `7a3710297473cbb865408d41db362e6014fd3eeaaf819751495e6d928e7adf5e`。
  design.md §6.5 已指定它“可直接作为运行时”。
- **不用哪个**：`GhostCGI/pecmd.exe`（1,173,504 字节，2021-06-22，
  SHA256 `79d8da20850b7c1d3e7c1dbae3e90d4470685a7d6d375d09007f3e25eff3e4e0`）
  是另一个二进制，随 GhostCGI 工具自带，原样留在 GhostCGI 文件夹里，
  不作运行时。
- **怎么供**：payload 资产路线——随 `micpe-payload.7z` 一起走，
  打包时拷到 `ProgramFiles\MICPE\PECMD.EXE`（startnet.cmd 要的路径）。
  不从网上下载：PECMD2012 官网（作者 mdyblog 的 163 博客）已无可用
  的官方直链，没有可信哈希的来源不拉。
- **硬规则**：PECMD.EXE 是第三方免费软件，绝不提交进公开仓库
  （design.md 约束：不入 git、不入 GPL 覆盖范围）。`New-PayloadArchive`
  在 PECMD.EXE 缺失时明确报错停下，绝不静默跳过——旧的打包命令里
  `2>/dev/null || true` 会让缺文件时悄悄通过，payload 缺 PECMD 要到
  镜像启动回退到 cmd 才被发现，这个坑 M5 已堵上。
- **注明来源**：PECMD.EXE 的来源记录见本文件（DSI 附带）与
  `Payload.ps1` 头注释；不再写进任何 Release 说明。

## 注入方式

- `Invoke-PayloadStep`（`Build-Micpe.ps1`）：从 `app/` 拼回三个包
  （只在对应开关开启时）→ 验哈希 → `Expand-Payload` 展开 payload →
  `Install-Payload` 把 `ProgramFiles/*` 拷到挂载点的 `Program Files/` →
  按开关调 `app/chrome/install.bat`（`7z x` 解 `chrome-slim.7z`，
  `Chrome-bin/` 拷到 `Program Files\Google\Chrome\Application`）、
  `app/office/install.bat`（`7z x` 解到 `Program Files\Office2016`）→
  `Assert-PayloadInstalled` 断言（含精简断言：Chrome 无 WidevineCdm、
  Locales 只有 en-US/zh-CN；Office 无 MSACCESS.EXE、无厂商脚本）→
  提交 → 体积门禁（boot.wim ≤ 3GB，见 `Wim.ps1`）。
- `install.bat` 只在 CI 里运行，绝不在 PE 启动后运行（用户 2026-11-17
  决定）。payload 步骤先把资产放到 .bat 所在文件夹旁，.bat 按约定
  只读自己文件夹里的文件。
- 探针期望（`src/ci/probe.cmd`，不改）：`payload=1` 要求
  `PENetwork.exe`、`7-zip\7z.exe`（小写路径）、`DiskGenius.exe`、
  `Win10_x64.xml` 四项齐备；`brand=1` 要求 OEMInformation 的
  Manufacturer 含 MICPE、SupportURL 含 B 站地址、oemlogo.bmp 存在。

## 降级顺序（体积超限时）

Office → Chrome → Photos → Media Player（`Stages.ps1` 的
`Get-DegradeOrder`）。`Invoke-Degrade` 目前只在测试里用，M7 体积治理
时再接线；M5 的步骤只做 `Assert-BootWimSize` 失败即停，不静默降级。

## 分卷方法（打包轮）

Chrome 与 Office 精简后重打，再按 95 MB 分卷提交进仓库。拼回验哈希
（必须与 `Payload.ps1` 里的 pin 一致）是提交前的硬步骤：

```bash
# Chrome：从 MSI 提取出的文件树上精简后重打
7z a -mx=9 chrome-slim.7z Chrome-bin
# Office：精简后的文件树上重打
7z a -mx=9 office2016-slim.7z Office2016
# 分卷（GitHub 单文件上限 100 MB；95M = 99,614,720 字节）
split -b 95M -d --numeric-suffixes=1 --suffix-length=3 chrome-slim.7z chrome-slim.7z.
split -b 95M -d --numeric-suffixes=1 --suffix-length=3 office2016-slim.7z office2016-slim.7z.
# 拼回验哈希再提交
cat chrome-slim.7z.001 chrome-slim.7z.002 | sha256sum
cat office2016-slim.7z.001 office2016-slim.7z.002 | sha256sum
```

分卷文件直接提交在 `app/chrome/`、`app/office/`（`.gitignore` 已放行）；
构建时 `Get-AppPackageArchive` 拼回、验哈希。旧的三个 Release
（`payload-v1` / `chrome-v1` / `office-v1`）已于分卷版验证通过后删除。

## 更新与替换方法

- **换新版 Chrome/Office**：把新安装包精简、重打、分卷，放进
  `app/chrome/` 或 `app/office/`，同 commit 更新 `Payload.ps1` 里的
  哈希与本文件里的版本号。旧版分卷直接覆盖（同名）。
- **payload 树有变**：改 `~/workspace/micpe-m5-material/` 里的
  对应文件，用 `New-PayloadArchive` 重打归档，验哈希，同 commit
  更新 `Payload.ps1` 里的 pin 与本文件。
- **PECMD.EXE 有变**：只接受 DSI 附带副本的更新；换文件后更新
  本文件与 `Payload.ps1` 里的 `$script:PecmdHash`，重打归档，
  同 commit 更新 payload 哈希。GhostCGI 的副本不作运行时。

## 未验证项（M5 明确不背书）

- 三个包的 `app/` 分卷拼回 + 哈希验 + 精简断言只在本地 Pester 里走过，
  没在真实 CI 构建里消费过（打包轮触发的 Build 会是第一次）。
- Chrome 的 `7z x` 解包落盘结构未经 Windows 核对；断言是递归找
  `chrome.exe`，不钉死子路径（旧 `msiexec /a` 路线已退役）。
- payload/brand 的 DISM 挂载、体积门禁、L3 QEMU 探针（`payload=1` /
  `brand=1`）均未在真实 install.wim/boot.wim 上跑过，留待底座映像
  就绪后一次补测（M7 或下一轮触发 Build 时）。
