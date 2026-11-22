# Client 底座的裁剪策略（WIMBuilder2 研究结论）

这份文档回答两个问题：**怎么裁剪才安全**，以及**哪些东西是不能动的**。

写作背景：v7 用黑名单方式把 `install.wim`（9.1 GB）删到 4.03 GB，
结果开机报 `0xc00000bb`。修的时候发现根因根本不是"删多了"，
而是**少了一整套驱动**——这恰好说明黑名单法的根本缺陷：它只能保证
"没删掉我记得的"，无法保证"该有的都有"。

---

## 一、WIMBuilder2 的三个不变式

WIMBuilder2 能做出稳定可用的 Client 型 PE，靠的是三条纪律，不是某个技巧。

### 1. 加，而不是减

WB 的做法是**从空目录开始，只取组件声明的文件**：

```
call AddFiles %0 :end_files
\Windows\explorer.exe
\Windows\System32\winlogon.exe
+ver >= 17763
...
:end_files
```

`AddFiles.cmd` 把这份清单交给 `AddFiles.vbs` 解析（支持 `@` 切换基路径、
`+mui` 自动带语言 MUI、`+if`/`+ver` 条件、通配符、逗号分隔），
再由 `DoAddFiles.cmd` 一次性抽取：

```
wimlib-imagex extract "%WB_SRC%" %WB_SRC_INDEX% @"_AddFiles.txt" ^
    --dest-dir="%_WB_MNT_PATH%" --no-acls --nullglob
```

关键在 `--nullglob`：清单里允许写"可能不存在"的路径（不同版本差异），
不会因为某个文件缺失就整体失败。

**为什么这比黑名单强制更强**：结果与源镜像的丰富程度无关，只与清单有关。
清单是可以 review、可以测试、可以逐版本维护的资产。

### 2. 整类删除前，先寄存再恢复

有些类别必须整体清掉（字体、NLS 代码页、键盘布局），但其中少数成员要留。
WB 的 `Slim_Safely.bat` 用一个 20 行的原语解决：

```
:KEEP_FILES                    # 把要留的 move 到 [KEEP]<原路径>
:KEEP_DONE                     # xcopy /S /E /H /K 回原位，再删 [KEEP]
```

用法是**先寄存、再整类删、最后恢复**：

```
call :KEEP_FILES \Windows\Fonts\ "msyh.ttc,segoeui.ttf,segmdl2.ttf,..."
del /a /f /q "%X_WIN%\Fonts\*.*"
...
call :KEEP_DONE
```

这样"删除"这个动作永远是精确的（删完之后恢复的是明确的白名单），
而不是靠 `del` 的排除语法去和通配符斗智。

### 3. 注册表也用"装配"而不是"删减"

WB 不在目标蜂巢上做删除，而是把需要的键 `RegCopy` 到 `Tmp_SYSTEM` /
`Tmp_SOFTWARE` 里，最后整体换掉：

```
call RegCopy /-s "HKLM\SOFTWARE\Classes\*"
call RegCopy HKLM\SOFTWARE\Classes\DesktopBackground\Shell
```

组件自己的注册表改动写在组件目录的 `.reg` 里（`Shell_RegSoftware.reg`），
跟着组件一起进出。**注册表和文件走同一条生命周期**，不会出现
"注册表说要这个服务，文件却被裁掉了"。

---

## 二、这次 0xc00000bb 的真正原因（与裁剪无关）

先给三方实测对比，`Start` 是服务启动类型，`0` = 引导启动：

| 服务 | Client 原始底座 | 我们的 v7 | RAMOS（能开机） | WinPE 基底 |
|---|---|---|---|---|
| `WimFsf` | **不存在** | **不存在** | `0` | `0` |
| `FBWF` | **不存在** | **不存在** | `0` + 8 GB 覆盖层 | `0` |
| `FltMgr` | `0` | `0` | `0` | `0` |
| `Ramdisk` | `3` | `3` | `0` | `3` |

结论：**Windows 安装镜像从来不打算从 WIM 里运行，所以它不带这套栈。**
`wimfsf.sys`（把 WIM 当文件系统）和 `fbwf.sys`（可写覆盖层）在
`install.wim` 里连文件都没有。

于是引导链走到"打开系统设备"这一步时无解，报错就是：

```
A required device isn't connected or can't be accessed
Error code: 0xc00000bb        (STATUS_NOT_SUPPORTED)
```

这也解释了为什么 v6（PE 底座）能走到黑屏、v7（Client 底座）直接卡在引导器：
两边的失败点完全不同，不是同一类问题。

修法（`Enable-WimBootStack`）：从安装介质的 `boot.wim` 里把
`wimfsf.sys`/`fbwf.sys` 和这两个服务的键移植进 Client 底座，
四个服务全部 `Start=0`，并给 FBWF 设 `WinPECacheThreshold`（MB）。

> 覆盖层大小的实测依据：RAMOS 用 `0x2000`（8192 MB）。
> 16 GB 内存要同时装下 ~4 GB 的 WIM，所以取 4096 MB 更稳。

---

## 三、必要清单（三层）

判断标准是"拿掉它，哪一层会塌"。

### L1 引导层 —— 拿掉任何一项都开不了机

文件：

```
Windows\System32\{ntoskrnl.exe,hal.dll,ci.dll,bootvid.dll,win32k*.sys}
Windows\System32\{smss,csrss,wininit,services,lsass,svchost,winlogon}.exe
Windows\System32\drivers\{wimfsf,fbwf,fltmgr,ramdisk,ntfs,partmgr,
                          volmgr,volmgrx,mountmgr,classpnp,storport}.sys
Windows\System32\config\{SYSTEM,SOFTWARE,SAM,SECURITY,DEFAULT}
```

