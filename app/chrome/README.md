# Chrome（打包轮已改：分卷进仓库，不再走 Release）

- **来源**：Google Chrome 企业版独立安装包
  `googlechromestandaloneenterprise64.msi`，版本 151.0.7922.138
  （Google LLC，WiX Toolset 6.0.2.0 打包，x64），164,831,232 字节，
  SHA256
  `0ec77319d917eb232f1b1b52e0f6f6178eacb2d5abff1517f5c17d50a0a2db1a`。
  出自用户提供的参考包（`~/workspace/MIC-PE-recovery/MIC-PE.7z` 里的
  `PE预装软件/安装包/`）。
- **精简**（用户决定 2026-11-17 15:07）：从 MSI 提取出的文件树上
  删掉 `Locales/` 里除 en-US、zh-CN 各 4 个 `.pak` 之外的 212 个语言
  包（约 45 MB），删掉 `WidevineCdm/` 整个目录（DRM 插件，约 22 MB），
  其余保留（`MEIPreload/`、`Extensions/` 等小组件不影响体积）。
  解压后约 440 MB，顶层目录是 `Chrome-bin/`。
- **存放**：精简后重打 `chrome-slim.7z`（125,367,407 字节，SHA256
  `df82dc28b2e0615656dae8b362eab15dd0d8efea7941a78a5e79d0f1a95ca626`），
  按 95 MB 分卷成 `chrome-slim.7z.001`、`.002` 直接提交在本文件夹
  （GitHub 单文件上限 100 MB）。构建时拼回、验哈希再用。
  旧 `chrome-v1` Release 已删除，不再有第二条包来源。
- **集成目标**：`\Program Files\Google\Chrome\Application`（厂商布局，
  不是 `\Program Files\MICPE`——Chrome 要按自己的目录结构找文件）。
- **集成方式**：`install.bat` 只在 CI 里运行（payload 步骤调用，
  对着已挂载的 boot.wim）。payload 步骤先把分卷拼回、验哈希、放到本
  文件夹旁，`install.bat` 再用 `7z x` 解出 `Chrome-bin/`、拷到
  `Application\`，不在 PE 里安装。幂等：先删旧目标再解。
  `Assert-PayloadInstalled -Chrome` 递归找 `chrome.exe`，并断言
  WidevineCdm 不存在、Locales 里只有 en-US/zh-CN。
- Edge 不自带（用户 2026-11-16 决定）；Chrome 太重可换 Firefox 并
  精简，那是体积治理时的选项，本轮不动。
