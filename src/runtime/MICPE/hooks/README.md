# 启动钩子（hooks）

四个阶段各有一个目录，构建时整个 `src/runtime/MICPE` 会被原样复制到镜像的
`%SystemRoot%\System32\MICPE`，所以这里放什么，镜像里就有什么。

| 目录 | 时机 | 能做什么 |
|---|---|---|
| `hooks/osinit/` | `wpeinit.exe` 之后、用户环境之前 | 加载驱动、写 HKLM 注册表、设置机器级环境变量 |
| `hooks/preshell/` | `USERPROFILE` 已设、`ctfmon` 已起、shell 之前 | 铺快捷方式、改 `HKCU`（此时是 SYSTEM 的 HKCU） |
| `hooks/shell/` | shell 已启动并轮询结束 | 按 shell 是否存活做补救动作 |
| `hooks/postshell/` | 控制台隐藏之前 | 改外观、起常驻小工具、收尾清理 |

规则很简单：

- 只放 `.cmd`，按**文件名排序**执行，用 `10-`、`20-` 这类前缀控制顺序。
- 钩子在 `startnet.cmd` 的同一个 cmd 进程里 `call`，**不要用 `setlocal`**，
  否则设的变量传不到下一阶段。
- 必须纯 ASCII + CRLF（控制台是 CP936，中文注释在某些代码页下会截断命令行）。
  中文说明写在这个 README 里，不要写进 `.cmd`。
- 失败不要 `exit`，用 `exit /b`；钩子报错不应该打断后面阶段。

示例（`hooks/postshell/10-show-all.cmd`）：

```bat
@echo off
rem Show hidden and system files in Explorer.
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v Hidden /t REG_DWORD /d 1 /f >nul
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v ShowSuperHidden /t REG_DWORD /d 1 /f >nul
```

放进去、重新构建，就生效，不需要动任何其他文件。
