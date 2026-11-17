# Chrome（M5 已补）

- **来源**：Google Chrome 企业版独立安装包
  `googlechromestandaloneenterprise64.msi`，版本 151.0.7922.138
  （Google LLC，WiX Toolset 6.0.2.0 打包，x64），164,831,232 字节，
  SHA256
  `0ec77319d917eb232f1b1b52e0f6f6178eacb2d5abff1517f5c17d50a0a2db1a`。
  出自用户提供的参考包（`~/workspace/MIC-PE-recovery/MIC-PE.7z` 里的
  `PE预装软件/安装包/`），随 `chrome-v1` Release 资产走，不入 git。
- **集成目标**：`\Program Files\Google\Chrome`（厂商布局，不是
  `\Program Files\MICPE`——Chrome 要按自己的目录结构找文件）。
- **集成方式**：`install.bat` 只在 CI 里运行（M5 payload 步骤调用，
  对着已挂载的 boot.wim）。payload 步骤先把 MSI 下载验哈希、放到本
  文件夹旁，`install.bat` 再用 `msiexec /a` 管理员安装方式解包到
  目标位置，不在 PE 里安装。幂等：先删旧目标再解。
- **注意**：`msiexec /a` 解出来的子目录结构未经 Windows 实测，
  `Assert-PayloadInstalled -Chrome` 是递归找 `chrome.exe`，不钉死
  某一层子路径；L2 验证时若结构与预期不符，改断言不要放宽。
- Edge 不自带（用户 2026-11-16 决定）；Chrome 太重可换 Firefox 并
  精简，那是 M7 体积治理时的选项，本轮不动。
