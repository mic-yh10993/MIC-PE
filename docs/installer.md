# MICPE-Setup 装机工具（M6）

`src/installer/MICPE-Setup.wcs` 是 MICPE 的一键装机工具：PECMD WCS 向导，
单窗口 760×520，Win11 观感（design §5.4）。启动后自动发现装机源、新手
一键装系统；以后也可以把 PE 附带到自封装系统里作 `boot.wim`。

## 技术栈：PECMD WCS

设计已定（design §5.4），本轮确认不重选：本体 <1 MB、零运行时依赖
（WPF 要 .NET FX 4.8，350–500 MB，放不进体积预算）；PECMD 支持自绘窗口、
自定义配色/字体、圆角按钮。WCS 语法是初稿，以 L3 QEMU 运行
（probe.txt + 截图）为准，和 PECMD.INI、Pin-Shortcuts.wcs 同一个口径。

## 用法

```
MICPE-Setup.wcs                       交互式；先发现装机源再显示界面
MICPE-Setup.wcs -auto "<image>"       跳过选择，直接进确认页
MICPE-Setup.wcs -cli -discoveronly    只扫描并把结果写进 probe 文件
MICPE-Setup.wcs -cli -deploy <源> <目标盘>
                                      无界面部署（CI 冒烟路径）
```

开机自弹：`PECMD.INI` 在启动后扫描各卷，找到 `install.mic` 或
`sources\install.wim` 就 `EXEC MICPE-Setup.wcs -auto "<路径>"`，并设标记
只弹一次；没找到就只起桌面。

## install.mic 协议（design §5.4.1）

探盘只认标记文件，不猜：

1. 枚举所有卷（含离线卷，先 `mountvol` 分配盘符）。
2. 卷根存在 `install.mic` → 该卷**就是**装机源卷。`install.mic` 是纯文本
   （UTF-8 或 ANSI 均可，去 BOM 后读第一行）＝ 显示用的系统名，例如
   `MICPE 定制系统 v1`；映像固定位于 `<该卷>\sources\install.wim`。
3. 没有 `install.mic` 的卷，降级匹配：`<卷>\sources\install.wim` →
   `<卷>\install.wim` → `<卷>\sources\install.esd` → `<卷>\*.esd`。
   卷根同时存在 `bootmgr`/`efi` 等 ISO 特征时，判定为挂载的安装介质。
4. 多个命中时全部列进“更换镜像”下拉，按“有 `install.mic`”优先排序。
5. 命中唯一时自动选中并把该卷 + 首行名字填进界面，同时弹出装机工具。

`install.mic` 协议也要写进 README，让第三方封装也能用。

## 执行步骤（向导内自动串行）

1. 二次确认（显示磁盘号、分区号、将清空的分区、镜像路径）。
2. 卸载目标卷 → 格式化 NTFS（卷标与用户选的一致）。
3. `dism.exe /English /Apply-Image /ImageFile:<wim> /Index:<index> /ApplyDir:<target>`（esd 也走 DISM；gho 不做）。
4. 无人值守（可选，默认不写）：未勾选则目标系统正常进 OOBE；勾选则把
   选定的 `autounattend.xml` 写到目标分区根目录。
5. `bcdboot <target>\Windows /s <boot> /f ALL`（UEFI+BIOS 双写）。
6. 完成页：重启 / 关机 / 查看日志。

## 校验规则（Review Focus）

| # | 规则 | 落点 |
|---|---|---|
| 1 | 卷根有 `install.mic` 但映像缺失 → 明确报“标记存在但映像缺失”，绝不静默跳到下一个卷或开始安装 | `Find-InstallSource` 返回 `Broken=$true` 的条目；`.wcs` 的 `AddSource` 同样处理 |
| 2 | 空间不足 → apply 前拒绝 | `Test-TargetSpace`（索引未压缩大小 ×1.15）；`.wcs` 应用前调它 |
| 3 | 多索引 → 列出版本让用户选，默认选中与 `install.mic` 首行匹配的那个，匹配不到默认第一个 | `Select-DefaultIndex`（全等优先 → 包含 → 第一个） |
| 4 | 目标卷不得是 PE 所在卷或镜像所在卷 | `Test-TargetSafety`；`.wcs` 的 `CheckTarget` 同样处理 |
| 5 | 坏卷跳过，不整体失败 | `Find-InstallSource` 每个根独立 try/catch，只写警告 |

## 配置（MICPE-Setup.ini）

| 键 | 值 |
|---|---|
| `LogDir` | `X:\Program Files\MICPE\logs` |
| `MinImageBytes` | `536870912`（512 MB；小于此的映像不认） |
| `DiskGenius` | `X:\Program Files\DiskGenius.exe` |
| `UnattendDir` | `X:\Program Files\WinNTSetup\unattend` |

## 无人值守模板

直接复用预装包里现成的模板，不自己发明格式：

