# MICPE 设计文档

- 日期：2026-11-15
- 作者：SYSTEM-Intel-MIC（项目所有者）+ 实施方
- 状态：待批准

## 1. 意图与为什么

MICPE 是一张**装机维修盘**：从 U 盘/光盘启动，进一个能联网、能轻量办公上网的 Windows 11 桌面，用来装系统、备份、修复、应急上网。不是随身系统，不做持久化。

同时它承担第二职责：一张**新手也能一键装系统**的盘。开机自动扫描所有卷找 `sources\install.wim`，找到就默认选中并自动弹出装机工具。

第三个约束来自未来：这个 `boot.wim` 之后可能被塞进作者自己封装的系统 ISO 里当 `boot.wim` 用。所以产物必须是**结构合法的 boot.wim，且不依赖 ISO 根目录的任何外部文件**。

## 2. 目标与非目标

### 目标（v1 必须达成）

| # | 目标 | 验收方式 |
|---|---|---|
| G1 | ISO 双启（BIOS + UEFI），`boot.wim` 直接可启动 | QEMU/VMware 冷启动进桌面 |
| G2 | 原生 Explorer 桌面、任务栏、开始菜单可用 | 进桌面后能用「此电脑」浏览磁盘 |
| G3 | UWP 原生可运行（照片、新版媒体播放器、计算器） | 三个应用都能启动、能打开文件 |
| G4 | 有网络（有线 DHCP + PENetwork 兜底）、能上网 | 打开浏览器加载网页 |
| G5 | 微软拼音输入法可用 | 能切换并输入中文 |
| G6 | 装机工具按 `install.mic` 标记（降级：`sources\install.wim`）自动发现装机源并开机自弹 | 带标记的卷上启动即弹窗且已选中该源 |
| G7 | 装机工具能一键装系统（选分区→格式化→应用→引导），空盘时引导去 DiskGenius | 建好分区的虚拟盘装完能重启进 OOBE |
| G8 | 体积 `boot.wim` ≤ 3 GB（目标 ≤2.6 GB），ISO ≤3.2 GB | `dism /Get-WimInfo` 报的 Size |
| G9 | 品牌最小集：壁纸、OEMInformation、winver 归属、OEM logo、SupportURL | `winver` 与「系统信息」显示正确 |
| G10 | 预装软件装进 MICPE 自身（`Program Files\MICPE` 含 PENetwork，其余平铺在 `Program Files`） | PE 内目录与桌面快捷方式存在，且目标系统不含这些工具 |

### 非目标（v1 不做）

- 不做 ARM64
- 不做持久化/用户配置文件保存
- 不做微软账户登录、不做 Store 下载安装（UWP 只到"能运行本地已注册应用"）
- 不做驱动库大而全（只做内置存储/网卡兜底 + 可选外部驱动目录）
- 不做多语言（只 zh-CN）
- 不做 BitLocker/Defender（PE 无此能力）
- 不做过度品牌化（只有第 9 条那几项）

### 反目标（做到也算失败）

- 为了 UWP 把体积做到 5 GB 以上，失去"装机盘"的便携意义
- 用了第三方闭源 shell（WinXShell 等）替代 Explorer——用户明确要原生
- 装机工具需要用户理解"引导分区""映像序号"才能用
- 公开仓库里出现不可再分发的二进制（违反 GPL 洁净度或许可）

## 3. 约束

| 类别 | 约束 |
|---|---|
| 构建环境 | 仅 GitHub Actions 免费 Hosted runner，`windows-2025`（Server 2025，26100），单 job ≤360 分钟 |
| 内存 | `boot.wim` 全量进 RAM 盘 → 目标机内存 ≥ 4 GB |
| 体积 | `boot.wim` ≤ 3 GB（硬顶），目标 ≤2.6 GB |
| 发布 | 单个 Release asset ≤ 2 GB → ISO 必须 7z 分卷 |
| 仓库 | 单文件 ≤100 MB → 三个包分别独立 Release 资产：`payload-v1`（预装软件 53 MB）、`chrome-v1`（Chrome MSI 157 MB）、`office-v1`（Office 2016 绿色版 162 MB） |
| 许可 | 本仓库 GPL-3.0；微软系统文件、PENetwork、PECMD、DiskGenius 等不入 git |
| 语言 | 只 zh-CN（含微软拼音） |
| 作者信息 | 作者 SYSTEM-Intel-MIC；OEM 型号 SYSTEM-Intel-MIC；SupportURL = https://space.bilibili.com/1978487514 |

