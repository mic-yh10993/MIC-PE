# payload.md — 三个 payload 包的来源、哈希与发布方法（M5）

MICPE 的三个预装包各自一个 GitHub Release，构建时按开关下载、验
SHA256 才用。**三个 Release 尚未发布**——发布是一次性外发动作，
本轮只做代码与本地验证，不执行发布命令；发布步骤与哈希都已备好，
见下文“发布方法”。

## 包清单

| 包 | Release tag | 资产文件名 | 大小 | SHA256 |
| --- | --- | --- | --- | --- |
| payload | `payload-v1` | `micpe-payload.7z` | 28,564,811 B（解压后约 56 MB） | `c95737c250d34244a548d12c983f8c73aa479271d4889201429fac5c9960319e` |
| chrome | `chrome-v1` | `chrome-enterprise-x64.msi` | 164,831,232 B | `0ec77319d917eb232f1b1b52e0f6f6178eacb2d5abff1517f5c17d50a0a2db1a` |
| office | `office-v1` | `office2016-green.7z` | 170,364,185 B | `8bb9a924b72e5d70968121d1ed88df8bea74823e4f8aed1598d766b2a3cb7caf` |

哈希钉在 `src/build/lib/Payload.ps1` 的 `$script:PayloadHashes` 里，
下载时 `Get-PayloadReleaseAsset` 逐个验， mismatch 直接报错停下。
重发资产必须同 commit 更新 pin，绝不静默放宽。

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
  WiX Toolset 6.0.2.0，x64）。第三方专有安装包，原样分发。
- **office**：`PE预装软件/安装包/Office.7z`，Office 2016 绿色精简版，
  解压后约 474 MB，顶层目录 `Office2016/`，内含
  `Office16/WINWORD.EXE`、`EXCEL.EXE`、`POWERPNT.EXE`。
  第三方专有软件，原样分发。

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
- **注明来源**：payload-v1 的 Release 说明里写明来源（DSI 附带）与
  SHA256（见下文发布命令）；本文件即来源记录。

## 注入方式

- `Invoke-PayloadStep`（`Build-Micpe.ps1`）：下载三个资产（只在对应
  开关开启时）→ 验哈希 → `Expand-Payload` 展开 payload → `Install-Payload`
  把 `ProgramFiles/*` 拷到挂载点的 `Program Files/` → 按开关调
  `app/chrome/install.bat`（`msiexec /a` 解 MSI 到
  `Program Files\Google\Chrome`）、`app/office/install.bat`（`7z x`
  解到 `Program Files\Office2016`）→ `Assert-PayloadInstalled` 断言
  → 提交 → 体积门禁（boot.wim ≤ 3GB，见 `Wim.ps1`）。
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

## 发布方法（一次性，未执行）

发布前先确认 `gh` 已登录且有该仓库的写权限。归档文件已备好：
`~/workspace/micpe-m5-payload-build/micpe-payload.7z`（哈希见上表，
用 `New-PayloadArchive` 可复现）。按下面命令发布三个 Release：

```bash
MATERIAL="$HOME/workspace/micpe-m5-material"
cd /tmp
cp "$HOME/workspace/micpe-m5-payload-build/micpe-payload.7z" micpe-payload.7z
sha256sum micpe-payload.7z > payload.sha256
cp "$MATERIAL/PE预装软件/安装包/googlechromestandaloneenterprise64.msi" chrome-enterprise-x64.msi
cp "$MATERIAL/PE预装软件/安装包/Office.7z" office2016-green.7z
sha256sum chrome-enterprise-x64.msi > chrome.sha256
sha256sum office2016-green.7z > office.sha256

gh release create payload-v1 --repo mic-yh10993/MIC-PE --title "MICPE payload v1 (预装软件)" \
  --notes "第三方便携工具集，解压到 Program Files。CI 按此 release 名下载。PECMD.EXE 来源：DSI 附带（DSI-安装备份-源码/make/PECMD.EXE），SHA256 7a3710297473cbb865408d41db362e6014fd3eeaaf819751495e6d928e7adf5e；第三方免费软件，不入 git、不入 GPL 覆盖范围。" \
  micpe-payload.7z payload.sha256

gh release create chrome-v1 --repo mic-yh10993/MIC-PE --title "MICPE Chrome v1" \
  --notes "Google Chrome 企业版 MSI，仅装进 MICPE 自身。CI 按此 release 名下载。" \
  chrome-enterprise-x64.msi chrome.sha256

gh release create office-v1 --repo mic-yh10993/MIC-PE --title "MICPE Office 2016 v1" \
  --notes "Office 2016 绿色精简版（7z，解压 474 MB），仅装进 MICPE 自身。CI 按此 release 名下载。" \
  office2016-green.7z office.sha256
```

发布后逐个核对：`gh release download` 能拉到、哈希与上表一致、
`Payload.ps1` 里的 pin 不用改（已是发布文件的哈希）。若重打归档
导致哈希变化，必须同 commit 更新 `Payload.ps1` 里的 pin。

## 更新与替换方法

- **换新版 Chrome/Office**：把新安装包放进 `app/chrome/` 或
  `app/office/`（仅本地操作，不提交），用新文件重发对应 Release，
  同 commit 更新 `Payload.ps1` 里的哈希与本文件里的版本号。
- **payload 树有变**：改 `~/workspace/micpe-m5-material/` 里的
  对应文件，用 `New-PayloadArchive` 重打归档，验哈希，重发
  `payload-v1`（或发新 tag 并同步改 `Get-PayloadRelease`）。
- **PECMD.EXE 有变**：只接受 DSI 附带副本的更新；换文件后更新
  本文件与 `Payload.ps1` 里的 `$script:PecmdHash`，重打归档，
  同 commit 更新 payload 哈希。GhostCGI 的副本不作运行时。

## 未验证项（M5 明确不背书）

- 三个 Release 尚未发布：`Get-PayloadReleaseAsset` 的下载路径只在
  代码与测试里走过，没在真实 CI 里拉过资产。
- `msiexec /a` 解 Chrome MSI 的实际落盘子目录结构未经 Windows 核对；
  断言是递归找 `chrome.exe`，不钉死子路径。
- payload/brand 的 DISM 挂载、体积门禁、L3 QEMU 探针（`payload=1` /
  `brand=1`）均未在真实 install.wim/boot.wim 上跑过，留待底座映像
  就绪后一次补测（M7 或下一轮触发 Build 时）。
