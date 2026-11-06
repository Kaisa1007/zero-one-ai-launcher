# 实际使用的素材清单（自动生成）

生成脚本：`ZeroOneLauncher/Tools/prepare_assets.py`。Zero-One 美术 / 音频为 `license_unknown`，仅作个人本地原型；通用特效许可见下表与 `CREDITS.txt`。
构建阶段的 FFDec 命令（未打包进 App）：

- `ffdec -ignorebackground -zoom 3 -selectid 52,130 -format sprite:png,shape:png -export sprite,shape <temp dir> Assets/00_Originals/SWF/cometcomics_zero_one_flash_belt.swf`
- `ffdec -ignorebackground -selectid 52,130 -format sprite:svg,shape:svg -export sprite,shape <temp dir> Assets/00_Originals/SWF/cometcomics_zero_one_flash_belt.swf`

## 图片 / 特效

| App 资源 | 像素 | SHA-256 | 来源 | 许可 | 素材库对应文件 |
|---|---|---|---|---|---|
| `Images/hiden_logo_vec@3x.png` | 1885×542 | `25c82e62ebf11a45…` | SWF #52 | license_unknown | `Assets/03_Icons_Logos/hiden_intelligence_logo_white_swf.png` |
| `Images/scan_glow@3x.png` | 4348×179 | `9eaf3729a8106763…` | SWF #130 | license_unknown | `Assets/04_Henshin_Effects/green_scan_glow_horizontal_swf.png` |
| `Images/hiden_logo.png` | 629×181 | `1e708ae9f627078f…` | `03_Icons_Logos/hiden_intelligence_logo_white_swf.png` | license_unknown | `—` |
| `FX/fx_spark_01.png` | 512×512 | `ca5e7eac772d5af1…` | `Assets/12_VFX/01_Transparent_Particles/Kenney/kenney_spark_01.png` | CC0-1.0 | `—` |
| `FX/fx_star_01.png` | 512×512 | `4cd179dbc319bfbe…` | `Assets/12_VFX/01_Transparent_Particles/Kenney/kenney_star_01.png` | CC0-1.0 | `—` |
| `FX/fx_light_01.png` | 512×512 | `e15db5a8ccea012f…` | `Assets/12_VFX/01_Transparent_Particles/Kenney/kenney_light_01.png` | CC0-1.0 | `—` |
| `FX/fx_hex_mask.png` | 2048×2048 | `3fe6ab825a76b35f…` | `Assets/12_VFX/06_Derived_Masks/hexagon_baked_lighting_luminance_mask.png` | CC-BY-3.0 | `—` |

## 音频