## 4. 方案选择（已定）

### 曾考虑的三种基底

| 方案 | 说明 | 结论 |
|---|---|---|
| A. ADK 官方 WinPE（copype + WinPE-OC） | 微软支持、体积小 | **否**。AppX/StateRepository/Explorer 依赖是网状而非列表状，补不全，UWP 无解 |
| B. `install.wim` 裁剪后改名 `boot.wim`（Edgeless 路线） | 文件天然齐全，UWP 零适配 | **否**。不是真正的 PE 结构，塞回封装系统当 boot.wim 有兼容风险，与"boot.wim 兼容性最好"相悖 |
| **C. ISO 的 `boot.wim` 作基底 + 从 `install.wim` 按白名单提取** | 真 boot.wim 结构，按需搬入 shell/UWP 栈 | **采纳**。用户指定，且是唯一同时满足"真 boot.wim"和"有 UWP"的路 |

### 为什么用 boot.wim 而不是 winre.wim

参考教程用 `winre.wim`（体积小、结构干净）。我们选 ISO 的 `sources\boot.wim` 索引 1：

- 它本身就是"安装介质"的 boot.wim，塞回封装系统时结构一致（G 约束直系）
- 自带 setup 相关组件，装机工具后续可复用
- 代价是基底大 ~100 MB，从 SOFTWARE hive 替换后的净差可接受

### 关键技术手法（来自参考教程，逐条验证过）

1. **SOFTWARE hive 整体替换**：`install.wim` 的 `Windows\System32\config\SOFTWARE` 直接覆盖 boot.wim 的同名文件。这是 UWP 能跑的第一块基石——PE 精简 hive 里根本没有 `AppX`/`AppModel`/`StateRepository`/`Windows.UI` 的注册项，靠补丁补不进去。
2. **按白名单从 install.wim 提取文件**：分四批（CmdPE 基础 → Explorer → WOW64 运行库 → DWM/组件/输入法/UWP）。用 `wimlib-imagex extract` 支持通配符，比 DISM 逐文件快得多。
3. **`ProgramData\Microsoft\Windows\AppRepository` 目录必须存在**（哪怕是空的），StateRepository 服务靠它初始化。
4. **`Windows\SystemTemp` 目录必须存在**，否则照片查看器报"文件损坏"。
5. **`DeviceSetupManager.dll` 需 patch** 才能让"安全弹出 USB"工作（可选，v1 降级为不做，用磁盘管理弹出）。
6. **注册表三阶段合并脚本**（1-Build / Explorer / Addons），按 pass 顺序执行。

## 5. 设计

### 5.1 构建流水线（GitHub Actions）

```
workflow: .github/workflows/build.yml
  job: build (windows-2025, timeout 360)
   1. checkout
   2. 清理 runner 无用大件（Android/R/PostgreSQL/Selenium 等）→ 腾 ~15 GB
   3. 选最大空闲盘做 WORK
   4. 拉 UUP dump（25H2 amd64 zh-CN）→ uup-converter-wimlib → Windows11.iso
      └ 复用 winbuild 的 Get-UupIso.ps1 逻辑，但只取 install.wim 与 boot.wim
   5. 挂载 install.wim(Pro) 与 boot.wim(索引1) 到不同目录
   6. 应用文件白名单（wimlib extract，四批）
   7. 替换 SOFTWARE hive，合并 SYSTEM/DEFAULT 补丁
   8. 注入预装软件到 Program Files\MICPE + 桌面快捷方式
   9. 注入品牌资产（壁纸、oemlogo.bmp、注册表 OEMInformation/winver）
  10. 注入启动脚本（startnet.cmd → PECMD.INI → 装机工具探测）
  11. 提交并导出 boot.wim（LZX 压缩），体积断言 ≤3 GB
  12. oscdimg 生成 ISO（UDF，BIOS+UEFI 双启）
  13. 7z 分卷 → Release
```

**为什么不用 ADK**：只需要 `oscdimg.exe`。`copype`/`MakeWinPEMedia` 全部不用。ADK 安装 2 GB、耗时 5–8 分钟，也走缓存避免重复。

