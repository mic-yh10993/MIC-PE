# MICPE Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 GitHub Actions 免费 runner 上，从 UUP dump 的原版 Windows 11 25H2 镜像构建一个 ≤3 GB、带原生 Explorer 与 UWP、可一键装机的 `boot.wim`/ISO，命名为 MICPE。

**Architecture:** 以 ISO 的 `sources\boot.wim`（索引 1）为基底，按四批白名单从 `install.wim` 提取文件，整体替换 `SOFTWARE` 注册表 hive，再注入预装软件、品牌、启动脚本与 PECMD 装机工具，最后用 `oscdimg` 封成双启 ISO。成品 ISO 仅含 `boot.wim`（不带 `install.wim`，用户自己放；装机工具按 `install.mic` 协议从别的卷发现），构建出成品后自动上传 Release（tag `micpe-<stage>-<build>-<yyyymmdd>-r<run_number>`）。构建由单个 PowerShell 脚本 `Build-Micpe.ps1` 以 `-Stage m1..m7` 编排，每个阶段产物都可独立成 ISO 供人工验证。**启动索引必须在封 ISO 前显式设为 1**（`wimlib-imagex info --boot 1` 并读回断言）：UUP 原版介质的 `boot.wim` 默认启动索引是 2（Windows Setup），而全部定制与探针只在索引 1（Windows PE）里，不设则 winload 启动 Setup、探针永远跑不到（run 44062469206 诊断）。

**Tech Stack:** PowerShell 7（Pester 5 测试）、DISM、wimlib-imagex、oscdimg、7-Zip、UUP dump + uup-converter-wimlib、PECMD（WCS 脚本）、GitHub Actions（`windows-2025`）。

**Spec:** `docs/superpowers/specs/2026-11-15-micpe-design.md`

## Global Constraints