服务（`Start=0`）：`WimFsf` `FBWF` `FltMgr` `Ramdisk`

注册表（`HKLM\SYSTEM\Setup`）：`CmdLine=LogonUI`、`SetupType=2`、
`SystemSetupInProgress=0`、`FactoryPreInstallInProgress=0`

> 这一层不需要探索，用 `Assert-BootCritical` 机械校验即可。
> 我们在 v7 上跑过一次，`missing=0 / serviceProblems=0` 才算过关。

### L2 会话层 —— 拿掉它开得了机但进不了桌面

`LogonUI.exe` 及其 XAML 运行时（`Windows.UI.Logon`、`Windows.UI.Xaml*`、
`CoreMessaging.dll`、`CoreUIComponents.dll`、`imageres.dll`）、
凭据提供程序（`credprovhost`/`AuthExt`）、`userinit.exe`、`explorer.exe`、
`dwm.exe`、`sihost.exe`、`themes`/`ProfSvc`/`Schedule`/`TextInputManagementService`。

这一层里最容易漏、也最容易崩的是 **LogonUI 的 XAML 依赖**：
少一个 `Windows.UI.Xaml.Resources.*.dll`，`LogonUI` 启动即崩，
现象和"引导失败"完全一样（0xc00000ef / 黑屏），极难区分。

### L3 UWP 层 —— 决定原生任务栏与开始菜单

| 项 | 位置 | 能否离线预置 |
|---|---|---|
| AppX 服务（`AppXSvc`/`StateRepository`/`ClipSVC`/`TokenBroker`） | SYSTEM 服务表 | 能（键本来就在） |
| Shell 宿主（`ShellExperienceHost`/`StartMenuExperienceHost`/`Client.CBS`/`Client.Core`） | `Windows\SystemApps` | 能（文件） |
| 框架包（`WindowsAppRuntime`/`VCLibs`/`UI.Xaml`） | `Program Files\WindowsApps` | 能（文件） |
| **StateRepository 数据库** | `ProgramData\Microsoft\Windows\AppRepository` | **不能**，首次登录时由 `StateRepository` 服务生成 |

最后一行是 UWP 型 PE"开机很慢"的唯一原因：第一次登录要把所有包注册进
状态库。WIMBuilder2 的 `zp-UWPAppX\AppXapps\main.bat` 就是干这个的
（它把注册动作显式写出来，而不是留给系统自己慢慢做）——这是后续可以
继续优化的点：**把包注册前移到构建期**，冷启动就能从分钟级降下来。

---

## 四、可以放心裁的类别

依据 `Slim_Safely.bat` / `Slim_Extra.bat` / `za-SlimUltra`，按"检索不到即无用"排序：

| 类别 | 依据 |
|---|---|
| 字体（保留当前语言 + `segmdl2`/`segoeui`/`marlett`） | 字体缺失只会退化显示，不会崩 |
| NLS 代码页（保留 `C_<ACP>.NLS` + 1252/437/20127） | 同上 |
| 键盘布局 `KB*.DLL`（保留当前 `Layout File` + `KBDUS`） | 同上 |
| 非当前语言 MUI（`Windows\Boot\*`、`System32\<lang>`） | WB 的 `REMOVE_MUI` |
| `Windows\Boot\{EFI,DVD,PCAT,Misc}` | 这些是给别人做引导用的，自己不用 |
| `WinSxS\Backup`、`WinSxS\Temp` | 组件存储回滚数据 |
| 安装器载荷（`sources\*` 非 boot.wim） | WB 的 `slim.winre_sources` |
| 语音/讲述人、`Windows\Speech*` | 独立特性 |
| Edge / WebView2、Defender 病毒库、OneDrive 安装包 | 纯负载；注意与 WinSxS 的硬链接要两边一起删才有收益 |
| `DriverStore` 里的第三方厂商驱动（NVIDIA/AMD/Realtek…） | 虚拟机/通用硬件用不到 |

反例（**不要**这样裁）：直接 `filter` 掉"看起来很大"的目录、按体积排序删、
按扩展名批量删（`.dll`/`.sys`）。我们 v5 走的就是这条路，
每次都能"省下几个 GB"，但每轮都要靠用户实测来发现新断点。

---

## 五、脚本用法

```powershell
# 1) 只做验证（不修改任何东西）
. .\src\build\lib\ClientBase.ps1
Test-BootCriticalFiles -ImageRoot E:\micpe\client\root

# 2) 给 Client 底座补上 WIM 引导栈（幂等）
Enable-WimBootStack -ImageRoot E:\micpe\client\root `
                    -PeDonorWim E:\micpe\base\boot.wim `
                    -OverlayMegabytes 4096

# 3) 整类裁剪 + 寄存恢复
Move-ToKeep -ImageRoot $root -RelativePath 'Windows\Fonts' `
            -Name 'msyh.ttc','segoeui.ttf','segmdl2.ttf','simsun.ttc'
Remove-Item (Join-Path $root 'Windows\Fonts\*') -Force
Restore-Keep -ImageRoot $root

# 4) 捕获前自证（缺失即中止，不产出不可引导的镜像）
Assert-BootCritical -ImageRoot E:\micpe\client\root
```

`Assert-BootCritical` 是这条流水线的安全阀：它把"能不能开机"从
**靠人测**变成**构建期断言**。以后再改裁剪，改坏了会在这里停下，
而不是让你等到虚拟机报 0xc00000bb。