**为什么 UUP dump 而不是微软 ISO**：用户指定，且能锁定具体内部版本、可控语言与版本 SKU，CI 全过程无需人工登录。

### 5.2 仓库结构

```
MIC-PE/
├── .github/workflows/build.yml      # 主构建
├── .github/workflows/payload.yml    # 一次性：把大二进制打成 Release 资产
├── LICENSE                          # GPL-3.0
├── README.md
├── docs/
│   ├── design.md                    # 本文档
│   └── test-checklist.md            # 冒烟清单
├── src/
│   ├── build/
│   │   ├── Build-Micpe.ps1          # 主控脚本（步骤编排）
│   │   ├── Get-BaseImage.ps1        # UUP → ISO → 拆 wim
│   │   ├── Merge-Registry.ps1       # hive 挂载/补丁/卸载
│   │   ├── Add-Payload.ps1          # 预装软件 + 快捷方式
│   │   └── New-Iso.ps1              # oscdimg 封装
│   ├── filelists/
│   │   ├── 10-cmdpe.txt             # 四批白名单（每行一个 install.wim 内路径，支持通配）
│   │   ├── 20-explorer.txt
│   │   ├── 30-runtimes.txt
│   │   └── 40-components.txt
│   ├── registry/
│   │   ├── 10-pe-base.reg
│   │   ├── 20-explorer.reg
│   │   ├── 30-components.reg
│   │   └── 40-brand.reg
│   ├── shell/
│   │   ├── startnet.cmd
│   │   ├── PECMD.INI
│   │   └── Pin-Shortcuts.wcs
│   └── installer/                   # 装机工具（PECMD WCS）
│       ├── MICPE-Setup.wcs
│       ├── MICPE-Setup.ini
│       └── lang/zh-CN.txt
└── assets/
    ├── logo.bmp
    └── wallpaper.jpg
```

### 5.3 体积预算（硬顶 3 GB）

| 部分 | 预估（WIM 压缩后） | 说明 |
|---|---|---|
| boot.wim 基座（26200 zh-CN） | 460 MB | 含中文字体 |
| SOFTWARE hive 替换 | +90 MB | 全量 hive |
| Explorer + twinui + WOW64 + DWM | +420 MB | 白名单 20/30/40 |
| UWP 栈（AppX/StateRepository/XAML） | +180 MB | |
| Photos + MediaPlayer + 依赖框架 | +300 MB | VCLibs/.NET Native/WinUI |
| 微软拼音输入法 | +130 MB | |
| 预装软件（53 MB → 解压约 120 MB） | +70 MB | |
| Chrome（安装后） | +280 MB | 走 Release 资产 |
| Office 2016 绿色版 | +330 MB | 走 Release 资产，可选开关 |
| 启动脚本/品牌/杂项 | +20 MB | |
| **合计** | **≈ 2.28 GB** | 余量 320 MB |

超限时的降级顺序（按此顺序砍，不需要重新讨论）：Office → Chrome → Photos → Media Player。每砍一项都要在 Release 说明里写明。

### 5.4 装机工具（MICPE-Setup）

**技术栈：PECMD WCS**。理由：

- 复用 DSI 成熟逻辑，开发周期从"周"降到"天"
- 本体 <1 MB，零运行时依赖（WPF 要 .NET FX 4.8，350–500 MB，放不进预算）
- PECMD 支持自绘窗口、自定义配色/字体、圆角图片按钮，能做出干净的 Win11 观感

**启动流程**：

```
startnet.cmd
  └ 初始化 VHD/网络/临时目录
  └ PECMD.EXE LOAD X:\Program Files\MICPE\PECMD.INI
       └ 探盘：枚举所有卷（离线卷先分配盘符）
       └ 找 <卷>\sources\install.wim | <卷>\install.wim | *.esd | *.wim(>2GB)
       └ 命中 → exec MICPE-Setup.wcs -auto "<路径>"
       └ 未命中 → 只起桌面
```

**界面（Win11 观感）**：

- 背景 `#F3F3F3`，卡片 `#FFFFFF` + 8 px 圆角描边模拟
- 主色 `#0067C0`（Win11 强调蓝），危险操作 `#C42B1C`
- 字体 `Microsoft YaHei UI`（zh-CN 环境用 `Microsoft YaHei` 兜底）
- 单页布局，不用多页面跳转：