| 文件 | 用途 |
|---|---|
| `Program Files\WinNTSetup\unattend\Win10_x64.xml` | 全自动：zh-CN、Administrator 空密码自动登录、跳 EULA/OOBE/联网账户/无线设置 |
| `Program Files\WinNTSetup\unattend\Win7-11-Select.xml` | 通用选择式：启动时弹出填写用户名/计算机名/工作组 |

界面上也可浏览任意 `*.xml`；工具只做 `%变量%` 替换与写入，不解析语义。
默认不勾选“使用无人值守”。

## 新手保障

- 默认值就是“最可能正确”的那个：自动挑最大的 NTFS 数据分区当系统盘、
  自动挑 EFI 分区当引导。
- 空盘不报死错，而是给明确的下一步按钮（打开 DiskGenius）；分好区后点
  “重新扫描”即可，无需重启或重开工具。
- 危险操作二次确认，确认框里用**具体数字**而不是术语。
- 失败时把 dism/bcdboot 的输出落到 `X:\MICPE\logs\setup-<时间>.log`，
  界面上给“复制日志路径”按钮。
- 不提供“删除所有分区/清空磁盘”这类一键毁灭按钮（分区交给 DiskGenius，
  它是用户主动发起、可见的独立操作）。

## probe 键（design §6）

`.wcs` 的 `-cli` 模式把结果写进 `%MICPE_PROBE_FILE%`（默认
`X:\micpe-probe.txt`），供 CI 读取：

| 键 | 含义 |
|---|---|
| `installer_scan=1` | `-cli -discoveronly` 找到至少一个装机源 |
| `installer_source=marker` / `fallback` | 命中的来源类型 |
| `installer_name=<名>` | `install.mic` 首行显示名 |
| `installer_path=<路径>` | 命中的映像全路径（供 probe.cmd 的部署步使用） |
| `installer_deploy=1` | `-cli -deploy` 应用 + 引导修复成功（CLI 模式默认用第一个索引） |
| `installer_boot=1` | 目标盘上存在 `EFI\Microsoft\Boot\BCD`（probe.cmd 在部署后检查） |

## 已知缺口（M7 前必须处理）

- **应用工具已定为 DISM（M7 决定，缺口关闭）**：`Invoke-Deploy` 与 `.wcs`
  的 `apply` 步骤原先调 `wimlib-imagex`，但它只是构建主机上的工具，从不
  进 PE。M7 改走 WinPE 自带的 `dism.exe /Apply-Image`（已在出货 boot.wim
  里两个索引都核实存在；`/Get-WimInfo` 负责版本查询，`/English` 钉死
  英文输出以便解析）。不走“把 wimlib 放进 payload”的路线：那要多带
  `wimlib-imagex.exe` + `libwim-15.dll`，还会让已备好的 payload-v1 归档
  哈希 pin 作废。未验证：`.esd` 的 apply 是同一条 DISM 命令，Win10+
  实践中可用，但本次 L3 未覆盖；分卷 `.swm` 源发现器不返回、向导也不
  接受，故无 `/SWMFile` 分支；`/ScratchDir` 未加，若 L3 报 scratch 空间
  错误再指到目标盘。
- **QEMU 验收 harness 已接线（M7）**：build.yml 的 `Prepare data disks`
  步骤（仅 `verify=full` 且 stage ∈ {m6, m7, all}）用 diskpart 建 VHDX
  （分区 + NTFS 格式化 + 拷文件）再 `qemu-img convert` 成 plan 要求的
  qcow2：disk2 空白 NTFS、disk3 标记 + 真实 install.wim 副本、disk4
  无标记 + 真实 install.wim 副本、disk5 空白 64 GB；`Test-Stage.ps1`
  经 `-DataDisks` 透传；`probe.cmd` 在找到源时调 `-cli -deploy` 装到
  空闲最大的卷（即 disk5），写 `installer_deploy=1` 并检查 BCD 写
  `installer_boot=1`。数据盘验证超时 120 分钟（TCG 下 DISM apply 很慢）。
  未验证：整条链路一次都没在 CI 跑过（m6/m7 构建被缺失的 payload
  Release 挡住，见下一条）；disk2-only 的 `installer_scan=nopartition`
  场景合跑里观测不到，需单独跑一次才能验证。
- **m6/m7 完整构建被缺失的 payload Release 挡住**：`Invoke-PayloadStep`
  用 `gh release download` 从 `payload-v1` / `chrome-v1` / `office-v1`
  拉资产，三个 tag 在 GitHub 上都不存在（2026-11-17 API 实测 404）。
  等用户拍板发不发这三个 Release；在此之前 stage m5/m6/m7 的 Build
  会在 payload 步骤失败，能实际跑通的最高完整构建是 stage m4。
- `.wcs` 的 PECMD 语法是初稿，未经 PECMD 实际解析；L3 QEMU 运行时以
  probe.txt + 截图为准。
