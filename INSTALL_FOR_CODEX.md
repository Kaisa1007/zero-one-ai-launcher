# INSTALL_FOR_CODEX.md

这份文件写给 AI 编程助手（Codex 等）看。用户会给你本仓库的地址，让你帮忙安装。请按顺序执行下面的步骤，每一步都先做检查，确认成功后再继续。用简体中文向用户汇报。

要安装的东西一共三样，彼此独立。用户只要其中一部分的话，跳过其余部分即可：

- **A. 启动器**：开机动画加 Codex 换皮（macOS App）
- **B. 伊兹桌宠**：Codex Pets 宠物
- **C. 伊兹人格**：`~/.codex/AGENTS.md` 加 Personalization

## 规则

- **不要修改** `/Applications/ChatGPT.app` 的任何文件。换皮是启动器运行时注入的，App 本体保持原样。
- **不要运行** `./build_app.sh --assets`。它依赖不在仓库里的原始素材库，一定会失败。`Resources/` 里已经有全部生成好的素材。
- **不要在安装过程中打开启动器。** 你正在 Codex 里运行，而启动器要求 Codex 没在运行才能换皮。打开的步骤留给用户自己做（见最后一节）。
- 需要联网、写 `/Applications` 或安装系统组件时，按你平时的权限流程向用户请求批准。
- 某一步失败时，告诉用户卡在哪一步、报错是什么、建议怎么解决。不要跳过失败的步骤继续往下做。

## 0. 环境检查

```bash
uname -m                                   # 必须是 arm64（Apple Silicon）
sw_vers -productVersion                    # 必须 ≥ 14.0
xcode-select -p                            # 有输出路径 = 已安装 Command Line Tools
swiftc --version                           # 能输出版本号
ls -d /Applications/ChatGPT.app            # Codex 已安装
```

- 不是 `arm64`：告诉用户启动器只支持 Apple Silicon，A 跳过，B、C 仍然可以装。
- 没有 Command Line Tools：让用户运行 `xcode-select --install`，在弹出的系统窗口里点「安装」，装完再继续。这一步必须用户手动确认。
- 找不到 `ChatGPT.app`：启动器仍然可以装，运行时会让用户手动选择 Codex 的位置。

## 1. 获取仓库

如果当前目录已经是本仓库（有 `build_app.sh` 和 `extras/izu-pet/`），跳过这一步。否则：

```bash
git clone https://github.com/Kaisa1007/zero-one-ai-launcher.git ~/zero-one-ai-launcher
cd ~/zero-one-ai-launcher
```

之后的命令都在仓库根目录里运行。

## A. 安装启动器

```bash
./build_app.sh --install
```

- 成功的标志：最后几行输出 `Built: ...` 和 `Installed: /Applications/Zero-One AI Launcher.app`。如果 `/Applications` 不可写，会装到 `~/Applications/Zero-One AI Launcher.app`，这也算成功。
- 编译时出现的 warning 可以忽略，只有 error 才算失败。
- 如果报 `No macOS SDK compatible with ...`：说明 Command Line Tools 的编译器和 SDK 版本不匹配。让用户运行 `softwareupdate --list` 查看并更新 Command Line Tools，或者安装完整的 Xcode。

可选的自检（窗口模式、静音、不启动 Codex，大约 25 秒）：

```bash
"build/Zero-One AI Launcher.app/Contents/MacOS/ZeroOneLauncher" --selftest /tmp/zo-selftest
tail -5 /tmp/zo-selftest/selftest.log
```

退出码为 0 就算通过。

## B. 导入伊兹桌宠

前提：当前 Codex 可以使用 Pets 插件（ChatGPT Work 模式）。如果没有 Pets 相关的工具或插件，告诉用户这个账号暂时不支持桌宠，跳过 B。

- 图集：`extras/izu-pet/spritesheet-extended.png`（v2 格式，1536×2288，9 组动作加 16 个视线方向，已经通过校验）
- SHA-256：`b60d48367c37fddd7c186b497a98ef0eaf8b1d9626bc4b68c02c14d57323064d`。先用 `shasum -a 256` 核对，不一致就说明文件损坏，重新下载。

步骤：

1. 先用 Pets 的列表功能看用户是否已经有名为「伊兹」的宠物。如果有，问用户是直接启用现有的，还是再创建一个。
2. 用这张图集的**绝对路径**，按 Pets 插件的流程校验并上传，然后创建宠物：
   - 名字：`伊兹`
   - 描述：`以《假面骑士01》伊兹为原型的Q版修玛吉亚秘书，认真礼貌地辅助工作，也在陪伴中学习情感。`
3. 把新宠物设为当前宠物，再查一次列表，确认它确实是当前启用的宠物。
4. **不要重新生成或修改图集。** 它已经是最终版本。如果校验报错，把错误原样告诉用户，不要尝试修复图片。

## C. 设置伊兹人格

### C1. AGENTS.md（你来做）

目标：把 `extras/izu-pet/AGENTS.md` 的内容加进 `~/.codex/AGENTS.md`，**追加，不要覆盖**用户原有的内容。

```bash
mkdir -p ~/.codex
if grep -q '人格：伊兹' ~/.codex/AGENTS.md 2>/dev/null; then
  echo "已经装过伊兹人格，跳过"
else
  [ -f ~/.codex/AGENTS.md ] && cp ~/.codex/AGENTS.md ~/.codex/AGENTS.md.bak-before-izu
  { [ -s ~/.codex/AGENTS.md ] && printf '\n\n'; cat extras/izu-pet/AGENTS.md; } >> ~/.codex/AGENTS.md
  echo "已追加"
fi
```

如果用户原来有 `AGENTS.md`，告诉他们备份在 `~/.codex/AGENTS.md.bak-before-izu`。

### C2. Personalization（用户来做，你无法操作）

这是 Codex 的账号设置，你改不了。请把下面的说明原样告诉用户：

> 请打开 Codex「设置 → Personalization」：
> 1. 人格（Personality）预设选 **None**；
> 2. 打开仓库里的 `extras/izu-pet/PERSONALIZATION.md`，复制「# IZU — 伊兹人格系统提示词」下面从「## 一、核心身份」开始、到「尽量减少无意义反问」为止的全部内容，粘贴进自定义指令一栏；
> 3. 「怎么称呼你」一栏填 **社长**。
>
> 设置完以后，新开的对话才会生效。

如果用户希望你帮忙，可以把这段要粘贴的文字完整地输出在回复里，方便他们复制。

## 最后：告诉用户怎么用

安装完成后，向用户汇报每一部分是成功、跳过还是失败，然后告诉他们：

> 想看开机动画和飞电皮肤的话：
> 1. 先完全退出 Codex（⌘Q）；
> 2. 用聚焦搜索（⌘空格）输入「Zero-One」，打开 **Zero-One AI Launcher**；
> 3. 看完约 21 秒的开机动画后，会自动进入换好皮肤的 Codex。按 Esc 可以跳过动画。
>
> 以后想要飞电皮肤，就从 Zero-One AI Launcher 打开 Codex。直接打开 Codex 的话，就是原来的样子。