```
┌──────────────────────────────────────────────────────────────┐
│  MICPE 一键装机                              SYSTEM-Intel-MIC │
├──────────────────────────────────────────────────────────────┤
│  ① 系统镜像                                                    │
│  ┌────────────────────────────────────────────────────────┐  │
│  │ D:\sources\install.wim   ·  MICPE 定制系统 v1  · 1 个版本│  │
│  │                     [ 更换镜像 ] [ 重新扫描 ]  [ 分区 ]│  │
│  └────────────────────────────────────────────────────────┘  │
│  版本： [ MICPE 定制系统 ▾ ]                                   │
│                                                              │
│  ② 安装到                                                     │
│  ┌────────────────────────────────────────────────────────┐  │
│  │ 磁盘 0 · NVMe 512 GB                                   │  │
│  │   分区 1  EFI        100 MB   保留          [引导]     │  │
│  │   分区 2  MSR         16 MB   保留                     │  │
│  │   分区 3  Windows     476 GB  NTFS          [系统 ▸]   │  │
│  └────────────────────────────────────────────────────────┘  │
│  ☑ 格式化系统分区    ☑ 自动修复引导    ☑ 写入 OEM 信息          │
│  ☐ 使用无人值守        [ 编辑 / 选择 xml ]                     │
│                                                              │
│  ③ 就绪        [        ⏵ 开始安装        ]                   │
└──────────────────────────────────────────────────────────────┘
```

`[ 分区 ]` 按钮直接**拉起 DiskGenius**（`X:\Program Files\DiskGenius.exe`）。空盘/未分区的情况，界面在分区列表处显示提示："未找到可安装的分区 · [ 打开 DiskGenius 分区 ]"，用户分好区后点 `[ 重新扫描 ]` 即可，无需重启或重开工具。

**执行步骤（向导内自动串行）**：

1. 二次确认（显示磁盘号、分区号、将清空的分区、镜像路径）
2. 卸载目标卷 → 格式化 NTFS（卷标与用户选的一致）
3. `dism.exe /English /Apply-Image /ImageFile:<wim> /Index:<index> /ApplyDir:<target>`（esd 也走 DISM；gho 不做）
4. **无人值守（可选，默认不写）**：未勾选则目标系统正常进 OOBE，用户自己建账户；勾选则把选定的 `autounattend.xml` 写到目标分区根目录
5. `bcdboot <target>\Windows /s <boot> /f ALL`（UEFI+BIOS 双写）
6. 完成页：重启/关机/查看日志

**无人值守模板从哪来**：直接复用预装包里现成的模板，不自己发明格式：

| 文件 | 用途 |
|---|---|
| `Program Files\WinNTSetup\unattend\Win10_x64.xml` | 全自动：zh-CN、Administrator 空密码自动登录、跳 EULA/OOBE/联网账户/无线设置、`ProtectYourPC=3` |
| `Program Files\WinNTSetup\unattend\Win7-11-Select.xml` | 通用选择式：启动时弹出填写用户名/计算机名/工作组，`process=1` |
| 用户自选 | 界面上可浏览任意 `*.xml`；工具只做 `%变量%` 替换与写入，不解析语义 |

（注：Dism++ 目录里没有 unattend 模板，它的 `Config\Data.xml` 是清理/优化规则库。现成模板只有 WinNTSetup 这 3 个。设计按此为准。）

**新手保障**：

- 默认值就是"最可能正确"的那个：自动挑最大的 NTFS 数据分区当系统盘、自动挑 EFI 分区当引导
- 空盘不报死错，而是给一个明确的下一步按钮（打开 DiskGenius）
- 危险操作二次确认，确认框里用**具体数字**而不是术语
- 失败时把 dism/bcdboot 的输出落到 `X:\MICPE\logs\setup-<时间>.log`，界面上给"复制日志路径"按钮
- 不提供"删除所有分区/清空磁盘"这类一键毁灭按钮（分区交给 DiskGenius，它是用户主动发起、可见的独立操作）

### 5.4.1 装机源发现协议（`install.mic`）

这是本项目的私有约定，也是"新手一键"的关键：**探盘只认标记文件，不猜**。

规则：

