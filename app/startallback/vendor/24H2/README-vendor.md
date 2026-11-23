# vendor/ — StartAllBack 官方安装包（WimBuilder2 做法）

`install.bat` 构建时从这里的官方 `.exe` 现解（`7z x -aoa`，安装程序本身
不运行），而不是用仓库里预解压的 `files/`。版本切换靠放包，不改脚本。

## 放包规则

- **构建号 `>= 26100` 用 `24H2/`**，更早的构建用 `vendor/` 根目录。
  （WimBuilder2 `StartIsBack/main.bat:25-32` 的门禁；26300 走 `24H2/`。）
- 文件名须匹配 `StartAllBack_*_setup.exe`。一个目录里有多个包时，按文件名
  排序取最后一位（wb2 `VGetFile.cmd` 的 `dir /b /on` 规则）——丢一个新包进来
  就自动成为选中项，不用改脚本。
- **放之前先验包**：`7z t <包>.exe`（测试归档完整性）+ `7z x -aoa` 解到临时目录，
  核对 `StartAllBackX64.dll` 存在。构建时 `install.bat` 也会校验 DLL 存在，
  但坏包要尽早拦住。

## 不要放的包

- **`StartAllBack_3.9.20_Setup.exe` 已损坏**（WimBuilder2 `vendor/` 里那个文件：
  磁盘 1,776,404 字节，7z 头标称 2,125,088，解压报 `Unexpected end of archive`，
  exit 2，丢了 A64 全套）。wb2 靠文件名排序恰好避开它（选中 3.9.28）。
  不要把它拷进来。

## 包到了之后还要做的事（不要只放包）

1. `reg/default.reg` 的 `CurrentVersion` 改成 DLL 的主版本号
   （3.9.x → `"3.9"`；`install.bat` 会校验，不一致构建失败）。
2. `src/uwp/manifest.json` 里 `StartAllBack 3.6 (...)` 的名字改成实际版本。
3. 构建成功后按探针验收：`sab_files=1`、`sab_reg=1`、`sab_mapped=1`、
   **`sab_hook=1`**（`StartAllBackX64.dll` 进 explorer 进程——3.6 在 26300 上
   一直缺的那一项）。`sab_hook` 从 0 变 1 才是换版生效的证据。

## 包没到之前

`vendor/` 与 `24H2/` 为空时，`install.bat` 回退到预解压的 `files/`（3.6），
构建产物与以前完全一致。`files/` 原地保留，直到 3.9.x 验证通过再由用户
定夺是否删除。
