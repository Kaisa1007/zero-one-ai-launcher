# Zero-One AI Launcher · Windows

飞电智能开机动画与 Codex 桌面版运行时皮肤。正常约 21 秒开始交接。Codex 加载较慢时显示「応答待ち」。动画使用 WPF，音频使用 NAudio 共享模式 WASAPI，皮肤通过 Chromium 私有调试管道注入。

## 构建

需要 Windows x64、.NET 8 SDK 和 WPF 桌面运行时。脚本优先使用仓库内的 `work\dotnet\dotnet.exe`，也可用 `-Dotnet` 指定 SDK。构建从 NuGet 还原固定版本的 NAudio.Wasapi 和它的依赖。缓存进入 `work`，程序发布到 `outputs\Windows`。

```powershell
# 在仓库根目录执行
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\windows\Build-Windows.ps1
```

保留整个发布目录。程序从相邻的 `Resources` 读取仓库成品图像、音频、皮肤和署名。

## 运行

保存工作并完全退出 Codex，双击 `outputs\Windows\ZeroOneLauncher.exe`。启动器从当前用户的 MSIX 注册包清单解析桌面入口。若找不到，请选择实际桌面程序的 `.exe`。选项会保存在发布目录的 `codex-path.txt`。

| 参数 | 行为 |
|---|---|
| 无参数 | 全屏播放并交接。Codex 已运行时切换到现有窗口。 |
| `--windowed` | 窗口模式，可与联动测试组合。 |
| `--codex-path <exe>` | 本次运行使用指定的桌面程序。 |
| `--selftest <目录>` | 静音窗口模式。使用模拟就绪状态，忽略按键和点击。 |
| `--e2e-codex <截图.png>` | 真实启动、注入、交接，截图后关闭本次启动的测试实例。Codex 已运行时以退出码 3 拒绝。 |

按 Esc、空格、回车或点击可跳到 Logo 完成画面。等待时再按一次可强制交接。正常运行的诊断和帧率写入发布目录的 `last-run.log`。

## 静音自检

```powershell
# 在仓库根目录执行
$env:ZEROONE_READY_AT = '7'
$exe = Join-Path $PWD.Path 'outputs\Windows\ZeroOneLauncher.exe'
$out = Join-Path $PWD.Path 'outputs\SelfTest'
$p = Start-Process -FilePath $exe -ArgumentList "--selftest `"$out`"" -Wait -PassThru
Get-Content -LiteralPath (Join-Path $out 'selftest.log') -Tail 14
$p.ExitCode
```

`ZEROONE_READY_AT` 默认 7 秒，设为 15 秒可验证慢速等待与恢复，设为 60 秒可验证 30 秒超时。关键节点 PNG 和 `selftest.log` 写入指定目录。退出码 0 表示时间线、语音顺序、同步进度和截图断言通过。每阶段另行记录帧数、平均间隔、p95、最长间隔、跳过的 60 Hz 逻辑帧和 UI 更新耗时 p95。

## 真实联动验证

请在独立 PowerShell 中运行，并先完全退出 Codex 桌面版。测试会关闭它自己启动的实例。测试优先在截图后通过私有管道请求 Browser.close。日志的 cleanup 字段区分调试协议退出、窗口退出、管道断开退出和强制清理。截图可能包含当前 Codex 主窗口的内容，排查时可以仅发送日志。

```powershell
# 在仓库根目录执行
$exe = Join-Path $PWD.Path 'outputs\Windows\ZeroOneLauncher.exe'
$shot = Join-Path $PWD.Path 'outputs\codex-e2e.png'
$p = Start-Process -FilePath $exe -ArgumentList "--e2e-codex `"$shot`"" -Wait -PassThru
Get-Content -LiteralPath ([IO.Path]::ChangeExtension($shot, '.log')) -Tail 30
$p.ExitCode
```

请检查 Codex 窗口是否在动画期间保持隐藏、是否透过六边形翻转露出、截图是否出现飞电皮肤，以及各阶段掉帧数。正常模式可在交接后再打开一个 Codex 窗口，检查它是否自动换皮。