1. 枚举所有卷（含离线卷，先 `mountvol` 分配盘符）
2. 卷根存在 `install.mic` → 该卷**就是**装机源卷
   - `install.mic` 是纯文本（UTF-8 或 ANSI 均可，去 BOM 后读第一行）＝ 显示用的系统名，例如 `MICPE 定制系统 v1`
   - 映像固定位于 `<该卷>\sources\install.wim`
3. 没有 `install.mic` 的卷，降级匹配（兼容原版微软 ISO 与旧习惯）：
   - 优先级 1：`<卷>\sources\install.wim`
   - 优先级 2：`<卷>\install.wim`、`<卷>\sources\install.esd`、`<卷>\*.esd`
   - 该卷根同时存在 `bootmgr`/`efi` 等 ISO 特征 → 判定为"挂载的安装介质"，同样算命中
4. 多个命中时全部列进"更换镜像"下拉，按"有 `install.mic`"优先排序
5. 命中唯一时**自动选中并把该卷 + 首行名字填进界面**，同时弹出装机工具（G6）

设计意图（对应所有者的用法）：他自己封装的系统 ISO 与原版微软 ISO **同构**，只是把安装程序、映像、预装环境换成自己的。所以：

- 他的 ISO 里会带 `install.mic` + `sources\install.wim`
- 把 MICPE 的 `boot.wim` 换进那个 ISO 后，MICPE 启动即认到 `install.mic`，直接一键装自己的系统
- 用户拿原版微软 ISO + Ventoy 时，没有 `install.mic`，走规则 3 也能正常识别

`install.mic` 协议要写进 README，让第三方封装也能用。

### 5.5 品牌与 OEM

| 项 | 位置 | 值 |
|---|---|---|
| 桌面壁纸 | `Windows\Web\Wallpaper\Windows\img0.jpg`（覆盖） | `assets/wallpaper.jpg` |
| OEM Logo | `Windows\System32\oemlogo.bmp` | `assets/logo.bmp` |
| `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\OEMInformation` | Manufacturer / Model / SupportURL / SupportProvider / Logo | `MICPE` / `SYSTEM-Intel-MIC` / `https://space.bilibili.com/1978487514` / `SYSTEM-Intel-MIC` / `%SystemRoot%\System32\oemlogo.bmp` |
| `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion` | RegisteredOwner / RegisteredOrganization | `SYSTEM-Intel-MIC` / `MICPE` |
| 计算机名 | 启动时随机 | `MICPE-XXXX` |
| 桌面注释 | `Program Files\MICPE\说明.txt` | 版本、构建号、作者、B 站地址 |

不做：开机动画、登录界面换图、系统属性里的大段文案、捆绑主页。

### 5.6 预装软件与目录约定