- 目标仓库：`mic-yh10993/MIC-PE`，分支 `main`，私有，不适用开源协议（不含微软二进制与第三方工具）。
- 源镜像：UUP dump，`Windows 11 26H2`，`amd64`，`zh-cn`，Pro 版；构建号由 workflow 输入 `build` 指定，默认 `26300`。
- 体积硬约束：`boot.wim` ≤ 3 GB，目标 ≤ 2.6 GB；ISO ≤ 3.2 GB。超限时按 Office → Chrome → Photos → Media Player 顺序降级。
- 单个 Release asset ≤ 2 GB；成品 ISO 约 1–1.5 GB，直接作为 Release 资产上传，不分卷。
- 仓库单文件 ≤ 100 MB，因此三个包直接提交在仓库 `app/` 文件夹里：`app/payload/micpe-payload.7z`（预装软件，28.5 MB，单文件）、`app/chrome/chrome-slim.7z.001/.002`（Chrome 精简版，拼回 125 MB）、`app/office/office2016-slim.7z.001/.002`（Office 精简版，拼回 167 MB）。Chrome 去语言包（只留 en-US、zh-CN）与 WidevineCdm，Office 去 Access 与厂商安装卸载脚本；构建时拼回、验 SHA256 再用。三者互不依赖，可单独更新。旧的三个独立 Release 资产（`payload-v1` / `chrome-v1` / `office-v1`）已于分卷版验证通过后删除，不再有第二条包来源。
- 只 zh-CN；只 amd64；不做 ARM64。
- 品牌固定值：`OEMInformation\Manufacturer` = `MICPE`，`Model` = `SYSTEM-Intel-MIC`，`SupportProvider` = `SYSTEM-Intel-MIC`，`SupportURL` = `https://space.bilibili.com/1978487514`，`Logo` = `%SystemRoot%\System32\oemlogo.bmp`；`CurrentVersion\RegisteredOwner` = `SYSTEM-Intel-MIC`，`RegisteredOrganization` = `MICPE`；计算机名 `MICPE-XXXX`。
- 自有程序与配置只放 `X:\Program Files\MICPE\`（`PENetwork`、`MICPE-Setup`、`说明.txt`、`logs`）；其余预装软件平铺在 `X:\Program Files\`，其中 7-Zip 目录名必须是 `7-zip`（`GhostCGI\cgi.ini` 硬编码 `%ProgramFiles%\7-ZIP\7z.exe`）。
- 预装软件只装进 MICPE 自身，绝不写入目标系统。
- 装机源发现协议：卷根 `install.mic`（首行=显示名）→ 该卷 `sources\install.wim`；无标记时降级匹配 `sources\install.wim`、`install.wim`、`*.esd`。
- 空盘不接管分区：提示用户点「分区」拉起 `X:\Program Files\DiskGenius.exe`，分完点「重新扫描」。
- 无人值守默认关闭；勾选后用 `X:\Program Files\WinNTSetup\unattend\Win10_x64.xml` 或 `Win7-11-Select.xml`，或用户自选 `*.xml`。
- 验证以 **CI 端到端自验证**为主（所有者明确要求不占人工时间）：L1 静态（Pester/语法/清单解析）、L2 结构（WIM 挂载/体积/注册表键/ISO 回读/BCD 解析）、L3 运行时（QEMU TCG 冷启动 + `vvfat` 回写 `E:\micpe-probe.txt` + monitor `screendump` 截图 + 非黑像素判定）。详见 spec §6.6。
- PE 内自检脚本 `src/ci/probe.wcs` 把结果按 `key=value` 写入 `E:\micpe-probe.txt`；CI 用 `tests/Assert-Probe.ps1` 断言期望值。人工只在出成品后做一次真机验证。

## Review Focus

1. 卷根有 `install.mic` 但 `sources\install.wim` 不存在或损坏 → 必须明确报"标记存在但映像缺失"，绝不静默跳到下一个卷或开始安装。
2. 目标分区可用空间小于映像解压后所需 → 必须在 `wimlib apply` **之前**拒绝并给出具体数字，不允许 apply 到一半失败留下半装状态。
3. 映像含多个索引（如"专业版/专业版 N/家庭版"）→ 必须列出版本让用户选，默认选中与 `install.mic` 首行名称匹配的那个，匹配不到则默认第一个。
4. 选中的目标分区正好是 MICPE 启动盘或装机源所在分区 → 必须拒绝，否则边读边格式化会毁掉镜像。
5. 卷离线/无盘符/BitLocker 加密/Ventoy 虚拟盘 → 分配盘符失败的卷要跳过并继续扫描其余卷，不能整体扫描失败。

---

## File Structure

| 文件 | 职责 |
|---|---|
| `.github/workflows/build.yml` | 主构建：参数输入、缓存、调用 `Build-Micpe.ps1`、分卷发布 |
| `.github/workflows/test.yml` | 每次 push/PR 跑 Pester 与语法检查 |
| `README.md` | 用法、`install.mic` 协议、内存要求、许可与来源声明 |
| `docs/design.md` | 设计文档副本（从 spec 拷入） |
| `docs/test-checklist.md` | 真机一次性确认表（CI 已覆盖的项标注"CI 已验"） |
| `scripts/Test-Syntax.ps1` | 本地/CI 通用的 PowerShell 语法解析检查 |
| `scripts/Invoke-Tests.ps1` | 跑 Pester |
| `src/build/Build-Micpe.ps1` | 阶段编排总入口 |
| `src/build/lib/Common.ps1` | 日志、断言、路径 |
| `src/build/lib/Disk.ps1` | 清理 runner、选最大空闲盘 |
| `src/build/lib/BaseImage.ps1` | UUP → ISO → 拆出 wim |
| `src/build/lib/Wim.ps1` | 挂载/卸载、白名单提取、体积断言 |
| `src/build/lib/Registry.ps1` | hive 挂载/卸载、导入 `.reg` |
| `src/build/lib/Payload.ps1` | 预装软件、快捷方式 |
| `src/build/lib/Brand.ps1` | 壁纸、oemlogo、OEM 注册表 |
| `src/build/lib/Iso.ps1` | `oscdimg` 封装与校验 |
| `src/filelists/10-cmdpe.txt` … `40-components.txt` | 白名单（每行一个 `install.wim` 内相对路径，支持 `*`） |
| `src/registry/10-pe-base.reg` … `40-brand.reg` | 注册表补丁 |
| `src/shell/startnet.cmd` | PE 启动入口（替代 winpeshl.ini） |
| `src/shell/PECMD.INI` | PECMD 装配：探盘、起 shell、起装机工具 |
| `src/shell/Pin-Shortcuts.wcs` | 桌面/开始菜单快捷方式 |
| `src/installer/MICPE-Setup.wcs` | 装机工具主界面与流程 |
| `src/installer/MICPE-Setup.ini` | 装机工具配置（日志路径、默认勾选项） |
| `src/installer/lang/zh-CN.txt` | 界面文案 |
| `src/ci/probe.wcs` | PE 内自检脚本，结果写入 `E:\micpe-probe.txt` |
| `src/ci/Assert-Probe.ps1` | CI 侧 probe 结果断言（按阶段声明期望） |
| `src/ci/Invoke-QemuVerify.ps1` | 组装 vvfat 盘、启动 QEMU、抓截图、收 probe、超时管理 |
| `tests/Common.Tests.ps1` 等 | Pester 测试，与被测脚本同名 |

---

### Task 1: 仓库骨架与语法门禁

**Files:**
- Create: `LICENSE`, `README.md`, `.gitignore`, `scripts/Test-Syntax.ps1`, `.github/workflows/test.yml`, `docs/design.md`
- Test: `tests/Repo.Tests.ps1`

**Interfaces:**
- Produces: `Test-Syntax.ps1` 接受 `-Path <string[]>`，对每个 `.ps1` 调 `[System.Management.Automation.Language.Parser]::ParseFile`，有错误时 `Write-Error` 并 `exit 1`，否则 `exit 0`。后续每个 Task 的"语法检查"步骤都调它。

- [ ] **Step 1: 写失败测试**

```powershell
# tests/Repo.Tests.ps1
Describe 'repository skeleton' {
    It 'has GPL-3.0 license text' {
        (Get-Content "$PSScriptRoot/../LICENSE" -Raw) | Should -Match 'GNU GENERAL PUBLIC LICENSE'
        (Get-Content "$PSScriptRoot/../LICENSE" -Raw) | Should -Match 'Version 3, 29 June 2007'
    }
    It 'README states the MICPE memory requirement' {
        (Get-Content "$PSScriptRoot/../README.md" -Raw) | Should -Match '4 GB'
    }
    It 'design doc is present' {
        Test-Path "$PSScriptRoot/../docs/design.md" | Should -BeTrue
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `pwsh -NoProfile -File scripts/Invoke-Tests.ps1 -Path tests/Repo.Tests.ps1`
Expected: FAIL — `LICENSE` 不存在

- [ ] **Step 3: 实现**

`LICENSE`：从 `https://www.gnu.org/licenses/gpl-3.0.txt` 下载全文（`Invoke-WebRequest`），不做修改。
`README.md` 必含小节：项目简介、系统要求（**至少 4 GB 内存**，因为 `boot.wim` 全量进 RAM 盘）、构建方式、`install.mic` 协议说明、许可与第三方来源声明。
`scripts/Test-Syntax.ps1` 与 `scripts/Invoke-Tests.ps1`（后者 `Import-Module Pester; Invoke-Pester -Path $Path -Output Detailed`）。
`.github/workflows/test.yml`：`runs-on: windows-2025`，`actions/checkout@v4`，跑 `scripts/Test-Syntax.ps1` + `scripts/Invoke-Tests.ps1`。

- [ ] **Step 4: 运行测试确认通过**

Run: `pwsh -NoProfile -File scripts/Invoke-Tests.ps1 -Path tests/Repo.Tests.ps1`
Expected: PASS 3 tests

- [ ] **Step 5: 提交**

```bash
git add LICENSE README.md .gitignore scripts .github docs
git commit -m "chore: repository skeleton with GPL-3.0 and test gate"
```

---

### Task 2: Common.ps1（日志与断言）

**Files:**
- Create: `src/build/lib/Common.ps1`
- Test: `tests/Common.Tests.ps1`

**Interfaces:**
- Produces:
  - `Write-Step([string] $Message)` — 输出 `==> $Message`
  - `Write-SubStep([string] $Message)` — 输出缩进 `    - $Message`
  - `Assert-True([bool] $Condition, [string] $Message)` — 为假抛 `InvalidOperationException`
  - `Assert-FileSize([string] $Path, [long] $MaxBytes, [string] $Label)` — 超限抛出并带上 GB 数字（`'{0:N2} GB' -f ($actual/1GB)`）
  - `Assert-PathExists([string] $Path)` — 不存在抛错
  - `Get-MicpeTempDir([string] $Root)` — 返回 `$Root\micpe-tmp`，不存在则创建

- [ ] **Step 1: 写失败测试**

```powershell
# tests/Common.Tests.ps1
BeforeAll { . "$PSScriptRoot/../src/build/lib/Common.ps1" }

Describe 'Assert-FileSize' {
    It 'passes when under limit' {
        $f = New-TemporaryFile; Set-Content $f 'abc'
        { Assert-FileSize -Path $f -MaxBytes 10 -Label 'wim' } | Should -Not -Throw
    }
    It 'throws with GB figure when over limit' {
        $f = New-TemporaryFile; [IO.File]::WriteAllBytes($f, (New-Object byte[] 2048))
        { Assert-FileSize -Path $f -MaxBytes 1024 -Label 'boot.wim' } |
            Should -Throw '*boot.wim*'
    }
}
Describe 'Assert-True' {
    It 'throws on false' { { Assert-True -Condition $false -Message 'x' } | Should -Throw '*x*' }
    It 'silent on true'  { { Assert-True -Condition $true  -Message 'x' } | Should -Not -Throw }
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `pwsh -NoProfile -File scripts/Invoke-Tests.ps1 -Path tests/Common.Tests.ps1`
Expected: FAIL — `Assert-FileSize` 未定义

- [ ] **Step 3: 实现 `src/build/lib/Common.ps1`**

按上面 Interfaces 的签名实现。所有函数用 `[CmdletBinding()]` 与显式类型参数。日志一律 `Write-Host`（不走 `Write-Verbose`，因为 CI 日志需要可见）。`Assert-*` 系列在消息里附上期望值与实际值。

- [ ] **Step 4: 运行测试确认通过**

Run: `pwsh -NoProfile -File scripts/Invoke-Tests.ps1 -Path tests/Common.Tests.ps1`
Expected: PASS 4 tests

- [ ] **Step 5: 提交**

```bash
git add src/build/lib/Common.ps1 tests/Common.Tests.ps1
git commit -m "feat(build): logging and assertion helpers"
```

---

### Task 3: Disk.ps1（runner 清理与选盘）

**Files:**
- Create: `src/build/lib/Disk.ps1`
- Test: `tests/Disk.Tests.ps1`

**Interfaces:**
- Consumes: `Write-Step`, `Assert-True`（Task 2）
- Produces:
  - `Remove-RunnerBloat([string[]] $Paths)` — 逐项 `Remove-Item -Recurse -Force -ErrorAction SilentlyContinue`，返回实际删掉的项数
  - `Get-BuildDrive([object[]] $Drives)` — 纯函数：输入带 `Root`/`Free` 属性的对象数组，返回 `Free` 最大的那个；空数组时抛错
  - `Get-BuildWorkspace([object[]] $Drives)` — 返回 `"{root}micpe"`，目录不存在则创建

- [ ] **Step 1: 写失败测试**

```powershell
# tests/Disk.Tests.ps1
BeforeAll { . "$PSScriptRoot/../src/build/lib/Common.ps1"; . "$PSScriptRoot/../src/build/lib/Disk.ps1" }

Describe 'Get-BuildDrive' {
    It 'picks the drive with most free space' {
        $d = @(
            [pscustomobject]@{ Root='C:\'; Free=5GB },
            [pscustomobject]@{ Root='D:\'; Free=40GB },
            [pscustomobject]@{ Root='E:\'; Free=12GB }
        )
        (Get-BuildDrive -Drives $d).Root | Should -Be 'D:\'
    }
    It 'throws when no drives' {
        { Get-BuildDrive -Drives @() } | Should -Throw
    }
}
Describe 'Remove-RunnerBloat' {
    It 'counts only paths that existed' {
        $tmp = New-Item -ItemType Directory -Path (Join-Path $env:TEMP "bloat$(Get-Random)")
        Remove-RunnerBloat -Paths @($tmp.FullName, 'C:\definitely-not-here-xyz') | Should -Be 1
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `pwsh -NoProfile -File scripts/Invoke-Tests.ps1 -Path tests/Disk.Tests.ps1`
Expected: FAIL — `Get-BuildDrive` 未定义

- [ ] **Step 3: 实现 `src/build/lib/Disk.ps1`**

`Remove-RunnerBloat` 用计数器累加 `Test-Path` 为真的项。`Get-BuildDrive` 用 `Sort-Object Free -Descending | Select-Object -First 1`。默认清理清单常量 `$script:RunnerBloatPaths` = `C:\Android`, `C:\SeleniumWebDrivers`, `C:\R`, `C:\Program Files\MongoDB`, `C:\Program Files\PostgreSQL`, `$env:LOCALAPPDATA\pip\cache`, `$env:LOCALAPPDATA\NuGet`。

- [ ] **Step 4: 运行测试确认通过**

Run: `pwsh -NoProfile -File scripts/Invoke-Tests.ps1 -Path tests/Disk.Tests.ps1`
Expected: PASS 3 tests

- [ ] **Step 5: 提交**

```bash
git add src/build/lib/Disk.ps1 tests/Disk.Tests.ps1
git commit -m "feat(build): runner cleanup and build drive selection"
```

---

### Task 4: Wim.ps1（挂载、白名单提取、体积断言）

**Files:**
- Create: `src/build/lib/Wim.ps1`
- Test: `tests/Wim.Tests.ps1`

**Interfaces:**
- Consumes: Task 2 的 `Assert-True`/`Assert-FileSize`/`Assert-PathExists`
- Produces:
  - `ConvertTo-WimPathPattern([string] $Line)` — 去掉行首 `\`、行尾空白、`#` 注释行返回 `$null`，反斜杠统一为 `\`，返回可用于 `wimlib-imagex extract` 的模式串
  - `Read-Whitelist([string] $Path)` — 读文件，逐行 `ConvertTo-WimPathPattern`，过滤 `$null`，去重，保持顺序，返回 `string[]`
  - `Mount-WimImage([string] $WimPath, [int] $Index, [string] $MountDir)` — `dism /Mount-Image /ReadOnly` 不用；用读写挂载
  - `Dismount-WimImage([string] $MountDir, [switch] $Commit)`
  - `Export-WimFiles([string] $WimPath, [int] $Index, [string] $Destination, [string[]] $Patterns)` — 用 `wimlib-imagex extract`，`--no-acls` 不开、保留属性；每 50 个模式一批调用以减少进程启动
  - `Assert-BootWimSize([string] $WimPath)` — 调 `Assert-FileSize -MaxBytes 3GB -Label 'boot.wim'`

- [ ] **Step 1: 写失败测试**

```powershell
# tests/Wim.Tests.ps1
BeforeAll { . "$PSScriptRoot/../src/build/lib/Common.ps1"; . "$PSScriptRoot/../src/build/lib/Wim.ps1" }

Describe 'ConvertTo-WimPathPattern' {
    It 'strips leading backslash' { ConvertTo-WimPathPattern '\Windows\explorer.exe' | Should -Be 'Windows\explorer.exe' }
    It 'ignores comment and blank lines' {
        ConvertTo-WimPathPattern '; comment' | Should -BeNullOrEmpty
        ConvertTo-WimPathPattern '' | Should -BeNullOrEmpty
        ConvertTo-WimPathPattern '   ' | Should -BeNullOrEmpty
    }
    It 'keeps wildcards' { ConvertTo-WimPathPattern '\Windows\WinSxS\x86_*\*.*' | Should -Be 'Windows\WinSxS\x86_*\*.*' }
    It 'trims trailing whitespace' { ConvertTo-WimPathPattern '\Windows\a.dll  ' | Should -Be 'Windows\a.dll' }
}

Describe 'Read-Whitelist' {
    It 'dedupes while keeping order' {
        $f = New-TemporaryFile
        Set-Content $f "`\Windows\a.dll`n`\Windows\b.dll`n`\Windows\a.dll`n;c`n"
        Read-Whitelist -Path $f | Should -Be @('Windows\a.dll','Windows\b.dll')
    }
}

Describe 'Assert-BootWimSize' {
    It 'rejects a file over 3 GB' {
        $f = New-TemporaryFile
        $fs = [IO.File]::OpenWrite($f); $fs.SetLength(3GB + 1); $fs.Close()
        { Assert-BootWimSize -WimPath $f } | Should -Throw
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `pwsh -NoProfile -File scripts/Invoke-Tests.ps1 -Path tests/Wim.Tests.ps1`
Expected: FAIL — `ConvertTo-WimPathPattern` 未定义

- [ ] **Step 3: 实现 `src/build/lib/Wim.ps1`**

`Export-WimFiles` 内部构造 `wimlib-imagex extract <wim> <index> @patterns --dest-dir=<dst>`；每批失败时用 `Assert-True ($LASTEXITCODE -eq 0)` 报出失败批次的前 3 个模式。`Mount-WimImage` 先 `Assert-PathExists`，再 `dism.exe /English /Mount-Image`，`$LASTEXITCODE -eq 0` 断言。

- [ ] **Step 4: 运行测试确认通过**

Run: `pwsh -NoProfile -File scripts/Invoke-Tests.ps1 -Path tests/Wim.Tests.ps1`
Expected: PASS 6 tests

- [ ] **Step 5: 提交**

```bash
git add src/build/lib/Wim.ps1 tests/Wim.Tests.ps1
git commit -m "feat(build): whitelist parsing, wim mount, size assertion"
```

---

### Task 5: 四批白名单文件

**Files:**
- Create: `src/filelists/10-cmdpe.txt`（77 条）、`20-explorer.txt`（144 条）、`30-runtimes.txt`（305 条）、`40-components.txt`（175 条）
- Test: `tests/Filelists.Tests.ps1`

**Interfaces:**
- Consumes: `Read-Whitelist`（Task 4）
- Produces: 四个清单文件，供 Task 10–12 的 `Export-WimFiles` 直接消费。

- [ ] **Step 1: 写失败测试**

```powershell
# tests/Filelists.Tests.ps1
BeforeAll {
    . "$PSScriptRoot/../src/build/lib/Common.ps1"
    . "$PSScriptRoot/../src/build/lib/Wim.ps1"
}
Describe 'whitelists' {
    It '<_>.txt exists and parses' -ForEach @('10-cmdpe','20-explorer','30-runtimes','40-components') {
        $p = "$PSScriptRoot/../src/filelists/$_.txt"
        Test-Path $p | Should -BeTrue
        (Read-Whitelist -Path $p).Count | Should -BeGreaterThan 10
    }
    It 'every entry is a Windows path without drive letter' {
        Read-Whitelist -Path "$PSScriptRoot/../src/filelists/20-explorer.txt" |
            Where-Object { $_ -match '^[A-Za-z]:' -or $_ -notmatch '^[A-Za-z0-9_\. ]+\\' } |
            Should -BeNullOrEmpty
    }
    It 'cmdpe list does not contain the .wim base image itself' {
        Read-Whitelist -Path "$PSScriptRoot/../src/filelists/10-cmdpe.txt" |
            Where-Object { $_ -like '*Recovery\Winre.wim' } | Should -BeNullOrEmpty
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `pwsh -NoProfile -File scripts/Invoke-Tests.ps1 -Path tests/Filelists.Tests.ps1`
Expected: FAIL — 文件不存在

- [ ] **Step 3: 生成清单**

从教程 `/root/micpe-ref/参考文献(可只阅读精简txt）/5/uwppe教程.txt` 四节（行 35–556 CmdPE、556–790 Explorer、790–1148 运行库、1148–结尾 组件）提取所有以 `\` 开头的行，去重保序写入对应文件。生成脚本一次性使用，不入仓库：

```powershell
$lines = Get-Content $tutorial
$secs = @{ '10-cmdpe'=@(35,556); '20-explorer'=@(556,790); '30-runtimes'=@(790,1148); '40-components'=@(1148,$lines.Count) }
foreach ($k in $secs.Keys) {
    $a,$b = $secs[$k]
    $lines[($a-1)..($b-1)] | Where-Object { $_.Trim().StartsWith('\') } |
        ForEach-Object { $_.Trim().Substring(1) } |
        Select-Object -Unique | Set-Content "src/filelists/$k.txt"
}
```

生成后手工删除 `Windows\System32\Recovery\Winre.wim`（基底不是 winre，不需要它，且会白白多加 400 MB）。

- [ ] **Step 4: 运行测试确认通过**

Run: `pwsh -NoProfile -File scripts/Invoke-Tests.ps1 -Path tests/Filelists.Tests.ps1`
Expected: PASS 6 tests（4 个文件 × 存在 + 2 条规则）

- [ ] **Step 5: 提交**

```bash
git add src/filelists tests/Filelists.Tests.ps1
git commit -m "feat(build): four-batch install.wim whitelists from tutorial"
```

---

### Task 6: Registry.ps1（hive 挂载与导入）

**Files:**
- Create: `src/build/lib/Registry.ps1`
- Test: `tests/Registry.Tests.ps1`

**Interfaces:**
- Consumes: Task 2 断言
- Produces:
  - `Mount-RegistryHive([string] $HiveFile, [string] $KeyName)` — `reg.exe load "HKLM\$KeyName" $HiveFile`，断言退出码 0，已挂载则先卸载
  - `Dismount-RegistryHive([string] $KeyName)` — `reg.exe unload`，未挂载时静默
  - `Import-RegFile([string] $RegFile)` — `reg.exe import`，断言 0
  - `Invoke-RegistryScript([string] $MountDir, [string[]] $RegFiles)` — 依次挂载 `DEFAULT`/`DRIVERS`/`SOFTWARE`/`SYSTEM` 为 `PE-DEF`/`PE-DRV`/`PE-SOFT`/`PE-SYS`，导入全部 `.reg`，最后全部卸载；用 `try/finally` 保证异常时也卸载
  - `Get-RegistryValue([string] $KeyName, [string] $SubKey, [string] $Name)` — 读值用于断言

- [ ] **Step 1: 写失败测试**

```powershell
# tests/Registry.Tests.ps1
BeforeAll {
    . "$PSScriptRoot/../src/build/lib/Common.ps1"
    . "$PSScriptRoot/../src/build/lib/Registry.ps1"
}
Describe 'hive mount round trip' {
    It 'loads, reads, unloads' {
        $hive = Join-Path $env:TEMP "t$(Get-Random).hiv"
        Copy-Item "$env:SystemRoot\System32\config\DEFAULT" $hive
        Mount-RegistryHive -HiveFile $hive -KeyName 'MICPE-TEST'
        { Get-RegistryValue -KeyName 'MICPE-TEST' -SubKey '' -Name '' } | Should -Not -Throw
        Dismount-RegistryHive -KeyName 'MICPE-TEST'
        (reg query 'HKLM\MICPE-TEST' 2>$null; $LASTEXITCODE) | Should -Not -Be 0
    }
}
Describe 'Import-RegFile' {
    It 'applies a value' {
        $reg = Join-Path $env:TEMP "t$(Get-Random).reg"
        @"
Windows Registry Editor Version 5.00

[HKEY_CURRENT_USER\Software\MICPE-Test]
"Value"="Hello"
"@ | Set-Content $reg -Encoding Unicode
        Import-RegFile -RegFile $reg
        (Get-ItemProperty 'HKCU:\Software\MICPE-Test').Value | Should -Be 'Hello'
        Remove-Item 'HKCU:\Software\MICPE-Test' -Recurse -Force
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `pwsh -NoProfile -File scripts/Invoke-Tests.ps1 -Path tests/Registry.Tests.ps1`
Expected: FAIL — `Mount-RegistryHive` 未定义

- [ ] **Step 3: 实现 `src/build/lib/Registry.ps1`**

`Invoke-RegistryScript` 的挂载映射写成常量：

```powershell
$script:HiveMap = @(
    @{ File='DEFAULT';  Key='PE-DEF'  },
    @{ File='DRIVERS';  Key='PE-DRV'  },
    @{ File='SOFTWARE'; Key='PE-SOFT' },
    @{ File='SYSTEM';   Key='PE-SYS'  }
)
```

`.reg` 文件需是 UTF-16LE（`reg import` 对 UTF-8 也接受，但带中文值时必须 UTF-16LE）。断言：挂载后 `HKLM:\PE-SOFT\Microsoft\Windows\CurrentVersion` 存在。

- [ ] **Step 4: 运行测试确认通过**

Run: `pwsh -NoProfile -File scripts/Invoke-Tests.ps1 -Path tests/Registry.Tests.ps1`
Expected: PASS 2 tests

- [ ] **Step 5: 提交**

```bash
git add src/build/lib/Registry.ps1 tests/Registry.Tests.ps1
git commit -m "feat(build): registry hive mount and import helpers"
```

---

### Task 7: BaseImage.ps1（UUP → ISO → 拆 wim）

**Files:**
- Create: `src/build/lib/BaseImage.ps1`
- Test: `tests/BaseImage.Tests.ps1`

**Interfaces:**
- Consumes: Task 2/3 断言与工作区
- Produces:
  - `Get-UupBuild([string] $Build, [string] $Arch, [string] $Channel)` — 调 `https://api.uupdump.net/listid.php?search=<build>`，返回 `@{ Uuid; Build; Title }`；无匹配抛错并附上请求 URL
  - `New-UupDownloadPackage([string] $Uuid, [string] $OutDir, [string] $Lang)` — 调 `https://api.uupdump.net/get.php?id=<uuid>&lang=<lang>` 取 zip 并展开
  - `Set-ConvertConfig([string] $IniPath, [hashtable] $Overrides)` — 纯函数：改 `ConvertConfig.ini` 的键值，保留注释与顺序，返回改后的全文
  - `Get-BaseWims([string] $IsoPath, [string] $OutDir)` — 用 `7z` 解出 `sources\install.wim` 与 `sources\boot.wim`，返回两者路径

- [ ] **Step 1: 写失败测试**

```powershell
# tests/BaseImage.Tests.ps1
BeforeAll {
    . "$PSScriptRoot/../src/build/lib/Common.ps1"
    . "$PSScriptRoot/../src/build/lib/BaseImage.ps1"
}
Describe 'Set-ConvertConfig' {
    It 'replaces existing keys and preserves comments' {
        $f = New-TemporaryFile
        @"
; this is a comment
[Convert]
Edition=Professional
ResetBase=1
"@ | Set-Content $f
        $out = Set-ConvertConfig -IniPath $f -Overrides @{ Edition='Professional'; ResetBase='0'; SkipEdge='1' }
        $out | Should -Match '^; this is a comment'
        $out | Should -Match 'ResetBase=0'
        $out | Should -Match 'SkipEdge=1'
        ($out -split "`n" | Where-Object { $_ -match '^Edition=' }) | Should -Be 'Edition=Professional'
    }
}
Describe 'Get-UupBuild' {
    It 'throws a message containing the request url when nothing matches' {
        { Get-UupBuild -Build '1' -Arch 'amd64' -Channel 'stable' -ApiBase 'https://api.uupdump.net' -Invoke { @{ response = @{ builds = @{} } } } } |
            Should -Throw '*uupdump*'
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `pwsh -NoProfile -File scripts/Invoke-Tests.ps1 -Path tests/BaseImage.Tests.ps1`
Expected: FAIL — `Set-ConvertConfig` 未定义

- [ ] **Step 3: 实现 `src/build/lib/BaseImage.ps1`**

`Get-UupBuild` 接受 `-ApiBase` 与可选 `-Invoke` 脚本块（默认 `Invoke-RestMethod`），这样测试可注入。筛选规则：`arch -eq $Arch` 且 title 含 `Windows 11` 且 `$Channel -eq 'stable'` 时 title 不含 `Insider`。`Set-ConvertConfig` 逐行处理，键名比较用 `-replace '\s',''` 后的 `^key=`。

`New-UupDownloadPackage` 落盘后目录里必须有 `uup_download_windows.cmd`，否则抛错（UUP 返回错误页时会缺这个文件）。

- [ ] **Step 4: 运行测试确认通过**

Run: `pwsh -NoProfile -File scripts/Invoke-Tests.ps1 -Path tests/BaseImage.Tests.ps1`
Expected: PASS 2 tests

- [ ] **Step 5: 提交**

```bash
git add src/build/lib/BaseImage.ps1 tests/BaseImage.Tests.ps1
git commit -m "feat(build): uup dump resolution, config rewrite, wim extraction"
```

---

### Task 8: M1 — 阶段编排 + 空 PE ISO

**Files:**
- Create: `src/build/Build-Micpe.ps1`, `src/build/lib/Stages.ps1`, `src/build/lib/Iso.ps1`, `src/shell/startnet.cmd`, `.github/workflows/build.yml`
- Test: `tests/Ordering.Tests.ps1`

**Interfaces:**
- Consumes: Task 2–7 全部
- Produces:
  - `Get-StageSteps([string] $Stage)`（在 `Stages.ps1`，纯函数）— 返回该阶段要跑的步骤名数组；`all` 返回全部步骤
  - `$script:AllSteps` 与 `$script:StageSteps` 常量（同文件）
  - `Build-Micpe.ps1` 参数：`-Stage <m1..m7|all>`、`-Build <string>`、`-Workspace <string>`、`-Output <string>`、`-Office <switch>`、`-Chrome <switch>`
  - `New-MicpeIso([string] $MediaDir, [string] $OutIso)`（在 `Iso.ps1`）

- [ ] **Step 1: 写失败测试**

```powershell
# tests/Ordering.Tests.ps1
BeforeAll { . "$PSScriptRoot/../src/build/lib/Stages.ps1" }

Describe 'Get-StageSteps' {
    It 'm1 contains only base steps in order' {
        Get-StageSteps -Stage 'm1' | Should -Be @('base','reseed','iso')
    }
    It 'm4 includes shell, runtimes, components and uwp without duplicates' {
        $s = Get-StageSteps -Stage 'm4'
        $s | Should -Be @('base','reseed','explorer','runtimes','components','uwp','iso')
        ($s | Select-Object -Unique).Count | Should -Be $s.Count
    }
    It 'all ends with iso' {
        (Get-StageSteps -Stage 'all')[-1] | Should -Be 'iso'
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `pwsh -NoProfile -File scripts/Invoke-Tests.ps1 -Path tests/Ordering.Tests.ps1`
Expected: FAIL — `Get-StageSteps` 未定义

- [ ] **Step 3: 实现**

`Build-Micpe.ps1` 用 `param()` + `switch ($Stage)` 映射到步骤数组，步骤名常量：

```powershell
$script:AllSteps = @('base','reseed','explorer','runtimes','components','uwp','payload','brand','iso')
$script:StageSteps = @{
    m1 = @('base','reseed','iso')
    m2 = @('base','reseed','explorer','iso')
    m3 = @('base','reseed','explorer','runtimes','components','iso')
    m4 = @('base','reseed','explorer','runtimes','components','uwp','iso')
    m5 = @('base','reseed','explorer','runtimes','components','uwp','payload','brand','iso')
    m6 = @('base','reseed','explorer','runtimes','components','uwp','payload','brand','iso')
    m7 = $script:AllSteps
}
```

`m6` 与 `m5` 步骤相同：装机工具本身是 payload 里的文件，没有独立的构建步骤，`m6` 只是标明"这一期验证装机流程"。

`startnet.cmd`（M1 只需拉起 cmd）：

```cmd
@echo off
wpeinit
echo MICPE M1 base image OK
cmd.exe
```

`-WhatIfOnly` 不再需要：步骤表搬到 `Stages.ps1`，测试直接点源该文件，`Build-Micpe.ps1` 只负责执行。

`Iso.ps1` 的 `New-MicpeIso` 调 `oscdimg -m -o -u2 -udfver102 -bootdata:2#p0,e,b<etfsboot>#pEF,e,b<efisys> <media> <out>`，`etfsboot.com` 与 `efisys.bin` 从 `media\boot` 与 `media\efi\microsoft\boot` 取；断言输出 ISO 存在且 ≤ 3.2 GB。

`.github/workflows/build.yml`：`workflow_dispatch` 输入 `stage`（choice m1..m7/all）、`build`（默认 `26200`）、`office`/`chrome`（boolean，默认 false）；`runs-on: windows-2025`；`timeout-minutes: 360`；步骤为 checkout → 清理磁盘 → `Build-Micpe.ps1` → 体积报告写入 `$GITHUB_STEP_SUMMARY` → `actions/upload-artifact@v4`。

- [ ] **Step 4: 运行本地验证**

Run: `pwsh -NoProfile -File scripts/Invoke-Tests.ps1 -Path tests/Ordering.Tests.ps1`
Expected: PASS 3 tests

Run: `pwsh -NoProfile -File scripts/Test-Syntax.ps1 -Path src/build/Build-Micpe.ps1,src/build/lib/Iso.ps1`
Expected: 无错误输出，exit 0

- [ ] **Step 5: 提交并在 CI 验证 M1**

```bash
git add src/build/Build-Micpe.ps1 src/build/lib/Stages.ps1 src/build/lib/Iso.ps1 src/shell/startnet.cmd .github/workflows/build.yml tests/Ordering.Tests.ps1
git commit -m "feat(build): stage orchestration and M1 base PE ISO"
git push
gh workflow run build.yml -f stage=m1 -f build=26200
```

Expected: workflow 成功，artifact `micpe-m1-<build>` 内含 `MICPE.iso`，`$GITHUB_STEP_SUMMARY` 显示 `boot.wim` 与 ISO 体积。

- [ ] **Step 6: 提交前确认构建产物**（运行时验证在 Task 9 建立，之后所有阶段的 M1..M7 验收都走 CI）

本步骤不要求人工启动虚拟机；`MICPE.iso` 与 `boot.wim` 作为 artifact 留存。Task 9 完成后，M1 的运行时验收由 CI 自动完成。

---

### Task 9: CI 端到端自验证（QEMU + vvfat 回写 + 截图）

**Files:**
- Create: `src/ci/probe.wcs`, `src/ci/Assert-Probe.ps1`, `src/ci/Invoke-QemuVerify.ps1`, `.github/workflows/verify-smoke.yml`
- Modify: `.github/workflows/build.yml`（加 verify 输入与步骤）, `src/shell/PECMD.INI`
- Test: `tests/ProbeAssert.Tests.ps1`, `tests/QemuArgs.Tests.ps1`

**Interfaces:**
- Consumes: Task 8 的 ISO 产物
- Produces:
  - `Read-ProbeFile([string] $Path)` — 解析 `key=value` 行，返回 `hashtable`；忽略空行与 `#` 注释；重复键后者覆盖
  - `Assert-ProbeResult([hashtable] $Probe, [hashtable] $Expected)` — 对 `$Expected` 每项断言 `$Probe[$key]` 相等或（值为 `'*'` 时）存在且非空；返回缺失/不匹配项数组，为空表示通过
  - `Get-QemuArgs([hashtable] $Options)` — 纯函数，返回 `string[]`；必须包含 `-drive file=fat:rw:<share>,format=raw,media=disk,if=ide`、`-monitor tcp:127.0.0.1:4444,server,nowait`、`-m 4096`、`-smp 4`、`-display none`、`-no-reboot`
  - `Invoke-QemuVerify` — 参数 `-Iso <path> -ShareDir <path> -TimeoutMin <int> -ScreenshotDir <path> -LogPath <path>`；启动 QEMU、轮询 `probe.txt`、超时则截图并抛错

- [ ] **Step 1: 写失败测试**

```powershell
# tests/ProbeAssert.Tests.ps1
BeforeAll { . "$PSScriptRoot/../src/ci/Assert-Probe.ps1" }

Describe 'Read-ProbeFile' {
    It 'parses key=value and ignores comments and blanks' {
        $f = New-TemporaryFile
        Set-Content $f "# header`nboot=1`n`nexplorer=1`nime=1`n"
        $p = Read-ProbeFile -Path $f
        $p.Keys.Count | Should -Be 3
        $p['explorer'] | Should -Be '1'
    }
    It 'lets the last duplicate win' {
        $f = New-TemporaryFile
        Set-Content $f "uwp_launch=0`nuwp_launch=1`n"
        (Read-ProbeFile -Path $f)['uwp_launch'] | Should -Be '1'
    }
}

Describe 'Assert-ProbeResult' {
    It 'returns every failing key with expected and actual' {
        $probe = @{ explorer='1'; ime='0'; dwm='' }
        $bad = Assert-ProbeResult -Probe $probe -Expected @{ explorer='1'; ime='1'; dwm='*'; network='*' }
        $bad.Count | Should -Be 3
        ($bad -join "`n") | Should -Match 'ime'
        ($bad -join "`n") | Should -Match 'dwm'
        ($bad -join "`n") | Should -Match 'network'
    }
    It 'passes when everything matches' {
        (Assert-ProbeResult -Probe @{ a='1'; b='x' } -Expected @{ a='1'; b='*' }).Count | Should -Be 0
    }
}
```

```powershell
# tests/QemuArgs.Tests.ps1
BeforeAll { . "$PSScriptRoot/../src/ci/Invoke-QemuVerify.ps1" -ParseOnly }

Describe 'Get-QemuArgs' {
    BeforeAll {
        $script:args = Get-QemuArgs -Iso 'C:\x\MICPE.iso' -ShareDir 'C:\x\share' -MonitorPort 4444
    }
    It 'maps the share directory as a writable fat disk' {
        $script:args | Should -Contain 'file=fat:rw:C:\x\share,format=raw,media=disk,if=ide'
    }
    It 'exposes the monitor on tcp' {
        $script:args | Should -Contain 'tcp:127.0.0.1:4444,server,nowait'
    }
    It 'gives the PE enough memory for a 2.3GB ramdisk' {
        $script:args | Should -Contain '4096'
    }
    It 'does not require a display' {
        $script:args | Should -Contain 'none'
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `pwsh -NoProfile -File scripts/Invoke-Tests.ps1 -Path tests/ProbeAssert.Tests.ps1,tests/QemuArgs.Tests.ps1`
Expected: FAIL — `Read-ProbeFile` 与 `Get-QemuArgs` 未定义

- [ ] **Step 3: 实现 `src/ci/probe.wcs`**

PE 内运行的自检脚本。逐项检测并 `WRIT` 到 `E:\micpe-probe.txt`（`E:` 由 vvfat 提供；先 `FORX` 找带可写测试的盘符，找不到就写 `X:\micpe-probe.txt` 并记 `share=missing`）。

检查顺序与输出键：`boot`、`shell_ready`、`explorer`、`dwm`、`network`、`ime`、`uwp_appx`、`uwp_launch_photos`、`uwp_launch_media`、`uwp_launch_calculator`、`payload`、`brand`、`size_wim`、`size_iso`。每项值为 `1`/`0` 或数字/文本。（用户决定 2026-11-16：UWP 仅保留核心文件，设置应用不带，`uwp_launch_settings` 改为 `uwp_launch_calculator`。）

`uwp_launch_*` 用 `EXEC -su explorer.exe shell:AppsFolder\<AUMID>` 后 `WAIT 3000` 再 `FIND` 对应进程名（`CalculatorApp`、`Microsoft.Lightbox`、`Microsoft.Media.Player`）。进程名已按 provisioned 包的 `AppxManifest.xml` 核实（run 37，run 27 boot.wim）：新版照片应用的进程是 `Microsoft.Lightbox.exe`、媒体播放器是 `Microsoft.Media.Player.exe`；旧名 `Microsoft.Photos.exe`、`Microsoft.ZuneMusic.exe` 在映像里根本不存在。

- [ ] **Step 4: 实现 `Assert-Probe.ps1` 与 `Invoke-QemuVerify.ps1` 并跑测试**

`Invoke-QemuVerify.ps1` 需支持 `-ParseOnly` 开关使其被点源时只定义函数。QEMU 二进制通过 Chocolatey 安装（`choco install qemu -y --no-progress`），失败则回退直接下载 `https://qemu.weilnetz.de/w64/qemu-w64-setup-<ver>.exe` 静默安装。

Run: `pwsh -NoProfile -File scripts/Invoke-Tests.ps1 -Path tests/ProbeAssert.Tests.ps1,tests/QemuArgs.Tests.ps1`
Expected: PASS 6 tests

- [ ] **Step 5: 接入 workflow 并跑 M1 运行时验证**

`.github/workflows/build.yml` 增加输入 `verify`（choice `full`/`static`/`none`，默认 `full`）与步骤：

```powershell
if ('${{ inputs.verify }}' -eq 'full') {
    ./src/ci/Invoke-QemuVerify.ps1 -Iso $iso -ShareDir "$env:WORK\share" -TimeoutMin 40 `
        -ScreenshotDir "$env:WORK\shots" -LogPath "$env:WORK\qemu.log"
    $probe = Read-ProbeFile -Path "$env:WORK\share\probe.txt"
    $expected = @{ boot='1'; share='1' }   # M1 只要求启动成功且回写通道可用
    $bad = Assert-ProbeResult -Probe $probe -Expected $expected
    if ($bad.Count) { Write-Error ($bad -join "`n"); exit 1 }
}
```

上传 artifact：`probe.txt`、`shots/*.ppm`、`qemu.log`。

```bash
git add src/ci .github/workflows tests/ProbeAssert.Tests.ps1 tests/QemuArgs.Tests.ps1
git commit -m "feat(ci): end-to-end qemu verification with vvfat probe channel"
git push && gh workflow run build.yml -f stage=m1 -f build=26200 -f verify=full
```

Expected: workflow 成功；artifact 里 `probe.txt` 含 `boot=1` 与 `share=1`；`shots/shot-*.ppm` 里能看到 cmd 窗口（非全黑）。

- [ ] **Step 6: 每个后续阶段声明自己的 probe 期望**

在 `src/ci/Assert-Probe.ps1` 里加常量表，供各阶段引用：

```powershell
$script:StageProbeExpect = @{
    m1 = @{ boot='1'; share='1' }
    m2 = @{ boot='1'; share='1'; explorer='1'; shell_ready='1'; dwm='1' }
    m3 = @{ boot='1'; share='1'; explorer='1'; shell_ready='1'; dwm='1'; network='*'; ime='1' }
    m4 = @{ boot='1'; share='1'; ime='1'; uwp_appx='1' }
    m5 = @{ boot='1'; share='1'; explorer='1'; shell_ready='1'; dwm='1'; ime='1'; payload='1'; brand='1' }
    m6 = @{ boot='1'; share='1'; explorer='1'; shell_ready='1'; installer_scan='1'; installer_deploy='1' }
    m7 = @{ boot='1'; share='1'; explorer='1'; shell_ready='1'; dwm='1'; network='*'; ime='1'; uwp_appx='1'; uwp_launch_photos='1'; uwp_launch_media='1'; uwp_launch_calculator='1'; payload='1'; brand='1'; installer_scan='1'; installer_deploy='1'; size_wim='*'; size_iso='*' }
}
```

m4 期望放宽（run 44135105700 轮，2026-11-18）：m4 映像无 PECMD.EXE，回退只跑 cmd、不启动 Explorer，所以 explorer / dwm / shell_ready 在 m4 下永远不可能是 1；UWP 应用启动（`uwp_launch_*`，设计上经 PECMD EXEC + explorer.exe）同样不可能。m4 只验其能产出的：能启动、探针能写到共享盘、输入法 preload 已设、UWP AppX 文件在。桌面三项留到 m5 验（PECMD 随 payload 到达），UWP 启动留到 m7 验（完整映像）。三选一的其余两项未采用：让回退启动 Explorer 只会开文件夹窗口、成不了 shell，且 startnet.cmd 退出会结束会话；把 PECMD 提前会动 M5 范围，且打包改向在即、风险高。m2/m3 表里有同样的 latent 缺陷（同样要求 explorer/shell_ready/dwm），本次未动，记在评估卡 §14 里等后续轮处理。

测试补充：断言 `$script:StageProbeExpect` 的每个键都是 `m1..m7`，且 `m7` 包含 `m1` 的全部键。

- [ ] **Step 7: 提交**

```bash
git add src/ci/Assert-Probe.ps1 tests/ProbeAssert.Tests.ps1
git commit -m "feat(ci): per-stage probe expectations"
git push
```

---
### Task 10: M2 — SOFTWARE hive 替换 + Explorer 桌面

**Files:**
- Create: `src/registry/10-pe-base.reg`, `src/registry/20-explorer.reg`, `src/shell/PECMD.INI`, `src/shell/Pin-Shortcuts.wcs`, `src/build/lib/Shell.ps1`
- Test: `tests/Shell.Tests.ps1`

**Interfaces:**
- Consumes: `Export-WimFiles`、`Mount-WimImage`/`Dismount-WimImage`（Task 4）、`Invoke-RegistryScript`（Task 6）、`Read-Whitelist`（Task 4）
- Produces:
  - `Install-ExplorerShell([string] $MountDir, [string] $InstallWim, [string] $RepoRoot)` — 1) 用 `7z` 从 `$InstallWim` 取 `Windows\System32\config\SOFTWARE` 覆盖 `$MountDir\Windows\System32\config\SOFTWARE`；2) 创建 `$MountDir\ProgramData\Microsoft\Windows\AppRepository`（空目录）；3) 创建 `$MountDir\Windows\SystemTemp`；4) `Export-WimFiles` 应用 `20-explorer.txt`
  - `Assert-ExplorerPresent([string] $MountDir)` — 检查 `explorer.exe`、`Windows.StateRepository*.dll`（`Get-ChildItem` 计数 ≥ 4）、`AppRepository` 目录、`SystemTemp` 目录，缺任一项抛错并列出缺失项
  - `Set-BootShell([string] $MountDir, [string] $RepoRoot)` — 把 `startnet.cmd` 改为调 `PECMD.EXE LOAD ...\PECMD.INI`

- [ ] **Step 1: 写失败测试**

```powershell
# tests/Shell.Tests.ps1
BeforeAll {
    . "$PSScriptRoot/../src/build/lib/Common.ps1"
    . "$PSScriptRoot/../src/build/lib/Shell.ps1"
}
Describe 'Assert-ExplorerPresent' {
    It 'lists every missing artifact, not just the first' {
        $m = New-Item -ItemType Directory (Join-Path $env:TEMP "mnt$(Get-Random)")
        $ex = { Assert-ExplorerPresent -MountDir $m.FullName } | Should -Throw
        $err = try { Assert-ExplorerPresent -MountDir $m.FullName } catch { $_.Exception.Message }
        $err | Should -Match 'explorer.exe'
        $err | Should -Match 'AppRepository'
        $err | Should -Match 'SystemTemp'
    }
    It 'passes when all artifacts exist' {
        $m = New-Item -ItemType Directory (Join-Path $env:TEMP "mnt$(Get-Random)")
        New-Item -ItemType Directory -Force "$($m.FullName)\Windows\System32" | Out-Null
        Set-Content "$($m.FullName)\Windows\System32\explorer.exe" 'x'
        New-Item -ItemType Directory -Force "$($m.FullName)\ProgramData\Microsoft\Windows\AppRepository" | Out-Null
        New-Item -ItemType Directory -Force "$($m.FullName)\Windows\SystemTemp" | Out-Null
        4..1 | ForEach-Object { Set-Content "$($m.FullName)\Windows\System32\Windows.StateRepository$_.dll" 'x' }
        { Assert-ExplorerPresent -MountDir $m.FullName } | Should -Not -Throw
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `pwsh -NoProfile -File scripts/Invoke-Tests.ps1 -Path tests/Shell.Tests.ps1`
Expected: FAIL — `Assert-ExplorerPresent` 未定义

- [ ] **Step 3: 实现**

`10-pe-base.reg`：把 `PE-SYS` 的 `ControlSet001\Control\PEBoot` 类键与 `Winlogon\Shell` 设为 `PECMD.EXE`；`20-explorer.reg`：`Winlogon\Shell=explorer.exe`、`Winlogon\Userinit=`（空）、`Explorer\Shell Folders` 桌面指向 `X:\Users\Default\Desktop`、禁用首次登录动画。
`PECMD.INI`（M2 版）：`INIT` → `EXEC %SystemRoot%\explorer.exe` → 起 `ctfmon`。
`Pin-Shortcuts.wcs`：桌面放 `此电脑`、`MICPE`(Program Files\MICPE)、`命令提示符`。
`startnet.cmd` 改为 `wpeinit` + `PECMD.EXE LOAD X:\Program Files\MICPE\PECMD.INI`。

- [ ] **Step 4: 运行测试确认通过**

Run: `pwsh -NoProfile -File scripts/Invoke-Tests.ps1 -Path tests/Shell.Tests.ps1`
Expected: PASS 2 tests

- [ ] **Step 5: 提交并跑 M2**

```bash
git add src/registry src/shell src/build/lib/Shell.ps1 tests/Shell.Tests.ps1 src/build/Build-Micpe.ps1
git commit -m "feat(build): M2 explorer shell via software hive swap"
git push && gh workflow run build.yml -f stage=m2 -f build=26200
```

- [ ] **Step 6: CI 验收 M2**

```bash
gh workflow run build.yml -f stage=m2 -f build=26200 -f verify=full
```

Expected: `probe.txt` 的 `explorer=1`、`shell_ready=1`、`dwm=1`；`shots/shot-01.ppm` 的非黑像素比例 > 8%。未通过时看 artifact 的 `PECMD.LOG` 与 `probe.txt`，每次只改一个变量。

---

### Task 11: M3 — WOW64 运行库与微软拼音

**Files:**
- Create: `src/registry/30-components.reg`
- Modify: `src/build/Build-Micpe.ps1`（`runtimes`/`components` 步骤接入 `Shell.ps1`）
- Test: `tests/Ime.Tests.ps1`

**Interfaces:**
- Consumes: `Export-WimFiles`、`Invoke-RegistryScript`
- Produces:
  - `Install-Runtimes([string] $MountDir, [string] $InstallWim, [string] $RepoRoot)` — 应用 `30-runtimes.txt`，断言 `Windows\SysWOW64\ntdll.dll`、`Windows\System32\wow64.dll` 存在
  - `Install-Ime([string] $MountDir, [string] $InstallWim, [string] $RepoRoot)` — 从 `40-components.txt` 里筛出输入法相关行（`*InputMethod*`、`*ime*`、`*msctf*`、`*TextInputFramework*`、`*ChsIME*`、`*Winlangdb*`）单独提取，断言 `Windows\System32\InputMethod\SHARED` 存在
  - `Assert-ImeRegistered([string] $MountDir)` — 读 `SOFTWARE` hive 的 `Keyboard Layout\Preload`，至少 1 项指向 `0804`；读 `Control\Keyboard Layouts\00000804` 存在

- [ ] **Step 1: 写失败测试**

```powershell
# tests/Ime.Tests.ps1
BeforeAll {
    . "$PSScriptRoot/../src/build/lib/Common.ps1"
    . "$PSScriptRoot/../src/build/lib/Shell.ps1"
}
Describe 'Assert-ImeRegistered' {
    It 'throws naming the missing 0804 preload when hive lacks it' {
        $m = New-Item -ItemType Directory (Join-Path $env:TEMP "mnt$(Get-Random)")
        $hive = Join-Path $env:TEMP "s$(Get-Random).hiv"
        Copy-Item "$env:SystemRoot\System32\config\SOFTWARE" $hive
        New-Item -ItemType Directory -Force "$($m.FullName)\Windows\System32\config" | Out-Null
        Move-Item $hive "$($m.FullName)\Windows\System32\config\SOFTWARE"
        (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Keyboard Layout\Preload' -ErrorAction SilentlyContinue) | Out-Null
        { Assert-ImeRegistered -MountDir $m.FullName } | Should -Throw '*0804*'
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `pwsh -NoProfile -File scripts/Invoke-Tests.ps1 -Path tests/Ime.Tests.ps1`
Expected: FAIL — `Assert-ImeRegistered` 未定义

- [ ] **Step 3: 实现**

`Assert-ImeRegistered` 挂载 `$MountDir\Windows\System32\config\SOFTWARE` 为 `PE-IME`，读 `Microsoft\Windows NT\CurrentVersion\Keyboard Layout\Preload` 的所有值，任一值含 `0804` 则通过，否则抛出消息含 `0804` 与当前所有值。`30-components.reg` 写 `Preload\1=00000804`（微软拼音）。

- [ ] **Step 4: 运行测试确认通过**

Run: `pwsh -NoProfile -File scripts/Invoke-Tests.ps1 -Path tests/Ime.Tests.ps1`
Expected: PASS 1 test

- [ ] **Step 5: 提交并跑 M3**

```bash
git add src/registry/30-components.reg src/build tests/Ime.Tests.ps1
git commit -m "feat(build): M3 wow64 runtimes and Microsoft Pinyin IME"
git push && gh workflow run build.yml -f stage=m3 -f build=26200
```

- [ ] **Step 6: CI 验收 M3**

```bash
gh workflow run build.yml -f stage=m3 -f build=26200 -f verify=full
```

Expected: `ime=1`（`Preload` 含 `0804`）；`network` 为 `*`（非空即可，DHCP 慢时允许 `pending`）。输入法的"能打字"由 `ime=1` + 桌面截图 + 后续真机一次确认覆盖；probe 不模拟按键。

---

### Task 12: M4 — UWP 栈与三个应用

**Files:**
- Create: `src/build/lib/Uwp.ps1`, `src/registry/40-uwp.reg`
- Test: `tests/Uwp.Tests.ps1`

**Interfaces:**
- Consumes: Task 4–6
- Produces:
  - `Install-AppxFramework([string] $MountDir, [string] $InstallWim)` — 从 install.wim 提取 `Program Files\WindowsApps\Microsoft.VCLibs.140.00*`、`Microsoft.NET.Native.*`、`Microsoft.UI.Xaml.*`、`Microsoft.WindowsAppRuntime*`，断言至少 5 个框架包目录
  - `Register-ProvisionedAppx([string] $MountDir, [string[]] $PackageNames)` — 向 `$MountDir\Windows\System32\config\SOFTWARE` 的 `Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Applications` 写键；对每个名称断言键存在（InboxApplications 不写：构建管理员无权写入该键，见 CI run 44008629819；它是启动时不查的 servicing 元数据）
  - `Get-UwpDefaults()` — 返回 `@('Microsoft.WindowsCalculator','Microsoft.Windows.Photos','Microsoft.ZuneMusic')`（用户决定 2026-11-16：仅保留核心文件，设置与 Store 不带）
  - `Assert-UwpReady([string] $MountDir)` — 断言 `Windows\System32\AppXDeploymentClient.dll`、`Windows.StateRepository*.dll` ≥4、`Windows\System32\Windows.UI.Xaml.dll`、`AppRepository` 目录、且默认应用名对应的 `WindowsApps\<name>_*` 目录各 ≥1

- [ ] **Step 1: 写失败测试**

```powershell
# tests/Uwp.Tests.ps1
BeforeAll {
    . "$PSScriptRoot/../src/build/lib/Common.ps1"
    . "$PSScriptRoot/../src/build/lib/Uwp.ps1"
}
Describe 'Assert-UwpReady' {
    It 'reports each missing uwp artifact by name' {
        $m = New-Item -ItemType Directory (Join-Path $env:TEMP "mnt$(Get-Random)")
        $msg = try { Assert-UwpReady -MountDir $m.FullName } catch { $_.Exception.Message }
        $msg | Should -Match 'AppXDeploymentClient'
        $msg | Should -Match 'Windows.UI.Xaml'
        $msg | Should -Match 'Windows.StateRepository'
    }
}
Describe 'Get-UwpDefaults' {
    It 'includes photos, media player and calculator' {
        $d = Get-UwpDefaults
        $d | Should -Contain 'Microsoft.Windows.Photos'
        $d | Should -Contain 'Microsoft.ZuneMusic'
        $d | Should -Contain 'Microsoft.WindowsCalculator'
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `pwsh -NoProfile -File scripts/Invoke-Tests.ps1 -Path tests/Uwp.Tests.ps1`
Expected: FAIL — `Assert-UwpReady` 未定义

- [ ] **Step 3: 实现**

`Install-AppxFramework` 的提取清单基于 `Program Files\WindowsApps\` 前缀通配（这是 install.wim 里真实布局）。`Register-ProvisionedAppx` 只写 `AppxAllUserStore` 的允许运行键（`InboxApplications` 的 `Path` 值不写：构建管理员无权写入该键，CI run 44008629819 实证）；不复制 `StateRepository` 数据库（必须由首次启动生成，复制会导致 0x80073CF9）。`40-uwp.reg` 写 `Appx\\AllowAllTrustedApps` / `AllowDevelopmentWithoutDevLicense`（=1），构建时以 SYSTEM 身份导入（Invoke-RegImportAsSystem，一次性计划任务）：Appx 键的 DACL 只给 Administrators 只读权限，管理员 `reg import` 写不进去（CI run 44040699722 实证），而该 DACL 本身给 SYSTEM 完全控制；用户决定 2026-11-17 23:43：一切注册表导入都在 CI 挂载时做，禁止进 PE 后再导入；`StateRepository` 服务键是 install.wim 原样全键照抄（Start=2 自动，含 ImagePath / parameters / Security，由生成器从真实 hive 实读）。

- [ ] **Step 4: 运行测试确认通过**

Run: `pwsh -NoProfile -File scripts/Invoke-Tests.ps1 -Path tests/Uwp.Tests.ps1`
Expected: PASS 2 tests

- [ ] **Step 5: 提交并跑 M4**

```bash
git add src/build/lib/Uwp.ps1 src/registry/40-uwp.reg tests/Uwp.Tests.ps1 src/build/Build-Micpe.ps1
git commit -m "feat(build): M4 appx framework and provisioned uwp apps"
git push && gh workflow run build.yml -f stage=m4 -f build=26200
```

- [ ] **Step 6: CI 验收 M4**

```bash
gh workflow run build.yml -f stage=m4 -f build=26200 -f verify=full
```

Expected: `uwp_appx=1`、`uwp_launch_photos=1`、`uwp_launch_media=1`、`uwp_launch_calculator=1`。（用户决定 2026-11-16：设置应用不带，`uwp_launch_settings` 改为 `uwp_launch_calculator`。）probe 用 `explorer shell:AppsFolder\<AUMID>` 拉起后检查进程存活，失败即该项为 `0`。失败时看 artifact 里的 `probe.txt` 与截图；若 `uwp_appx=0` 先查 AppX 栈文件，若 `uwp_appx=1` 但 `uwp_launch_*=0` 先查 `StateRepository` 与 `AppRepository` 目录。

---

### Task 13: Payload 发布与注入（M5）

**Files:**
- Create: `src/build/lib/Payload.ps1`, `docs/payload.md`
- Test: `tests/Payload.Tests.ps1`

**Interfaces:**
- Consumes: Task 2 断言
- Produces:
  - `Get-AppPackageArchiveName([string] $Name)` — `Name` ∈ `payload|chrome|office`，返回拼回后的归档名：`micpe-payload.7z` / `chrome-slim.7z` / `office2016-slim.7z`
  - `Get-AppPackageVolumePaths([string] $Name, [string] $RepoRoot)` — 返回该包在 `app/<包>/` 下的分卷完整路径（拼回顺序）
  - `Join-AppPackageVolumes([string[]] $Volumes, [string] $OutFile)` — 按顺序字节拼接分卷
  - `Get-AppPackageArchive([string] $Name, [string] $RepoRoot, [string] $StagingDir)` — 拼回（单文件包直接拷）并验 SHA256，mismatch 直接报错停下；重打归档必须同 commit 更新 pin，绝不静默放宽
  - `Expand-Payload([string] $Archive, [string] $Destination)` — 用 `7z x` 展开，断言展开后有 `ProgramFiles\7-zip\7z.exe` 与 `ProgramFiles\MICPE\PENetwork\PENetwork.exe`
  - `Install-Payload([string] $MountDir, [string] $PayloadDir, [switch] $Chrome, [switch] $Office)` — 把 `$PayloadDir\ProgramFiles\*` 拷到 `$MountDir\Program Files\`；`-Chrome` 时额外解 `chrome-slim.7z` 到 `Program Files\Google\Chrome\Application`；`-Office` 时解 `office2016-slim.7z` 到 `Program Files\Office2016`
  - `Assert-PayloadInstalled([string] $MountDir, [switch] $Chrome, [switch] $Office)` — 断言 `Program Files\7-zip\7z.exe`、`Program Files\MICPE\PENetwork\PENetwork.exe`、`Program Files\MICPE\MICPE-Setup\MICPE-Setup.wcs`、`Program Files\DiskGenius.exe`、`Program Files\WinNTSetup\unattend\Win10_x64.xml`

- [ ] **Step 1: 写失败测试**

```powershell
# tests/Payload.Tests.ps1
BeforeAll {
    . "$PSScriptRoot/../src/build/lib/Common.ps1"
    . "$PSScriptRoot/../src/build/lib/Payload.ps1"
}
Describe 'Assert-PayloadInstalled' {
    It 'names every missing required item' {
        $m = New-Item -ItemType Directory (Join-Path $env:TEMP "mnt$(Get-Random)")
        $msg = try { Assert-PayloadInstalled -MountDir $m.FullName } catch { $_.Exception.Message }
        $msg | Should -Match '7-zip\\7z\.exe'
        $msg | Should -Match 'MICPE\\PENetwork\\PENetwork\.exe'
        $msg | Should -Match 'DiskGenius\.exe'
        $msg | Should -Match 'Win10_x64\.xml'
    }
}
Describe 'app packages' {
    It 'maps each package to its joined-archive name' {
        Get-AppPackageArchiveName -Name 'payload' | Should -Be 'micpe-payload.7z'
        Get-AppPackageArchiveName -Name 'chrome'  | Should -Be 'chrome-slim.7z'
        Get-AppPackageArchiveName -Name 'office'  | Should -Be 'office2016-slim.7z'
    }
    It 'maps each package to its committed volumes, in join order' {
        (Get-AppPackageVolumePaths -Name 'chrome' -RepoRoot $RepoRoot |
            ForEach-Object { Split-Path -Leaf $_ }) -join ',' |
            Should -Be 'chrome-slim.7z.001,chrome-slim.7z.002'
    }
    It 'rejects an unknown package name' {
        { Get-AppPackageArchiveName -Name 'nope' } | Should -Throw
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `pwsh -NoProfile -File scripts/Invoke-Tests.ps1 -Path tests/Payload.Tests.ps1`
Expected: FAIL — `Assert-PayloadInstalled` 未定义

- [ ] **Step 3: 三个包分卷进仓库 `app/`（打包轮，一次性）**

用本地恢复包里的材料打包（`/root/micpe-ref/` 在本机不存在，不要再引用它；
材料在 `~/workspace/MIC-PE-recovery/MIC-PE.7z`，已解包到
`~/workspace/micpe-m5-material/`）。Chrome 与 Office 先精简、重打，
再按 95 MB 分卷提交进仓库；payload 单文件直接提交：

```bash
MATERIAL="$HOME/workspace/micpe-m5-material"
PECMD="$MATERIAL/dsi/DSI-安装备份-源码/make/PECMD.EXE"
# PECMD.EXE 必须用 DSI 附带的副本（design.md §6.5 已指定可直接作为运行时；
# 不要用 GhostCGI 自带的另一个二进制）。缺失时明确报错停下，绝不能静默
# 跳过——否则 payload 会悄悄缺 PECMD，镜像启动回退到 cmd 才被发现。
test -f "$PECMD" || { echo "PECMD.EXE missing: $PECMD"; exit 1; }

# payload：112 文件树 + DSI PECMD.EXE，用 New-PayloadArchive 打包
# （两次连续构建哈希一致），直接提交到 app/payload/micpe-payload.7z。
# Chrome：从 MSI 提取 → 删 Locales（只留 en-US、zh-CN 各 4 个 .pak）→
# 删 WidevineCdm/ → 7z -mx=9 重打 chrome-slim.7z（顶层 Chrome-bin/）。
# Office：解包 → 删 36 个 Access 相关文件 → 删厂商 !)inst.cmd / -)unist.cmd
# → 7z -mx=9 重打 office2016-slim.7z（顶层 Office2016/，OSPP.VBS 保留）。
# 分卷（单文件 < 100 MB 上限）：
split -b 95M -d --numeric-suffixes=1 --suffix-length=3 chrome-slim.7z chrome-slim.7z.
split -b 95M -d --numeric-suffixes=1 --suffix-length=3 office2016-slim.7z office2016-slim.7z.
# 拼回验哈希（必须与 Payload.ps1 里的 pin 一致）再提交：
cat chrome-slim.7z.001 chrome-slim.7z.002 | sha256sum
cat office2016-slim.7z.001 office2016-slim.7z.002 | sha256sum
```

三个包相互独立：CI 只在对应开关开启时才拼回对应资产。`docs/payload.md`
记录每个包的来源、精简清单、许可、更新方法与替换步骤。旧的三个独立
Release 资产（`payload-v1` / `chrome-v1` / `office-v1`）已于分卷版验证
通过后删除，不再有第二条包来源；以后构建出成品自动上传 Release（tag
`micpe-<stage>-<build>-<yyyymmdd>-r<run_number>`，见 build.yml）。

- [ ] **Step 4: 实现 `Payload.ps1` 并跑测试**

Run: `pwsh -NoProfile -File scripts/Invoke-Tests.ps1 -Path tests/Payload.Tests.ps1`
Expected: PASS 4 tests

- [ ] **Step 5: 提交并跑 M5**

```bash
git add src/build/lib/Payload.ps1 tests/Payload.Tests.ps1 docs/payload.md
git commit -m "feat(build): M5 payload download and injection"
git push && gh workflow run build.yml -f stage=m5 -f build=26200
```

- [ ] **Step 6: CI 验收 M5**

```bash
gh workflow run build.yml -f stage=m5 -f build=26200 -f verify=full
```

Expected: `payload=1`（关键路径与快捷方式齐备）；`brand=1`。probe 的 `payload` 项已含 `7-zip\7z.exe` 小写路径检查（`GhostCGI` 的硬依赖）。

---

### Task 14: 品牌注入（M5 收尾）

**Files:**
- Create: `src/build/lib/Brand.ps1`, `src/registry/50-brand.reg`, `assets/logo.bmp`, `assets/wallpaper.jpg`
- Test: `tests/Brand.Tests.ps1`

**Interfaces:**
- Consumes: Task 6 `Import-RegFile`
- Produces:
  - `Set-Brand([string] $MountDir, [string] $RepoRoot)` — 覆盖 `Windows\Web\Wallpaper\Windows\img0.jpg`、写 `Windows\System32\oemlogo.bmp`、生成 `Program Files\MICPE\说明.txt`（含版本、构建号、作者、B 站地址）
  - `Get-BrandRegContent([string] $Version, [string] $BuildNumber)` — 纯函数，返回 `.reg` 全文（UTF-16LE 之前的内容），供测试断言键值
  - `Assert-BrandApplied([string] $MountDir)` — 断言 OEM 六个值、`RegisteredOwner`/`RegisteredOrganization`、`oemlogo.bmp` 尺寸 120×120

- [ ] **Step 1: 写失败测试**

```powershell
# tests/Brand.Tests.ps1
BeforeAll {
    . "$PSScriptRoot/../src/build/lib/Common.ps1"
    . "$PSScriptRoot/../src/build/lib/Brand.ps1"
}
Describe 'Get-BrandRegContent' {
    BeforeAll { $r = Get-BrandRegContent -Version '1.0.0' -BuildNumber '26200.10066' }
    It 'sets SupportURL to the bilibili page' {
        $r | Should -Match 'SupportURL"="https://space\.bilibili\.com/1978487514"'
    }
    It 'sets Model to SYSTEM-Intel-MIC and Manufacturer to MICPE' {
        $r | Should -Match 'Manufacturer"="MICPE"'
        $r | Should -Match 'Model"="SYSTEM-Intel-MIC"'
    }
    It 'sets owner and organization' {
        $r | Should -Match 'RegisteredOwner"="SYSTEM-Intel-MIC"'
        $r | Should -Match 'RegisteredOrganization"="MICPE"'
    }
    It 'points Logo at oemlogo.bmp' {
        $r | Should -Match 'Logo"="%SystemRoot%\\\\System32\\\\oemlogo\.bmp"'
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `pwsh -NoProfile -File scripts/Invoke-Tests.ps1 -Path tests/Brand.Tests.ps1`
Expected: FAIL — `Get-BrandRegContent` 未定义

- [ ] **Step 3: 实现**

`assets/` 从本地恢复包解包目录 `~/workspace/micpe-m5-material/品牌化/` 拷入 `logo.bmp`（120×120×24bpp）与 `wallpaper.jpg`（1920×1080）（`/root/micpe-ref/品牌化/` 在本机不存在）。`Set-Brand` 写 `.reg` 时转 UTF-16LE。`Assert-BrandApplied` 读 BMP 头 `18..26` 字节的宽高（`[BitConverter]::ToInt32`）。`说明.txt` 用 UTF-8 with BOM 保证记事本正常显示。

- [ ] **Step 4: 运行测试确认通过**

Run: `pwsh -NoProfile -File scripts/Invoke-Tests.ps1 -Path tests/Brand.Tests.ps1`
Expected: PASS 4 tests

- [ ] **Step 5: 提交并跑阶段验证**

```bash
git add src/build/lib/Brand.ps1 src/registry/50-brand.reg assets tests/Brand.Tests.ps1
git commit -m "feat(build): OEM branding, wallpaper and oemlogo"
git push && gh workflow run build.yml -f stage=m5 -f build=26200
```

- [ ] **Step 6: CI 验收**

```bash
gh workflow run build.yml -f stage=m5 -f build=26200 -f verify=full
```

Expected: `brand=1`。probe 读 hive 断言 OEM 六个值（Manufacturer=MICPE、Model=SYSTEM-Intel-MIC、SupportURL 指向 B 站、SupportProvider、Logo 路径）、`RegisteredOwner`/`RegisteredOrganization`、`oemlogo.bmp` 尺寸 120×120；截图确认壁纸已生效（`shots/shot-01.ppm` 与仓库 `assets/wallpaper.jpg` 的 8×8 缩略图差异度低于阈值）。

---

### Task 15: 装机工具 — 源发现（`install.mic`）

**Files:**
- Create: `src/installer/MICPE-Setup.wcs`（本任务只做发现与列表部分）、`src/installer/MICPE-Setup.ini`, `src/installer/lang/zh-CN.txt`, `src/installer/Discover.ps1`
- Test: `tests/Discover.Tests.ps1`

**Interfaces:**
- Consumes: 无（独立可测）
- Produces:
  - `Find-InstallSource([string[]] $Roots)` — 纯函数：输入卷根数组（如 `D:\`），返回 `[pscustomobject[]]`，每项 `@{ Root; ImagePath; DisplayName; HasMarker }`
  - `Read-InstallMic([string] $Path)` — 读去 BOM 后首行，`Trim()`，空则返回 `$null`
  - `Test-InstallImage([string] $Path)` — 存在且 > 512 MB 且扩展名 `.wim`/`.esd` 才为真
  - 排序规则：`HasMarker` 降序 → `ImagePath` 含 `sources\` 降序 → `Root` 升序

- [ ] **Step 1: 写失败测试**

```powershell
# tests/Discover.Tests.ps1
BeforeAll { . "$PSScriptRoot/../src/installer/Discover.ps1" }

Describe 'Find-InstallSource' {
    BeforeEach {
        $script:r = @()
        1..3 | ForEach-Object {
            $d = New-Item -ItemType Directory (Join-Path $env:TEMP "vol$($_)`_$(Get-Random)")
            $script:r += $d.FullName
        }
    }
    It 'prefers a volume with install.mic over one with only install.wim' {
        # vol1: bare sources\install.wim (512MB sparse)
        New-Item -ItemType Directory -Force "$($script:r[0])\sources" | Out-Null
        $f = [IO.File]::Create("$($script:r[0])\sources\install.wim"); $f.SetLength(600MB); $f.Close()
        # vol2: install.mic + sources\install.wim
        New-Item -ItemType Directory -Force "$($script:r[1])\sources" | Out-Null
        Set-Content "$($script:r[1])\install.mic" 'MICPE 定制系统 v1'
        $f = [IO.File]::Create("$($script:r[1])\sources\install.wim"); $f.SetLength(600MB); $f.Close()

        $res = Find-InstallSource -Roots $script:r
        $res[0].Root | Should -Be $script:r[1]
        $res[0].DisplayName | Should -Be 'MICPE 定制系统 v1'
        $res[0].HasMarker | Should -BeTrue
    }
    It 'reports a marker volume whose image is missing as a broken entry' {
        Set-Content "$($script:r[2])\install.mic" 'Broken'
        $res = Find-InstallSource -Roots $script:r
        $b = $res | Where-Object Root -EQ $script:r[2]
        $b.HasMarker | Should -BeTrue
        $b.ImagePath | Should -BeNullOrEmpty
        $b.Broken | Should -BeTrue
    }
    It 'ignores tiny or wrong-extension files' {
        New-Item -ItemType Directory -Force "$($script:r[0])\sources" | Out-Null
        Set-Content "$($script:r[0])\sources\install.wim" 'tiny'
        (Find-InstallSource -Roots @($script:r[0])).Count | Should -Be 0
    }
    It 'skips a root that throws instead of failing the whole scan' {
        $bad = 'Z:\definitely-not-a-volume'
        (Find-InstallSource -Roots @($bad, $script:r[1])).Count | Should -Be 1
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `pwsh -NoProfile -File scripts/Invoke-Tests.ps1 -Path tests/Discover.Tests.ps1`
Expected: FAIL — `Find-InstallSource` 未定义

- [ ] **Step 3: 实现 `src/installer/Discover.ps1`**

`Find-InstallSource` 每个根放在 `try/catch` 里，异常只写警告并 `continue`（覆盖 Review Focus #5）。标记卷但映像缺失 → 返回 `Broken=$true`、`ImagePath=$null`（覆盖 Review Focus #1）。`Test-InstallImage` 的阈值常量 `$script:MinImageBytes = 512MB`。`Read-InstallMic` 用 `[IO.File]::ReadAllLines` 并 `TrimStart([char]0xFEFF)`。

`MICPE-Setup.ini` 内容：`LogDir=X:\Program Files\MICPE\logs`、`MinImageBytes=536870912`、`DiskGenius=X:\Program Files\DiskGenius.exe`、`UnattendDir=X:\Program Files\WinNTSetup\unattend`。

- [ ] **Step 4: 运行测试确认通过**

Run: `pwsh -NoProfile -File scripts/Invoke-Tests.ps1 -Path tests/Discover.Tests.ps1`
Expected: PASS 4 tests

- [ ] **Step 5: 提交**

```bash
git add src/installer tests/Discover.Tests.ps1
git commit -m "feat(installer): install.mic discovery protocol"
```

---

### Task 16: 装机工具 — 校验、应用、引导

**Files:**
- Create: `src/installer/Deploy.ps1`
- Modify: `src/installer/MICPE-Setup.wcs`
- Test: `tests/Deploy.Tests.ps1`

**Interfaces:**
- Consumes: Task 14
- Produces:
  - `Get-WimIndexes([string] $WimPath)` — 调 `wimlib-imagex info`，解析出 `[pscustomobject[]] @{ Index; Name; Description; SizeBytes }`
  - `Select-DefaultIndex([object[]] $Indexes, [string] $DisplayName)` — 纯函数：名称与 `$DisplayName` 完全相等优先，否则含 `$DisplayName`，否则第一个；返回 `int`
  - `Test-TargetSpace([string] $WimPath, [int] $Index, [string] $TargetRoot)` — 返回 `@{ Required; Available; Ok }`；`Required` = 索引的 `SizeBytes * 1.15`（`wimlib` 报的是未压缩大小，乘 1.15 留余量）
  - `Test-TargetSafety([string] $TargetRoot, [string] $ImageRoot, [string] $PeRoot)` — 返回 `@{ Ok; Reason }`：目标等于 PE 的 `X:\` 根或等于 `$ImageRoot` 时 `Ok=$false` 并给出中文原因
  - `Invoke-Deploy([string] $WimPath, [int] $Index, [string] $TargetRoot)` — 依次：`format.com <drive> /FS:NTFS /Q /Y`（先 `mountvol` 卸载）→ `wimlib-imagex apply <wim> <index> <target>` → 返回退出码
  - `Repair-Boot([string] $TargetRoot, [string] $BootRoot)` — `bcdboot <target>\Windows /s <boot> /f ALL`

> **M7 决定（2026-11-17）：应用与查询工具从 wimlib-imagex 改成 DISM。**
> `wimlib-imagex.exe` 只在构建主机上存在，从不进 PE；`dism.exe` 已在出货
> boot.wim 里（两个索引都核实有）。`Get-WimIndexes` 改调
> `dism.exe /English /Get-WimInfo`，解析 `Index : N` / `Name :` /
> `Description :` / `Size : <千分位> bytes`；`Invoke-Deploy` 改调
> `dism.exe /English /Apply-Image /ImageFile:<wim> /Index:<n> /ApplyDir:<target>`。
> 参数名 `$WimlibPath` 改为 `$DismPath`（保留别名）。构建侧提取仍用 wimlib
>（`Wim.ps1`），只改 PE 内运行时。详见 `docs/installer.md`。

- [ ] **Step 1: 写失败测试**

```powershell
# tests/Deploy.Tests.ps1
BeforeAll { . "$PSScriptRoot/../src/installer/Deploy.ps1" }

Describe 'Select-DefaultIndex' {
    It 'picks exact name match' {
        $ix = @(
            [pscustomobject]@{ Index=1; Name='Windows 11 家庭版' },
            [pscustomobject]@{ Index=2; Name='MICPE 定制系统 v1' }
        )
        Select-DefaultIndex -Indexes $ix -DisplayName 'MICPE 定制系统 v1' | Should -Be 2
    }
    It 'falls back to first when nothing matches' {
        $ix = @([pscustomobject]@{ Index=3; Name='A' }, [pscustomobject]@{ Index=7; Name='B' })
        Select-DefaultIndex -Indexes $ix -DisplayName 'nothing' | Should -Be 3
    }
}
Describe 'Test-TargetSpace' {
    It 'requires 15 percent headroom over reported size' {
        $r = Test-TargetSpace -RequiredBytes 1000 -AvailableBytes 1100
        $r.Ok | Should -BeFalse
        $r.Required | Should -Be 1150
    }
    It 'passes with enough room' {
        (Test-TargetSpace -RequiredBytes 1000 -AvailableBytes 2000).Ok | Should -BeTrue
    }
}
Describe 'Test-TargetSafety' {
    It 'refuses when target equals the image volume' {
        $r = Test-TargetSafety -TargetRoot 'D:\' -ImageRoot 'D:\' -PeRoot 'X:\'
        $r.Ok | Should -BeFalse
        $r.Reason | Should -Match '镜像'
    }
    It 'refuses when target is the running PE volume' {
        (Test-TargetSafety -TargetRoot 'X:\' -ImageRoot 'D:\' -PeRoot 'X:\').Ok | Should -BeFalse
    }
    It 'allows a normal target' {
        (Test-TargetSafety -TargetRoot 'C:\' -ImageRoot 'D:\' -PeRoot 'X:\').Ok | Should -BeTrue
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `pwsh -NoProfile -File scripts/Invoke-Tests.ps1 -Path tests/Deploy.Tests.ps1`
Expected: FAIL — `Select-DefaultIndex` 未定义

- [ ] **Step 3: 实现 `src/installer/Deploy.ps1`**

`Get-WimIndexes` 解析 `wimlib-imagex info <wim>` 的 `Index:` / `Name:` / `Description:` / `Total Bytes:` 行。`Test-TargetSpace` 的重载签名必须同时支持 `-RequiredBytes/-AvailableBytes`（测试用）与 `-WimPath/-Index/-TargetRoot`（运行用），用参数集区分。`Invoke-Deploy` 里 `format.com` 用 `Get-Volume` 拿 `DriveLetter` 再组 `/FS:NTFS` 命令。

`MICPE-Setup.wcs` 补上三段：应用前调 `Test-TargetSpace` 与 `Test-TargetSafety`（不通过就停在确认页并显示中文原因），应用时进度条按 `wimlib` 的 `Extracting file` 数量估算，完成后调 `Repair-Boot`。

- [ ] **Step 4: 运行测试确认通过**

Run: `pwsh -NoProfile -File scripts/Invoke-Tests.ps1 -Path tests/Deploy.Tests.ps1`
Expected: PASS 6 tests

- [ ] **Step 5: 提交**

```bash
git add src/installer/Deploy.ps1 src/installer/MICPE-Setup.wcs tests/Deploy.Tests.ps1
git commit -m "feat(installer): space and safety checks, apply, boot repair"
```

---

### Task 17: 装机工具 — 界面与自弹（M6）

**Files:**
- Modify: `src/installer/MICPE-Setup.wcs`, `src/shell/PECMD.INI`
- Create: `docs/installer.md`
- Test: `tests/InstallerAssets.Tests.ps1`

**Interfaces:**
- Consumes: Task 14/15
- Produces:
  - `MICPE-Setup.wcs` 支持命令行 `-auto "<imagePath>"`，接受则跳过选择直接进确认页
  - `PECMD.INI` 在探到源时 `EXEC` 装机工具，未探到时只起桌面

- [ ] **Step 1: 写失败测试**

```powershell
# tests/InstallerAssets.Tests.ps1
BeforeAll { $root = "$PSScriptRoot/.." }
Describe 'installer assets' {
    It 'wcs exists and declares the auto switch' {
        $w = Get-Content "$root/src/installer/MICPE-Setup.wcs" -Raw
        $w | Should -Match '-auto'
        $w | Should -Match 'install\.mic'
    }
    It 'wcs opens DiskGenius for the partition button' {
        (Get-Content "$root/src/installer/MICPE-Setup.wcs" -Raw) | Should -Match 'DiskGenius\.exe'
    }
    It 'wcs offers the two unattend templates and is opt-in' {
        $w = Get-Content "$root/src/installer/MICPE-Setup.wcs" -Raw
        $w | Should -Match 'Win10_x64\.xml'
        $w | Should -Match 'Win7-11-Select\.xml'
        $w | Should -Match '无人值守\.Check=0'
    }
    It 'PECMD.INI launches the installer only when a source was found' {
        $p = Get-Content "$root/src/shell/PECMD.INI" -Raw
        $p | Should -Match 'MICPE-Setup'
        $p | Should -Match 'IFEX'
    }
    It 'ini points logs and DiskGenius at the MICPE paths' {
        $i = Get-Content "$root/src/installer/MICPE-Setup.ini" -Raw
        $i | Should -Match 'LogDir=X:\\Program Files\\MICPE\\logs'
        $i | Should -Match 'DiskGenius=X:\\Program Files\\DiskGenius\.exe'
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `pwsh -NoProfile -File scripts/Invoke-Tests.ps1 -Path tests/InstallerAssets.Tests.ps1`
Expected: FAIL — `.wcs` 缺 `-auto`

- [ ] **Step 3: 实现界面**

按 spec §5.4 的 ASCII 布局实现：单窗口 760×520、`#F3F3F3` 背景、白色卡片、`#0067C0` 主按钮、`#C42B1C` 危险按钮、`Microsoft YaHei UI` 字体。控件：镜像卡片 + `更换镜像`/`重新扫描`/`分区` 三按钮、版本下拉、磁盘/分区表格（列：名称、大小、类型、角色）、`格式化系统分区` / `自动修复引导` / `写入 OEM 信息` 三个默认勾选、`使用无人值守`（默认不勾）+ `编辑/选择 xml`、`开始安装` 主按钮。`分区` 按钮 `EXEC X:\Program Files\DiskGenius.exe`。无可用分区时表格区显示"未找到可安装的分区 · [打开 DiskGenius 分区]"并用灰色禁用开始按钮。

`PECMD.INI` 增加：`FORX` 扫 `C:`..`Z:`，`IFEX <root>\install.mic` 或 `IFEX <root>\sources\install.wim` 则 `EXEC` 装机工具，并设标记防重复启动。

- [ ] **Step 4: 运行测试确认通过**

Run: `pwsh -NoProfile -File scripts/Invoke-Tests.ps1 -Path tests/InstallerAssets.Tests.ps1`
Expected: PASS 5 tests

- [ ] **Step 5: 提交并跑 M6**

```bash
git add src/installer src/shell/PECMD.INI docs/installer.md tests/InstallerAssets.Tests.ps1
git commit -m "feat(installer): win11-styled wizard with auto-launch"
git push && gh workflow run build.yml -f stage=m6 -f build=26200
```

- [ ] **Step 6: CI 验收 M6（三个虚拟盘场景全在 CI 里造）**

`Invoke-QemuVerify.ps1` 在 M6 阶段额外挂三块 `qcow2` 数据盘，分别造出 spec 要求的三种场景：

| 盘 | 内容 | 期望 probe |
|---|---|---|
| disk2 | 空白 NTFS（无标记） | `installer_scan=nopartition`（界面显示"未找到可安装的分区"） |
| disk3 | NTFS + 根 `install.mic`（首行 `MICPE 定制系统 v1`）+ `sources\install.wim` 副本 | `installer_scan=1`、`installer_source=marker`、`installer_name=MICPE 定制系统 v1` |
| disk4 | NTFS + `sources\install.wim`（无标记） | `installer_scan=1`、`installer_source=fallback` |

再加一块 `disk5`（空白 64 GB qcow2）跑完整部署：probe 调 `MICPE-Setup.wcs -cli -deploy` 装到 disk5 主分区，输出 `installer_deploy=1`；CI 随后用 `bcdedit /store`（挂 disk5 的 BCD）验证引导条目存在。

```bash
gh workflow run build.yml -f stage=m6 -f build=26200 -f verify=full
```

Expected: 四种场景的 probe 全部符合上表；`shots/shot-0*.ppm` 能看到装机工具窗口（非黑像素 > 5%）。

---

### Task 18: M7 — 体积治理、双启 ISO、分卷发布

**Files:**
- Modify: `src/build/lib/Stages.ps1`（加 `Get-DegradeOrder`/`Invoke-Degrade`）、`src/build/Build-Micpe.ps1`、`.github/workflows/build.yml`
- Create: `docs/test-checklist.md`
- Test: `tests/Packaging.Tests.ps1`

**Interfaces:**
- Consumes: 全部
- Produces:
  - `Get-DegradeOrder()` — 返回 `@('office','chrome','photos','mediaplayer')`
  - `Invoke-Degrade([long] $CurrentWimBytes, [string[]] $Enabled)` — 纯函数：超 3 GB 时按顺序给出下一个要砍的项，返回 `@{ TooBig; NextToDrop }`
  - workflow 在 tag 推送与 `workflow_dispatch` 时发布 Release

- [ ] **Step 1: 写失败测试**

```powershell
# tests/Packaging.Tests.ps1
BeforeAll { . "$PSScriptRoot/../src/build/lib/Stages.ps1" }

Describe 'Invoke-Degrade' {
    It 'drops office first when over the cap' {
        $r = Invoke-Degrade -CurrentWimBytes (3.1GB) -Enabled @('office','chrome')
        $r.TooBig | Should -BeTrue
        $r.NextToDrop | Should -Be 'office'
    }
    It 'is fine under the cap' {
        (Invoke-Degrade -CurrentWimBytes (2.5GB) -Enabled @('office','chrome')).TooBig | Should -BeFalse
    }
    It 'exhausts the order without repeating' {
        (Invoke-Degrade -CurrentWimBytes (3.1GB) -Enabled @()).NextToDrop | Should -BeNullOrEmpty
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `pwsh -NoProfile -File scripts/Invoke-Tests.ps1 -Path tests/Packaging.Tests.ps1`
Expected: FAIL — `Invoke-Degrade` 未定义

- [ ] **Step 3: 实现**

`Build-Micpe.ps1` 在 `iso` 步骤前插入体积断言与降级决策；超限时构建失败并在日志给出"请关掉 `-Office`/`-Chrome`"的明确指令（不自动重跑，避免 CI 时间翻倍）。

workflow 增加发布步骤：`7z a -v2000m -mx=0 "$isoBase.iso.zip" <iso>`、`gh release create`/`upload`、notes 含构建号、选项列表、SHA256、体积、下载合并说明。

`docs/test-checklist.md` 按 M1–M7 建表，每行一项判定与"通过/不通过/备注"列。

- [ ] **Step 4: 运行测试确认通过**

Run: `pwsh -NoProfile -File scripts/Invoke-Tests.ps1 -Path tests/Packaging.Tests.ps1`
Expected: PASS 3 tests

- [ ] **Step 5: 提交并跑完整构建**

```bash
git add src/build .github/workflows/build.yml docs/test-checklist.md tests/Packaging.Tests.ps1
git commit -m "feat(build): M7 size governance, dual-boot ISO, split release"
git push && gh workflow run build.yml -f stage=all -f build=26200
```

- [ ] **Step 6: CI 终验 + 一次性真机确认**

CI 自动完成：

```bash
gh workflow run build.yml -f stage=all -f build=26200 -f verify=full
```

期望 `m7` 的全套 probe 通过，另加两个固定回归（都在 CI 里）：
1. 把产物 `boot.wim` 换进原版 Windows 11 ISO 的 `sources\`，`bcdedit /store` 能解析，且 QEMU 冷启动后 `explorer=1`
2. `7z x MICPE.iso.zip.001` 解出的 ISO 的 SHA256 与 Release notes 一致

**人工只做一次**：出成品后你用真机 U 盘启动确认观感与手感，这是唯一需要你花时间的环节。`docs/test-checklist.md` 保留为真机确认表。

---

## Self-Review

**1. Spec coverage**

| Spec 项 | 覆盖任务 |
|---|---|
| G1 双启 ISO / 真 boot.wim | T8（M1 ISO）、T18（终验含替换回归） |
| G2 Explorer 桌面 | T10 |
| G3 UWP 三应用 | T12 |
| G4 网络 | T11（PENetwork 在 T13 注入，DHCP 由 wpeinit） |
| G5 微软拼音 | T11 |
| G6 install.mic 发现 + 自弹 | T15、T17 |
| G7 一键装机 + 空盘引导 DiskGenius | T16、T17 |
| G8 体积 | T4 断言、T18 治理 |
| G9 品牌 | T14 |
| G10 预装软件进 MICPE | T13 |
| §5.1 流水线 | T8、T18 |
| §5.2 仓库结构 | T1–T18 的 Files 段（T9 增加 `src/ci/*`） |
| §5.3 体积预算 | T18 |
| §5.4 装机界面/流程 | T16、T17 |
| §5.4.1 源发现协议 | T15 |
| §5.5 品牌表 | T14 |
| §5.6 目录约定 | T13（含 7-zip 小写断言） |
| §5.7 输入法 | T11 |
| §6.5 参考材料 | T5（白名单）、T13（payload）、T17（PECMD） |
| §6.6 验证闭环 | T9（L3 运行时自验证框架）、T10–T18 各自的"CI 验收"步骤 |
| §8 D1–D8 | D1→T17、D2→T17、D3→T13、D4→已完成、D5→T15、D6/D7→T13、D8→T16（不实现备份） |

**2. Step scan**：每个 Step 都是单一动作（写测试 / 跑测试 / 实现 / 跑验证 / 提交）。没有"TBD"或"处理边界情况"这类空指令。测试步骤都给了断言代码，实现步骤给了签名与关键常量，未预写函数体。

**3. Type consistency**：`Read-Whitelist`/`Export-WimFiles`/`Mount-WimImage`/`Dismount-WimImage`/`Invoke-RegistryScript`/`Import-RegFile`/`Assert-FileSize`/`Assert-True`/`Assert-PathExists`/`Write-Step` 在 T2–T18 中命名一致。`Find-InstallSource` 返回项字段 `Root`/`ImagePath`/`DisplayName`/`HasMarker`/`Broken` 在 T15 定义、T17 消费一致。`Test-TargetSpace` 双参数集在 T16 定义并自测。

**4. Review Focus 对应测试**：
1. 标记存在但映像缺失 → `Discover.Tests.ps1` 的 "reports a marker volume whose image is missing as a broken entry"
2. 空间不足 → `Deploy.Tests.ps1` 的 "requires 15 percent headroom"（提前拒绝）
3. 多索引选择 → `Deploy.Tests.ps1` 的 `Select-DefaultIndex` 两条
4. 目标是镜像/PE 所在卷 → `Deploy.Tests.ps1` 的 `Test-TargetSafety` 三条
5. 卷不可达 → `Discover.Tests.ps1` 的 "skips a root that throws instead of failing the whole scan"

**5. Proportion**：计划 18 个任务，多数 Step 是签名与断言而非函数体；唯一含较大代码块的是测试与常量表，属于"实施者无法自行决定的决策"。M6 的 WCS 界面按 spec 的 ASCII 布局与色值实现，未预写 PECMD 语法细节。
