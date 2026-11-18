# app/ — 自带组件集成目录

用户 2026-11-16 批准：仓库根目录加 `app/` 文件夹，所有自带组件各建一个
文件夹，里面放程序文件和 `install.bat` 自动集成脚本。第 0 步只定结构与
约定，具体组件集成留到 M5（payload 阶段）。

用户 2026-11-16 22:16 补充决定（三点，已获授权）：
- 装机向导实现方式由助手自主决策（M6 设计时再定：选性能损失最小、体积小、
  功能全、页面现代化的语言/技术栈）。本文件只给装机向导留位置，不选型。
- PECMD 是否接管系统初始化由助手自定；相关配置文件统一放
  `%System32%\MICPE`；用户的 MICPE 装机软件（自写）+ PENetwork + 其他
  MICPE 自有东西放 `\Program Files\MICPE`。
- UWP 仅保留核心文件：系统自带的设置应用太重，不要；如果需要最基础的
  设置功能就自实现（基本就是改注册表），自实现的东西放
  `%System32%\MICPE`。M4 只做 UWP 核心文件（照片、新版媒体播放器），
  不做设置应用；是否自实现设置工具留到 M4 再定。

用户 2026-11-17 07:48 补充决定（install.bat 的语义，已获授权）：
- `install.bat` **在 CI 里运行**：构建（M5 payload 阶段）时由 CI 调
  用，对着已挂载的 boot.wim 做集成——无非就是复制文件、写注册表，
  CI 里都可以实现。
- `install.bat` **绝不在 PE 启动后运行**：不要进入 PE 再安装软件，
  太浪费性能。PE 里只有集成好的文件，没有安装过程。
- office 的安装脚本改成 CI 能运行的版本；chrome 安装 bat 自写。
  这两个组件本体已在 M5 补齐（见 `app/chrome/`、`app/office/` 的
  `install.bat` 与 `README.md`），下面的清单里 office、chrome 均标
  为“M5 已补”。

## 布局

```
app/
  README.md            # 本文件：约定与组件清单
  _template/           # 新组件的模板（复制改名后填内容）
    README.md
    install.bat
  chrome/              # （M5 已补）Chrome 安装包
  office/              # （M5 已补）Office 2016 安装包
  <组件名>/            # 以后每加一个组件，就在这里建一个文件夹
    install.bat        # 必备：CI 里运行的自动集成脚本
    <程序文件...>      # 组件自己的文件
    README.md          # 可选：来源、版本、许可说明
```

## 集成目标（两个位置，分工固定）

`app/` 里放的是“组件安装包 + install.bat 集成脚本”，集成时按组件性质
写到下面两个位置，不要混放：

| 目标位置 | 放什么 |
| --- | --- |
| `%System32%\MICPE` | 相关配置文件（PECMD 接管初始化的配置也在此）；自实现的小工具（例如 M4 若决定自实现基础设置工具，放这里） |
| `\Program Files\MICPE` | 用户自写的 MICPE 装机软件、PENetwork、其他 MICPE 自有东西；各组件的程序文件（例如 Chrome、Office 的安装包解出来的程序） |

install.bat 按这个分工写目标路径：程序文件去 `\Program Files\MICPE`，
配置文件和自实现工具去 `%System32%\MICPE`。

## install.bat 约定（M5 的集成脚本会按这个约定调用）

- **运行时刻：CI 里，不在 PE 里。** 构建（M5 payload 阶段）时由 CI
  调用，对着已挂载的 boot.wim 做集成——复制文件、写注册表，CI 里都
  可以实现。`install.bat` 绝不在 PE 启动后运行；不要进入 PE 再安装
  软件，太浪费性能。PE 里只有集成好的文件，没有安装过程。
- 调用方式：`install.bat <挂载的 boot.wim 目录> <仓库根目录>`
  - `%1`：已挂载的 boot.wim 根目录，例如 `D:\micpe\mount`（注入目标是
    上面两个位置之一，见 plan.md 品牌约定：自有程序只放
    `X:\Program Files\MICPE\`）。
  - `%2`：仓库根目录，脚本自己的程序文件就放在脚本所在文件夹里。
- 必须幂等：重复跑两次结果一致（先删旧目标再拷，或跳过已存在文件）。
- 成功返回 `exit /b 0`；任何一步失败返回非零并打印原因。
- 只动自己组件的目标路径，不要改 boot.wim 里其他东西。
- 体积有上限（boot.wim ≤ 3GB，目标 ≤ 2.6GB；ISO ≤ 3.2GB），超限时按
  plan.md 的降级顺序处理：Office → Chrome → Photos → Media Player。

## 组件清单（计划内）

| 组件 | 来源 | 集成目标 | 状态 |
| --- | --- | --- | --- |
| Chrome | 自带安装包（用户 2026-11-16 澄清：Edge 不自带；Chrome 太重可换 Firefox 并精简；安装 bat 自写，CI 里运行） | `\Program Files\Google\Chrome`（厂商布局，见 `app/chrome/README.md`） | M5 已补 |
| Office 2016 | 自带安装包（安装脚本改成 CI 能运行的版本） | `\Program Files\Office2016`（厂商布局，见 `app/office/README.md`） | M5 已补 |
| PE 工具 | 参考文件里的工具（见 `~/workspace/MIC-PE-recovery/`） | 按性质分两处 | M5 已集成（`app/payload/micpe-payload.7z`） |
| PENetwork | 参考文件里的网络工具 | `\Program Files\MICPE` | M5 已集成（`app/payload/micpe-payload.7z`） |
| MICPE 装机软件 | 用户自写 | `\Program Files\MICPE` | M5 集成 |
| UWP 核心文件 | install.wim 提取（M4）：照片、新版媒体播放器；**不含系统设置应用** | 系统位置（UWP 自带路径） | M4 |
| 自实现设置工具 | 若 M4 决定做：改注册表实现基础设置 | `%System32%\MICPE` | M4 再定 |
| 装机向导 | M6：技术栈由助手在 M6 设计时定（性能损失最小、体积小、功能全、页面现代化） | 待定（随向导设计定） | M6，预留位置 |

## 不在这里放的东西

- 构建脚本（在 `src/build/`）、CI 探针（在 `src/ci/`）、启动脚本（在
  `src/shell/`）。
- 临时下载物与大文件：构建时下载的东西放构建工作目录，不进仓库。
