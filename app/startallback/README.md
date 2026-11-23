# StartAllBack 3.6

Windows 11 原生任务栏/开始菜单是 XAML 外壳，在 PE 里跑得起来（现在是
explorer 自带的那套），但开始菜单是空的、右键菜单也缺东西。StartAllBack
把任务栏和开始菜单接管成经典外壳行为，同时保留 Win11 的视觉。

- **版本**：StartAllBack 3.6.0.4631（`StartAllBackX64.dll` 3.6.0，
  用户 2026-11-22 提供的 `Desktop\shell\StartAllBack`，x64）。
- **许可**：StartAllBack 是共享软件（30 天试用后需要授权）。本仓库只做
  集成，不包含授权信息；正式发布前请自行确认许可。
- **集成目标**：`X:\Program Files\StartAllBack`（厂商布局，不是
  `Program Files\MICPE`——注册表里的 CLSID 硬编码了这条路径，程序也按
  自己所在目录找 `Styles\`、`Orbs\`、`Ribbon\`）。

## 目录

```
app/startallback/
  install.bat          # CI 里运行：files\ -> 镜像 Program Files\StartAllBack
  files/               # 程序本体（相当于官方安装后的目录）
    StartAllBackX64.dll        # 外壳钩子，explorer 加载它
    StartAllBackLoaderX64.dll  # 由 Drive\shellex\FolderExtensions 载入
    StartAllBackCfg.exe        # 设置界面
    Styles/  Orbs/  Ribbon/
  vendor/              # 官方安装包（构建时 7z 现解，见下）；3.9.x 没到之前是空的
    24H2/              # 构建号 >= 26100 用的包（如 3.9.x）
  reg/
    software.reg       # Classes 注册（CLSID / shellex / App Paths），必需
    default.reg        # 外观与默认项（HKCU = PE 的 DEFAULT 蜂巢），可随便改
```

## 它怎么被装进去

`src/uwp/manifest.json` 里两条：

```json
{ "kind": "app", "install": "app/startallback/install.bat",
  "reg": ["app/startallback/reg/software.reg", "app/startallback/reg/default.reg"],
  "requiresFeature": "startAllBack" }
```

`requiresFeature` 指向 manifest 根上的 `"startAllBack": true`；改成 `false`
整套（文件 + 注册）都不装，镜像回到纯原生 Win11 外壳。**不要**只关一半：
只留文件不导 `software.reg`，explorer 不会加载钩子 DLL，等于白拷。

装完不需要写启动项：StartAllBack 是进程内外壳钩子，explorer 启动时按
`software.reg` 里的 `Drive\shellex\FolderExtensions\{117E3954-...}` 和几个
ContextMenuHandlers 把自己的 DLL 载进去。

## 改外观 / 改行为

按"改代码而不是点 GUI"的约定，入口只有两个：

1. `reg/default.reg`——想固定什么设置就往里加，键名就是 StartAllBack
   自己写进 `HKCU\Software\StartIsBack` 的那些（`StartMenuAlpha`、
   `TaskbarCentered`、`AlterStyle`、`TaskbarStyle` ……）。
   现在故意**不写** `AlterStyle`/`TaskbarStyle`：不写就是 StartAllBack
   的 Win11 默认皮肤；要 Win7/Win8 外观就加
   `"AlterStyle"="X:\\Program Files\\StartAllBack\\Styles\\Plain8.msstyles"`。
2. `files/Styles/`——替换 `.msstyles` 文件即可换皮，路径与文件名跟
   `default.reg` 里写的对上就行。

`files/` 是官方安装目录的平铺副本：升级只需把新版本目录整个替换掉，
再按需改 `default.reg` 里的 `CurrentVersion`（现在是 `3.6`，版本对不上会
触发它的"设置已重置"提示）。

**版本门禁（round 7，按 WimBuilder2 的做法）**：`install.bat` 接受第 3 个
参数——目标 Windows 构建号（UwpChain 从构建参数传进来）。构建号
`>= 26100` 时优先解压 `vendor/24H2/` 里的官方安装包（`7z x -aoa`，
安装程序本身不运行）；没有包时回退到 `files/`（3.6）。包没到之前，
构建产物与以前完全一致。包到了之后：把 3.9.x 的 `.exe` 放进
`vendor/24H2/`（先 `7z t` 验完整性），再把 `default.reg` 的
`CurrentVersion` 改成 `"3.9"`、`manifest.json` 里的名字改成实际版本，
构建会自动走 vendor 路径；`install.bat` 会校验 DLL 版本与
`CurrentVersion` 一致，不一致构建失败。`vendor/24H2/README-vendor.md`
有放包规则（**不要放 `StartAllBack_3.9.20_Setup.exe`，那个文件已损坏**）。

## 与 WimBuilder2 的关系

注册表 `software.reg` 是从 WimBuilder2
`01-Components/00-Shell/za-StartMenu/StartIsBack/SAB_RegSoftware.reg` 转过来
的：只把 `Tmp_Software` 换成这个项目挂载镜像用的 `PE-SOFT` 别名，删掉纯
占位的空父键，其余保持等价。`default.reg` 是重写的——wb2 那份把外观锁在
`Plain8`（Win8 任务栏），不符合"要 Win11 样式"的需求。

**2026-11-23 逐项核对结论**（`micpe-wb2-round6/sab-wb2-analysis.md`）：
`software.reg` 与 wb2 在值层面逐值相同（76=76，零差异），键数差全是空父键；
`default.reg` 的 54 个值差距里，`AlterStyle`/`TaskbarStyle` 是有意的风格分叉
（不补）、`LegacyTaskbar` 是我方多且参考镜像也有、其余约 50 个值基本是 SAB
内置默认的显式复述（不写即默认）。`files/` 与 wb2 的 x64 保留集只差 3 个文件
（`DarkMagicLoaderX64.exe`、`DarkMagicX64.dll`、`UpdateCheck.exe`），但参考镜像
（能工作）同样没有前两个，所以缺它们不是当前故障。Plain10/Windows 10 样式文件
在任何官方包、wb2 树、参考镜像里都不存在——参考镜像的注册表指向它们但文件缺失，
SAB 容错回落，不要从不明来源补。任务栏不出的最可能原因仍是版本（3.6 不支持 26300），
等 3.9.x 包。

## 已知前提 / 坑

- **版本与系统版本的对应关系（round 3 定死）**：3.6 不支持 26300
  （26H2）。微软在 26100（24H2）硬拦截了旧版 StartAllBack；3.8（2024-07）
  才首次支持 24H2（任务栏完全重写），3.9.26（2026-09）才正式支持 26H2。
  WimBuilder2 对 ≥26100 用 3.9.20/3.9.28。3.6 在 26300 上 loader 能载入
  （sab_mapped=1），但任务栏钩子对不上新版 explorer 内部结构，任务栏出
  不来。想在 26300 上有任务栏，最终要升级到 3.9.x（用户会发包）；本轮先用
  LegacyTaskbar=1（走经典任务栏代码路径）+ 桌面 .lnk（早期触发
  FolderExtension）缓解。
- 需要 `authui.dll`、`shutdownux.dll`、`nrtapi.dll` 在 `System32`（电源和
  用户菜单用）。这三个在 `61-shell-explorer-app.txt` 已经在镜像里。
- 任务栏时钟：`default.reg` 里把 `ImmersiveShell\UseWin32TrayClockExperience`
  设为 0，让 StartAllBack 画时钟；否则角落会有两个时钟。
- 两个外壳替代品不能同时开：Start11 的启动钩子会检测到
  `StartAllBackX64.dll` 存在并自己跳过。
