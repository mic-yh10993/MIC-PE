# app/ — 自带组件集成目录

用户 2026-11-16 批准：仓库根目录加 `app/` 文件夹，所有自带组件各建一个
文件夹，里面放程序文件和 `install.bat` 自动集成脚本。第 0 步只定结构与
约定，具体组件集成留到 M5（payload 阶段）。

## 布局

```
app/
  README.md            # 本文件：约定与组件清单
  _template/           # 新组件的模板（复制改名后填内容）
    README.md
    install.bat
  chrome/              # （M5）Chrome 安装包
  office/              # （M5）Office 2016 安装包
  <组件名>/            # 以后每加一个组件，就在这里建一个文件夹
    install.bat        # 必备：自动集成脚本
    <程序文件...>      # 组件自己的文件
    README.md          # 可选：来源、版本、许可说明
```

## install.bat 约定（M5 的集成脚本会按这个约定调用）

- 调用方式：`install.bat <挂载的 boot.wim 目录> <仓库根目录>`
  - `%1`：已挂载的 boot.wim 根目录，例如 `D:\micpe\mount`（注入目标是
    `X:\Program Files\MICPE\<组件名>` 一类的路径，见 plan.md 品牌约定）。
  - `%2`：仓库根目录，脚本自己的程序文件就放在脚本所在文件夹里。
- 必须幂等：重复跑两次结果一致（先删旧目标再拷，或跳过已存在文件）。
- 成功返回 `exit /b 0`；任何一步失败返回非零并打印原因。
- 只动自己组件的目标路径，不要改 boot.wim 里其他东西。
- 体积有上限（boot.wim ≤ 3GB，目标 ≤ 2.6GB；ISO ≤ 3.2GB），超限时按
  plan.md 的降级顺序处理：Office → Chrome → Photos → Media Player。

## 组件清单（计划内）

| 组件 | 来源 | 状态 |
| --- | --- | --- |
| Chrome | 自带安装包（用户 2026-11-16 澄清：Edge 不自带；Chrome 太重可换 Firefox 并精简） | M5 集成 |
| Office 2016 | 自带安装包 | M5 集成 |
| PE 工具 | 参考文件里的工具（见 `~/workspace/MIC-PE-recovery/`） | M5 集成 |

## 不在这里放的东西

- 构建脚本（在 `src/build/`）、CI 探针（在 `src/ci/`）、启动脚本（在
  `src/shell/`）。
- 临时下载物与大文件：构建时下载的东西放构建工作目录，不进仓库。