**重要澄清**：下列软件是预装进 **MICPE 这个 PE 环境本身**（开机后 `X:\` 上就能用），**不是**装进被安装的目标系统。目标系统拿到的是纯 Windows 映像，不含这些工具。

`X:\Program Files\MICPE\` 结构（作者已定的约定，不另发明）：

```
Program Files\MICPE\
├── PENetwork\            # 原样（作者已有配置）
├── MICPE-Setup\          # 本项目的装机工具（wcs + ini + lang）
├── 说明.txt
└── logs\                 # 运行时日志
```

其余预装软件**保持作者给的平铺结构**，直接在 `Program Files\` 下：

```
Program Files\
├── 7-zip\        # 注意小写，GhostCGI/cgi.ini 硬编码调用
├── Dism++\  Everything\  GhostCGI\  Imagine\  Snapshot\  WimTools\  WinNTSetup\
├── DiskGenius.exe  BOOTICE.exe  cpuz.exe  MEMTEST.EXE  WinosInfo.exe  GoHash.EXE
```

桌面快捷方式：装机工具、DiskGenius、GhostCGI、Dism++、WinNTSetup、7-Zip、Everything、PENetwork、Chrome、Office（若启用）。

Chrome（MSI，安装到 `X:\Program Files\Google\Chrome`）与 Office 2016 绿色版（解压到 `X:\Program Files\Office2016`）也只在 MICPE 内可用，同样不进目标系统。

### 5.7 输入法

只装微软拼音：从 install.wim 提取 `InputMethod\*`、`ime\*`、`msctf*`、`TextInputFramework` 等（教程白名单里有完整清单），注册表走 components pass。默认输入法设为拼音，`Ctrl+Space` 切换。

### 5.8 体积与内存的取舍说明

- `boot.wim` 全量进 RAM：2.3 GB 的 WIM ≈ 开机占 2.3–2.6 GB 内存
- 目标机内存 4 GB 可用，2 GB 机器**不保证**能进桌面（会在 README 写明）
- 不在 v1 做"外置 WIM 挂载"优化：它会让产物不再是单文件 boot.wim，破坏第 3 个约束

## 6. 分期交付

| 期 | 内容 | 通过标准 |
|---|---|---|
| **M1** | 管线骨架：UUP → ISO → 拆 wim → 空 boot.wim 重封 → ISO | 产物能进 cmd 提示符 |
| **M2** | Explorer 桌面（白名单 20 + SOFTWARE hive + 注册表 20） | 进桌面，能开此电脑 |
| **M3** | 网络 + 输入法 + 运行库（WOW64） | ping 通、能输入中文、32 位 exe 能跑 |
| **M4** | UWP 栈 + 照片 + 媒体播放器 + 计算器 | 三个 UWP 都能启动 |
| **M5** | 预装软件 + 桌面快捷方式 + 品牌 | Program Files\MICPE 完整 |
| **M6** | 装机工具 + 自动探测自弹 + 一键装 | 空盘装完能进 OOBE |
| **M7** | 体积治理 + ISO 双启 + 分卷 Release + 清单 | 全部 G 目标达成 |

每期都有独立 workflow 输入开关（`stage: m1..m7`），失败可回退到上一期产物。

## 6.5 参考材料的位置与可用性（审查补充）

所有参考材料已解包并**持久保存到 `/root/micpe-ref/`**（不在临时目录，构建与后续会话都可读）：

| 材料 | 路径 | 内容与可用性 |
|---|---|---|
| UWP PE 四阶段教程 | `/root/micpe-ref/参考文献(可只阅读精简txt）/5/uwppe教程.txt` | 1402 行。**白名单已可直接转成清单**：CmdPE 77 条、Explorer 144 条、运行库 305 条、组件 175 条（去重后），其中 87 条含通配符。这是 M2–M4 的主要输入。 |
| ADK 正统路线 | `…/1/精简版本.txt`（692 行）、`…/4/精简.txt`（139 行） | copype + WinPE-OC 组件包清单。仅作兜底，不进主路径。 |
| 24H2 精简经验 | `…/2/精简.txt`、`…/3/精简.txt` | 内存占用与体积参考（2 GB 内存不够用，印证 §3 的 4 GB 要求）。 |
| DSI 装机源码 | `/root/micpe-ref/参考代码/` → 解包到 `DSI-安装备份-源码/DSI-安装备份.WCS`（98 KB，UTF-8 BOM，CRLF） | **可用**。已确认包含：卷/分区表格、`wimlib-imagex apply`、`bcdboot`、格式化、无人值守、驱动导入/导出、错误处理。M6 直接复用其函数结构。 |
| DSI 附带的 PECMD | `DSI-安装备份-源码/make/PECMD.EXE` | 可直接作为运行时（许可：PECMD 为免费软件，需在 README 注明来源，不入 GPL 覆盖范围）。 |
| UUP 构建脚本 | `/tmp/winbuild/scripts/Get-UupIso.ps1`（2712 行）+ 其 workflow | **可直接裁剪复用**。只保留 UUP 下载 → 转换 → 取 install.wim/boot.wim 的部分，去掉 unattend/Office/MAS/debloat。 |
| 预装软件树 | `/root/micpe-ref/PE预装软件/直接塞入programfiles/` | **纯绿色、无需安装**：9 目录 + 6 单文件，全部 PE32/PE32+ 独立 exe，`ls` 无 setup/install/vc_redist。唯一例外是 `GhostCGI/cgi.ini` 调用 `%ProgramFiles%\7-ZIP\7z.exe`（注意它写的是 `7-ZIP` 大写），所以 **7-zip 必须落在 `Program Files\7-zip`**。`WinNTSetup/unattend/` 自带无人值守模板，可复用。 |
| 品牌资产 | `/root/micpe-ref/品牌化/` | `logo.bmp` 120×120×24bpp（直接符合 OEM logo 要求）、`wallpaper.jpg` 1920×1080。 |
| 大件安装包 | `/root/micpe-ref/PE预装软件/安装包/` | `googlechromestandaloneenterprise64.msi` 157 MB（仅此一个需要安装）、`Office.7z` 162 MB（解压 474 MB 的 Office2016 绿色版）。两者**都超 GitHub 单文件 100 MB 上限**，各自独立发 Release 资产（`chrome-v1` / `office-v1`），与预装软件包 `payload-v1` 分开，可单独更新。 |

结论：白名单不用反向工程，M2–M4 的工期可估；DSI 逻辑可复用，M6 工期可估；预装软件是纯拷贝，M5 无需安装步骤（Chrome 除外）。

## 6.6 验证方式：CI 端到端自验证（所有者要求尽量不占人工时间）

所有者明确要求"尽可能在 CI 里验证，不要占我时间"。所以本项目的验收改为 **CI 自验证为主，人工只抽查截图**。

Hosted `windows-2025` 没有嵌套虚拟化，但 **QEMU 的 TCG 软件模拟可用**。验证必须加 `-cpu max`：默认 qemu64 CPU 缺 25H2 内核要的指令集，guest 在 WIM 读完约 1 分钟后三重故障（本地 TCG 复现，run 44062469206），`-cpu max` 后内核才能起来。配合下面两个机制，就能机器判定"PE 真的起来了"：

**机制一：`vvfat` 回写通道（核心）**

QEMU 可以把宿主机目录直接映射成一块 FAT 磁盘：

```
-drive file=fat:rw:<WORK>\share,format=raw,media=disk,if=ide
```

PE 里它表现为一个普通盘符（如 `E:`）。启动脚本把自检结果写成文本文件进去，CI 直接读宿主机目录里的同名文件。**这是一条从 PE 内部到 CI 的双向通道**，无需 OCR、无需串口、无需人眼。

**机制二：QEMU monitor 截图**

QEMU 以 `-monitor tcp:127.0.0.1:4444,server,nowait` 启动，CI 连上后发 `screendump <path>` 得到 PPM，再用 .NET `Bitmap` 转 PNG 并计算"非黑像素比例"，判定桌面是否真的绘制出来了（黑屏/只有鼠标时比例极低）。

**`src/ci/probe` 自检脚本（PE 内运行）**

启动后由 `PECMD.INI` 调起，逐项检测并写 `E:\micpe-probe.txt`：

| 检查项 | 判定方法 |
|---|---|
| `boot` | 脚本正在运行这一事实本身 |
| `explorer` | `FIND explorer.exe` 进程存在 |
| `shell_ready` | `%SystemRoot%\explorer.exe` 运行 ≥ 15 秒未退出 |
| `dwm` | `dwm.exe` 进程存在 |
| `network` | `ipconfig` 出现有效 IPv4（可 DHCP 超时则记 `pending`，不算失败） |
| `ime` | 注册表 `Keyboard Layout\Preload` 含 `0804` |
| `uwp_appx` | `dism /online /Get-ProvisionedAppxPackages` 或注册表 `AppxAllUserStore` 计数 > 0 |
| `uwp_launch` | 依次 `explorer shell:AppsFolder\<AppUserModelId>` 启动，3 秒后 `FIND` 进程在（照片/媒体播放器/计算器各自一行） |
| `payload` | 关键路径存在性（`Program Files\MICPE\PENetwork\PENetwork.exe` 等） |
| `brand` | 注册表 OEM 六个值 + `oemlogo.bmp` 存在 |
| `installer_scan` | 跑 `MICPE-Setup.wcs -cli -discoveronly`，输出发现的源列表 |
| `installer_deploy` | 跑 `-cli -deploy <源> <目标盘>`，输出 apply 与 bcdboot 退出码 |
| `size` | `boot.wim` 与 ISO 体积 |

每行格式 `key=value`，CI 用 `tests/Assert-Probe.ps1` 按阶段声明期望值。

**三档验证**

| 档 | 内容 | 何时跑 | 依赖 |
|---|---|---|---|
| L1 静态 | Pester 单测、语法检查、清单/注册表文件可解析 | 每次 push | 无 |
| L2 结构 | WIM 可挂载、体积断言、注册表键存在、清单文件落地、ISO 可回读、`boot.wim` 塞回原版 ISO 后 BCD 可解析 | 每次构建 | 无 |
| L3 运行时 | QEMU 冷启动 + probe 回写 + 截图 + 非黑像素判定 | 每次构建（可关） | L2 通过 |

`workflow` 输入 `verify: full|static|none` 控制 L3：`full` 默认开；`static` 只跑 L1/L2（省时间）；`none` 仅出产物。

**预期耗时**（TCG，4 vCPU，`-m 4096`）：M1（约 500 MB wim）3–6 分钟；M4/M5（约 2.3 GB）12–25 分钟。仍在 360 分钟上限内。

**CI 判定失败时的可诊断性**：每次 L3 都上传 `probe.txt`、`shot*.ppm`、`qemu.log`、`serial.log` 四个 artifact。失败原因从 `probe.txt` 的 `key=value` 直接可读，不需要复现。

**人工只剩两件事**：① 出成品后你自己在真机/U 盘上验一次；② 想看观感时下载 artifact 里的 `shot.ppm`。M1–M7 的迭代不再需要你在虚拟机上跑。

## 7. 风险与对策

| 风险 | 概率 | 对策 |
|---|---|---|
| UWP 起不来（0x80073CF9 / 0x80270254） | 高 | 先做 M2/M3 打底，M4 单独迭代；保留教程的原始注册表脚本顺序；每次只改一个变量 |
| Explorer 起不来（黑屏只有鼠标） | 中 | 保留 cmd 兜底；PECMD 检测 explorer 进程，失败则起 cmd 并落日志 |
| 体积超 3 GB | 中 | 5.3 的降级顺序自动执行，并在 Release 说明标注 |
| 260 分钟超时 | 中 | UUP 下载/转换拆成独立 job 用 artifact 传递；ADK/ISO 全部缓存 |
| Z 盘盘符冲突/离线卷 | 中 | 探盘前统一 `mountvol` 分配，用卷 GUID 而非盘符记录 |
| boot.wim 塞回封装系统不认 | 低 | M1 就把"产物当 boot.wim 塞进原版 ISO"作为固定回归项 |
| 第三方二进制许可 | 中 | 全部走 Release 资产或 CI 下载，git 里只有脚本与清单；README 列明来源与许可 |

## 8. 已确认的决策（所有者已答复 2026-11-15）

| # | 决策 | 结论 |
|---|---|---|
| D1 | 空盘如何安装 | 装机工具**不接管分区**。未找到可用分区时提示用户点「分区」按钮**拉起 DiskGenius**，分好区后点「重新扫描」再选分区安装。§5.4 已按此更新。 |
| D2 | 无人值守 | **可选**。默认不写、目标系统正常进 OOBE；勾选后用现成模板（`WinNTSetup\unattend\Win10_x64.xml` 全自动 / `Win7-11-Select.xml` 选择式），也允许用户自选任意 `*.xml`。Dism++ 目录里没有 unattend 模板，只有 WinNTSetup 那 3 个。 |
| D3 | 预装软件装到哪 | 装进 **MICPE 自己**（`X:\Program Files\...`），**不进**目标系统。§5.6 已加澄清。 |
| D4 | `MIC-PE` 仓库 | **清空**（所有者已明确）。本地 `/root/micpe-ref/` 已完整留档 721 MB，含全部参考材料与预装软件。 |
| D5 | 装机源如何发现 | 以**卷根 `install.mic`** 为准：存在则该卷 `<卷>\sources\install.wim` 就是装机映像，`install.mic` 首行是显示名。无标记时降级匹配 `sources\install.wim` 等。见 §5.4.1。所有者的自定义 ISO 与原版微软 ISO 同构，只是安装程序/映像/预装环境换成自己的。 |
| D6 | Office 默认 | 关闭，构建时开关（占 330 MB）。 |
| D7 | Chrome | MSI 安装（装进 MICPE）。 |
| D8 | 备份功能 | v1 不做，只做安装；备份放 v2。 |

## 9. 给实施者的自由

- CI 脚本的具体写法、缓存键设计
- PECMD 界面的像素级布局（给定上面那套配色与结构）
- 日志格式、错误码到中文提示的映射
- 文件白名单的增补（只要每加一批就跑一次体积断言）
- 探盘的具体正则与优先级（`sources\install.wim` 优先于根目录 `install.wim`）
