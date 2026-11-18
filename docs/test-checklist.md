# MICPE 测试清单（M1–M7）

CI 能判的项由 CI 判；只有“真机确认”一节必须人来做。**QEMU 通过 ≠ 真机
可用**：没有用户在真机上跑过这一节之前，不声称真机通过。

## CI 验收（按阶段）

| 阶段 | probe 期望（Assert-Probe.ps1） | 状态 |
|---|---|---|
| m1 | `boot=1`、`share=1` | CI（第 0 步已跑通；pflash 修法待 M7 补测） |
| m2 | + `explorer=1`、`shell_ready=1`、`dwm=1` | 待 M7 补测（stage m4 full 覆盖） |
| m3 | + `network=*`、`ime=1` | 待 M7 补测（stage m4 full 覆盖） |
| m4 | + `uwp_appx=1`、`uwp_launch_photos=1`、`uwp_launch_media=1`、`uwp_launch_calculator=1` | 待 M7 补测（stage m4 full） |
| m5 | + `payload=1`、`brand=1` | 待验证：打包轮已改走 `app/` 分卷，下一轮 Build 首次消费 |
| m6 | + `installer_scan=1`、`installer_deploy=1` | 待验证：同上；另需 4 盘 harness（M7 已接线，未跑过） |
| m7 | m6 全套 + `size_wim=*`、`size_iso=*` | 待验证：同上 |

两个固定回归（plan Task 18 Step 6，CI 里做）：

1. 把产物 `boot.wim` 换进原版 Windows 11 ISO 的 `sources\`，`bcdedit /store`
   能解析，且 QEMU 冷启动后 `explorer=1`。
2. `7z x MICPE.iso.zip.001` 解出的 ISO 的 SHA256 与 Release notes 一致。

## 体积账（M7 实测 + 项目自标）

| 项 | 数 | 来源 |
|---|---|---|
| boot.wim（M1 基线） | 552.4 MB（579,198,519 字节） | run5 产物实测 |
| payload 解包后 | ~53.6 MB（56,170,190 字节，113 文件） | 本机 `7z l micpe-payload.7z` |
| Chrome 开关 | +280 MB | build.yml 输入描述 |
| Office 开关 | +330 MB | build.yml 输入描述 |
| boot.wim 上限 | 3 GB | `Wim.ps1` `$BootWimMaxBytes` + 各步骤后断言 |
| ISO（M1 实测） | 4.48 GB（4,809,894,132 字节） | run 43884981629 |
| ISO 门禁 | 5 GB（只防失控增长） | `Iso.ps1` |
| ISO 产品目标 | ≤3.2 GB | plan.md |
| install.wim 单独 | ~4.1 GiB | `Iso.ps1` 注释 |

结论：boot.wim 预计 m6 无开关 ~0.65–0.9 GB、双开关 ~1.3–1.5 GB，离
3 GB 上限很远，降级门禁是护栏。**ISO 的 3.2 GB 目标在保留完整
install.wim 的前提下不可能达到**——4.48 GB 里 ~4.1 GiB 就是 media 里
的完整 install.wim（装机源，MICPE-Setup 要用它装系统）；降级顺序砍的
是 boot.wim 里的组件，对 ISO 几乎没影响。是否砍 install.wim 索引、或
接受 ~4.5 GB，等用户拍板；本轮不动 ISO 门禁、不砍任何已批功能。

降级顺序（已批）：Office → Chrome → Photos → Media Player。
超限时构建失败，日志给“请关掉 `-Office`/`-Chrome`”（`Build-Micpe.ps1`
的 iso 前决策；Photos/Media Player 没有开关，超限且它俩是下一个时
日志会说明需改代码）。

## 真机确认（用户做，一次）

用 U 盘启动成品 ISO，逐项核对，通过打 ✓、不通过写现象：

| # | 检查 | 通过 |
|---|---|---|
| 1 | PE 启动到 Explorer 桌面（不是 cmd 黑窗口），任务栏、桌面图标正常 | |
| 2 | 开始菜单 / 桌面能打开文件资源管理器 | |
| 3 | 微软拼音输入法可用：Shift 切中英，中文能打出字 | |
| 4 | 照片应用能打开一张图片 | |
| 5 | 新版媒体播放器能打开并播放一段视频/音频 | |
| 6 | 计算器能打开 | |
| 7 | PENetwork 能打开并联网（能上网） | |
| 8 | 7-Zip、DiskGenius、WinNTSetup 在 `Program Files` 里能找到并打开 | |
| 9 | 品牌：`winver` 显示 RegisteredOwner SYSTEM-Intel-MIC、Organization MICPE；OEM 信息里 SupportURL 是 B 站主页；桌面壁纸是 MICPE 壁纸 | |
| 10 | 插一张带 `install.mic` 的 U 盘（或第二块硬盘），开机自动弹出 MICPE 一键装机 | |
| 11 | 装机工具里能看到镜像与版本下拉，目标盘不是 PE 所在盘、不是镜像所在盘 | |
| 12 | 点“开始安装”能把系统装到目标盘，装完重启能进新系统（OOBE 正常） | |
| 13 | 装完的新系统里 `C:\Program Files\MICPE` 不存在多余的安装器残留（装机工具只应在 PE 里） | |
| 14 | PECMD 还在：`X:\Program Files\MICPE` 里有 PECMD.EXE，装机工具能正常弹 | |
| 15 | probe 各项（仅供对照 CI）：`explorer=1`、`shell_ready=1`、`dwm=1`、`ime=1`、`uwp_launch_*=1`、`payload=1`、`brand=1`、`installer_scan=1`、`installer_deploy=1` | |
| 16 | 盘符：PE 系统盘是 `X:`；原来装 Windows 的那个盘在 PE 里仍是 `C:`（不是 PE 启动盘抢了 `C:`）；资源管理器里能看到原系统盘 | |

## 已知未验证（不要当成已通过）

- payload / brand / installer 的 L2/L3：无一次真实构建跑过（被 Release 挡住）。
- `.esd` 映像的 DISM apply：同一条命令，L3 未覆盖。
- disk2-only 的 `installer_scan=nopartition` 场景：合跑里观测不到。
- PECMD WCS 语法：初稿，以 L3 probe + 截图为准。
- 26H2 底座：用户已决定留在 25H2 26200，不换。
