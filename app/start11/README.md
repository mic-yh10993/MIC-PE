# Start11 1.3（Stardock）

Stardock 的 Win11 开始菜单/任务栏替代品。和 StartAllBack 二选一：两者都
会接管任务栏，同时开只会互相打架。**默认关闭**（manifest 里
`"start11": false`），StartAllBack 是这条链的主选。

- **版本**：Start11 1.3.2.0（`Start11_64.exe` 1.3.2.0，`Start10Shell64.dll`
  1.1.0.0，用户 2026-11-22 提供的 `Desktop\shell\Start11`，x64）。
- **许可**：商业软件（试用期后需要授权）。仓库只做集成，不含授权。
- **集成目标**：`X:\Program Files\Start11`（厂商布局）。
- **状态**：文件与启动链已就位，**尚未实机验证**。它没有官方安装器的注册
  表写入（CLSID `{6A451C0A-9597-4915-BCCE-6E859BC996B2}` 的 `Start10Shell`
  类、`SOFTWARE\Stardock\Start8` 设置树），第一次在真机跑起来可能还需要
  补注册——真机结果出来后按下面的"下一步"改。

## 目录

```
app/start11/
  install.bat            # CI：files\ -> Program Files\Start11，并投放启动钩子
  files/                 # 程序本体（官方安装目录的平铺副本）
  hooks/
    50-start11.cmd       # 启动钩子，装到 System32\MICPE\hooks\postshell\
  README.md
```

## 它怎么被装进去

`src/uwp/manifest.json`：

```json
{ "kind": "app", "install": "app/start11/install.bat", "reg": [],
  "requiresFeature": "start11" }
```

把根上的 `"start11"` 改成 `true`、同时把 `"startAllBack"` 改成 `false`，
就切换到 Start11。`reg` 为空是故意的：现在还没有可信的注册表写入清单，
与其抄一份错的，不如先让程序在真机上自己跑起来，看到缺什么再补。

Start11 不是"注册即生效"的钩子，它需要一个进程起来，所以 `install.bat`
会把 `hooks/50-start11.cmd` 拷进镜像的 postshell 钩子目录：shell 起来后
执行 `Start11_64.exe`。钩子里有两道判断——目录不存在就退出；检测到
StartAllBack 已安装也退出（避免两个外壳抢任务栏）。

## 在真机上接着做

1. 启动到桌面，看 `X:\Windows\System32\MICPE\logs\boot.log` 里有没有
   `hook postshell: starting Start11`。
2. 开始菜单没变：说明缺 shell 钩子注册。Start11 的钩子 DLL 是
   `Start10Shell64.dll`，它内部引用的类是 `{6A451C0A-9597-4915-BCCE-6E859BC996B2}`
   （`Start10Shell Class`）；按 StartAllBack 的 `software.reg` 格式补一份
   `reg/software.reg`，然后把这个文件的 `"reg"` 指向它。
3. 服务 `Start11Srv.exe` 是否需要常驻，以真机行为为准：先在钩子里直接起
   `Start11_64.exe`，不行再考虑把 `Start11Srv.exe` 注册成服务。

## 改外观

Start11 的设置界面是 `Start11Config.exe`；设置落在
`HKCU\Software\Stardock\Start8`（它继承了 Start8 的命名空间）。要固化默认
值，就照着导出这个键，写成 `reg/default.reg` 并加进 manifest 的 `reg`。
