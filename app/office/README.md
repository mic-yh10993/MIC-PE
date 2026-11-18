# Office 2016（打包轮已改：分卷进仓库，不再走 Release）

- **来源**：Office 2016 绿色精简版 `office2016-green.7z`，
  170,364,185 字节，SHA256
  `8bb9a924b72e5d70968121d1ed88df8bea74823e4f8aed1598d766b2a3cb7caf`。
  出自用户提供的参考包（`~/workspace/MIC-PE-recovery/MIC-PE.7z` 里的
  `PE预装软件/安装包/`）。解压后约 474 MB，顶层目录是 `Office2016/`，
  内含 `Office16/WINWORD.EXE`、`EXCEL.EXE`、`POWERPNT.EXE`。
- **精简**（用户决定 2026-11-17 15:07）：删掉 Access 相关 36 个文件
  （`MSACCESS.EXE` 15,794,848 字节、`MSACC.OLB`、`ACEDAO.DLL` ×2、
  `ACECORE.DLL`、`ACCESS12.ACC`、`TellMeAccess.nrr`、`AccessWeb/`、
  `MsAccessLogo*` 图标等，共约 20 MB），删掉厂商原有的安装卸载脚本
  `!)inst.cmd`、`-)unist.cmd`（自写集成脚本，不用厂商的）；
  `OSPP.VBS` 保留。解压后约 454 MB。
- **存放**：精简后重打 `office2016-slim.7z`（167,504,937 字节，SHA256
  `8a5ec5d7d8b77303029769f2f9e043b5f6c98e0cdd7cf5d6b56dc8e2ef6301f7`），
  按 95 MB 分卷成 `office2016-slim.7z.001`、`.002` 直接提交在本文件夹
  （GitHub 单文件上限 100 MB）。构建时拼回、验哈希再用。
  旧 `office-v1` Release 已删除，不再有第二条包来源。
- **集成目标**：`\Program Files\Office2016`（厂商布局，不是
  `\Program Files\MICPE`）。
- **集成方式**：`install.bat` 只在 CI 里运行（payload 步骤调用，
  对着已挂载的 boot.wim）。payload 步骤先把分卷拼回、验哈希、放到本
  文件夹旁，`install.bat` 再用 `7z x` 解到 `Program Files`（顶层
  `Office2016/` 直接落位），不在 PE 里安装。幂等：先删旧目标再解；
  解完断言 `WINWORD.EXE` 存在、`MSACCESS.EXE` 与厂商脚本不存在。
- **体积**：Office 是降级顺序里的第一位（Office → Chrome → Photos
  → Media Player）。超限时先砍 Office，见 `Stages.ps1` 的
  `Get-DegradeOrder`。