## 管道探针与已知限制

- `Run-CodexPipeProbe.ps1` 是独立探针。从仓库根目录运行 `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\windows\Build-Windows.ps1 -Probe` 构建。探针产物位于 `work\probe\bin\Release\net8.0-windows`。可传入 `-SelfTest` 验证模拟进程，或完全退出桌面版后运行真实探针。
- Codex Windows `26.1029.7803.0` 的实测通过了管道握手、皮肤注入、深色模拟和 DOM 就绪。关管道后进程仍在，但主窗口消失。正式版在交接后保持连接，持续处理新窗口，等 Codex 进程结束后再释放。强制结束启动器会断开管道，可能关闭 Codex 窗口。 [Chromium 的 Windows 句柄接收](https://chromium.googlesource.com/chromium/src/+/refs/tags/136.0.7102.0/content/browser/devtools/devtools_agent_host_impl.cc) · [Electron 断开回调](https://github.com/electron/electron/blob/v44.0.0/shell/browser/electron_browser_main_parts.cc)
- 就绪检查使用 `main` 和输入框语义节点，并确认主页面已换皮。登录或更新页面可能没有输入框，30 秒后自动继续。Windows 的焦点策略可能在测试中途切走焦点时阻止激活。
- 日文字形使用 Windows 系统字体。Logo 的轻微透视晃动以 WPF 平面变换近似。女声沿用原版入点和完整台词，后一句接替声道时可替换前一句的混响尾音。
- 自检使用相同的动画调度和资源解析，音频设备与真实 Codex 的启动、隐藏、激活、新窗口换皮留给联动验证。

## 本机验收记录

默认静音自检用时 22.17 秒，六边形交接跳过 3 个 60 Hz 逻辑帧。

三轮实际全屏联动均完成运行时换皮、主界面就绪、前台激活和截图。R2 在 90% 后进入等待，界面就绪后继续到 100%。最新 R3 在 13.100 秒就绪，14.050 秒同步完成，21.017 秒开始交接。

| 全屏联动 | 交接掉帧 | 交接帧间隔 p95 | 最长帧间隔 |
|---|---:|---:|---:|
| 首轮 | 25 | 48.49 ms | 78.78 ms |
| R2 | 13 | 30.30 ms | 72.72 ms |
| R3 | 14 | 30.30 ms | 42.42 ms |

R3 全屏各阶段掉帧 5–19 帧，1–2 帧目标未达到。R3 交接阶段 UI 更新 p95 为 0.09 ms。这项指标只衡量 UI 线程提交更新的时间，无法确定后续合成或显示环节的耗时。

R3 测试截图写入成功。当前 Codex 版本在 `Browser.close`、窗口关闭和断开私有管道后仍留有进程，测试以 `cleanup=forced` 清理它自己启动的实例。正常启动模式保留私有管道，直到 Codex 进程退出。

## 伊兹桌宠与人格（可选）

桌宠和启动器相互独立。导入已完成的图集与追加人格的步骤见仓库安装说明。Windows 人格文件为 `%USERPROFILE%\.codex\AGENTS.md`。请在修改前备份。Personalization 设置由用户在 Codex 内完成。 [安装说明](../INSTALL_FOR_CODEX.md) · [伊兹人格文件](../extras/izu-pet/PERSONALIZATION.md)

## 许可

Windows 源码放在 `windows/`，共用仓库的 `Resources/` 和 `Skin/`。提交 Windows 变更时，源文件和文档可放进版本控制。本地构建产物、联动截图和日志留在 `outputs/`。发布二进制前应单独核对随包素材的分发权利。

代码、皮肤、脚本和文档适用仓库 MIT 许可。第三方素材的许可见原清单。飞电 Logo、扫描光效和原声等素材仅供个人本地、非商业粉丝交流。 [MIT](../LICENSE) · [素材清单](../Resources/ASSET_MANIFEST.md) · [署名](../Resources/CREDITS.txt)
