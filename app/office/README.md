# Office 2016（M5 已补）

- **来源**：Office 2016 绿色精简版 `office2016-green.7z`，
  170,364,185 字节，SHA256
  `8bb9a924b72e5d70968121d1ed88df8bea74823e4f8aed1598d766b2a3cb7caf`。
  出自用户提供的参考包（`~/workspace/MIC-PE-recovery/MIC-PE.7z` 里的
  `PE预装软件/安装包/`），随 `office-v1` Release 资产走，不入 git。
  解压后约 474 MB，顶层目录是 `Office2016/`，内含
  `Office16/WINWORD.EXE`、`EXCEL.EXE`、`POWERPNT.EXE`。
- **集成目标**：`\Program Files\Office2016`（厂商布局，不是
  `\Program Files\MICPE`）。
- **集成方式**：`install.bat` 只在 CI 里运行（M5 payload 步骤调用，
  对着已挂载的 boot.wim）。payload 步骤先把 7z 下载验哈希、放到本
  文件夹旁，`install.bat` 再用 `7z x` 解到 `Program Files`（顶层
  `Office2016/` 直接落位），不在 PE 里安装。幂等：先删旧目标再解；
  解完断言 `WINWORD.EXE` 存在才算成功。
- **体积**：Office 是降级顺序里的第一位（Office → Chrome → Photos
  → Media Player）。超限时先砍 Office，见 `Stages.ps1` 的
  `Get-DegradeOrder`。