| App 资源 | SWF 声音 | 播放区间（帧） | 时长 | SHA-256 | 来源 | 用途 |
|---|---|---|---|---|---|---|
| `Audio/driver_scan.wav` | 373 | 1156+95521 | 2.166 s | `c65f901f9671a692…` | `10_Audio/04_Processed_WAV/zero_one_driver_scan_swf_373.wav` | scan ('ZO Driver Sounds Scan'), shared |
| `Audio/authorize_common.wav` | 439 | 1156+54517 | 1.2362 s | `d7059512bc37342b…` | `10_Audio/04_Processed_WAV/progrise_key_common_authorize_swf_439.wav` | authorise voice ('PK Sounds Authorise'); both keys use this clip in the SWF (447 f7, 699 f9) |
| `Audio/driver_standby.wav` | 405 | 1156+153073 | 3.471 s | `a8602d796dcb0beb…` | `10_Audio/04_Processed_WAV/zero_one_driver_henshin_standby_swf_405.wav` | standby loop ('ZO Driver Standby Henshin', loop_count 32767), shared |
| `Audio/sfx_boot.wav` | — | 0+119070 | 2.7 s | `20dca27aae3dd006…` | `Tools/sfx_tool.swift` | HUD sound 'boot' (original, designed at build time) |
| `Audio/sfx_tick.wav` | — | 0+11907 | 0.27 s | `b5f8a4ecf325b8c0…` | `Tools/sfx_tool.swift` | HUD sound 'tick' (original, designed at build time) |
| `Audio/sfx_type.wav` | — | 0+7938 | 0.18 s | `9f73b36aaae5a68e…` | `Tools/sfx_tool.swift` | HUD sound 'type' (original, designed at build time) |
| `Audio/sfx_panel.wav` | — | 0+61740 | 1.4 s | `1f003408e1ad7b5b…` | `Tools/sfx_tool.swift` | HUD sound 'panel' (original, designed at build time) |
| `Audio/sfx_lock.wav` | — | 0+26460 | 0.6 s | `f2af9757ce0bfdc1…` | `Tools/sfx_tool.swift` | HUD sound 'lock' (original, designed at build time) |
| `Audio/sfx_swish.wav` | — | 0+44100 | 1.0 s | `2585ef2c91013cc3…` | `Tools/sfx_tool.swift` | HUD sound 'swish' (original, designed at build time) |
| `Audio/sfx_granted.wav` | — | 0+140200 | 3.1791 s | `80dffec167cae4f4…` | `Tools/sfx_tool.swift` | HUD sound 'granted' (original, designed at build time) |
| `Audio/sfx_chatter.wav` | — | 0+105840 | 2.4 s | `8d35312ad88fbd61…` | `Tools/sfx_tool.swift` | HUD sound 'chatter' (original, designed at build time) |
| `Audio/sfx_converge.wav` | — | 0+61740 | 1.4 s | `d765faf89a896d12…` | `Tools/sfx_tool.swift` | HUD sound 'converge' (original, designed at build time) |
| `Audio/sfx_boom.wav` | — | 0+142335 | 3.2276 s | `3117c9c87affb483…` | `Tools/sfx_tool.swift` | HUD sound 'boom' (original, designed at build time) |
| `Audio/sfx_shimmer.wav` | — | 0+96013 | 2.1772 s | `786bde41871bf567…` | `Tools/sfx_tool.swift` | HUD sound 'shimmer' (original, designed at build time) |
| `Audio/sfx_slam.wav` | — | 0+115506 | 2.6192 s | `c07c3e61c8036125…` | `Tools/sfx_tool.swift` | HUD sound 'slam' (original, designed at build time) |
| `Audio/sfx_flip.wav` | — | 0+92610 | 2.1 s | `8f0a9d592c477387…` | `Tools/sfx_tool.swift` | HUD sound 'flip' (original, designed at build time) |
| `Audio/sfx_whoosh.wav` | — | 0+79380 | 1.8 s | `8f3ca2ca534e1ae4…` | `Tools/sfx_tool.swift` | HUD sound 'whoosh' (original, designed at build time) |
| `Audio/voice_boot.wav` | — | 0+203040 | 4.6041 s | `8af237727a4610c1…` | `Assets/14_Voice/boot.mp3` | system voice 'boot' (mechanical / ethereal processing) |
| `Audio/voice_login.wav` | — | 0+167328 | 3.7943 s | `854b23731cb7cb92…` | `Assets/14_Voice/login.mp3` | system voice 'login' (mechanical / ethereal processing) |
| `Audio/voice_sync.wav` | — | 0+163872 | 3.7159 s | `8b71307842818a32…` | `Assets/14_Voice/sync.mp3` | system voice 'sync' (mechanical / ethereal processing) |
| `Audio/voice_sync_done.wav` | — | 0+128160 | 2.9061 s | `73f362db6f9d09f3…` | `Assets/14_Voice/sync_done.mp3` | system voice 'sync_done' (mechanical / ethereal processing) |
| `Audio/voice_granted.wav` | — | 0+132768 | 3.0106 s | `155e18a5dd8c2a23…` | `Assets/14_Voice/granted.mp3` | system voice 'granted' (mechanical / ethereal processing) |
| `Audio/voice_welcome.wav` | — | 0+167328 | 3.7943 s | `aee11b95026ac68c…` | `Assets/14_Voice/welcome.mp3` | system voice 'welcome' (mechanical / ethereal processing) |

完整 SHA-256、原始 MP3 路径和合成校验结果见 `manifest.json`。
