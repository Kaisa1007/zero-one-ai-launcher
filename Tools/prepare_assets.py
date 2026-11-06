#!/usr/bin/env python3
"""Build-time asset preparation for Zero-One AI Launcher.

Reads the untouched asset library in ../Assets and copies ONLY the files the app
uses into ZeroOneLauncher/Resources, with a provenance manifest (source path +
SHA-256). Nothing in Assets/ or work/ is modified.

Images: the SWF art in the library is 1x only, so the needed layers are re-rendered
at 3x (2x for the large VFX morphs) from the original SWF vectors with the FFDec copy
already in work/tools. This happens at build time only; FFDec / Java / the SWF are
NOT bundled. The Metal Cluster Hopper "in driver" frame (cover open, metal grip
removed) does not exist as a single SWF frame, so it is composited from the key's
own parts with their SWF placement matrices; the same composite with the grip is
checked against FFDec's frame 13 render.

usage: prepare_assets.py --tool <compiled Tools/asset_tool.swift>
"""
import argparse, hashlib, json, os, re, shutil, subprocess, sys, tempfile, wave, array, math
from pathlib import Path

HERE = Path(__file__).resolve().parent
APP_ROOT = HERE.parent                      # ZeroOneLauncher/
PROJECT = APP_ROOT.parent                   # project root
ASSETS = PROJECT / "Assets"
SWF = ASSETS / "00_Originals/SWF/cometcomics_zero_one_flash_belt.swf"
SWF_SHA = "e419af0de353c96b9defe718dfecd544387393489fb8a1885519eb9dc74ed8e4"
JAVA = PROJECT / "work/tools/jre/jdk-21.0.13+9-jre/Contents/Home/bin/java"
FFDEC = PROJECT / "work/tools/ffdec/ffdec.jar"
RAW_SWF_SOUNDS = PROJECT / "work/audio_swf_exports/sounds"       # FFDec raw MP3 exports of the same SWF
SOUND_INVENTORY = PROJECT / "work/audio/swf_sound_inventory.json"
OUT = APP_ROOT / "Resources"
ZOOM = 3

# SWF DefineSound seek samples (1685) count from raw decoder output. AudioToolbox
# (afconvert) already drops the standard 529-sample MP3 decoder delay, so in the WAVs
# the content starts at 1685 - 529 = 1156 (measured onsets 1158-1790 agree).
MP3_DECODER_DELAY = 529

# ---------------------------------------------------------------- keys
KEYS = {}   # the boot animation no longer shows Progrise keys
KEY_FRAMES = range(1, 14)   # 1..13: closed -> fully open. Later frames return to closed and are not used.
SHAPES = {
    "hiden_logo_vec": (52, "03_Icons_Logos/hiden_intelligence_logo_white_swf.png", "Hiden Intelligence logo (SWF vector shape 52, 3x)"),
    "scan_glow": (130, "04_Henshin_Effects/green_scan_glow_horizontal_swf.png", "horizontal green scan glow"),
}
LIBRARY_COPIES = {
    "hiden_logo": ("03_Icons_Logos/hiden_intelligence_logo_white_swf.png", "small brand mark (top-left)"),
}

# ---------------------------------------------------------------- VFX (generic, licensed)
VFX_COPIES = {
    # name: (library path, role)
    "fx_spark_01": ("12_VFX/01_Transparent_Particles/Kenney/kenney_spark_01.png", "electric spark particle (tinted at runtime)"),
    "fx_star_01": ("12_VFX/01_Transparent_Particles/Kenney/kenney_star_01.png", "glint particle"),
    "fx_light_01": ("12_VFX/01_Transparent_Particles/Kenney/kenney_light_01.png", "core light burst"),
    "fx_hex_mask": ("12_VFX/06_Derived_Masks/hexagon_baked_lighting_luminance_mask.png", "hexagon grid mask for the background glow (tinted)"),
}
# SWF morphs re-rendered at 2x (the library frames are 1x): FFDec -morphNumFrames 24 -morphDuration 0.8,
# the same sampling the library used. Only each sequence's nonblank_frame_range is copied.
MORPHS = {
}
MORPH_ZOOM = 2

# ---------------------------------------------------------------- rider elements
# (name, source in Assets/, optional derivation, role). A Real-ESRGAN x4 result in work/upscaled/<name>_x4.png
# (see SFX_AND_UPSCALE.md) replaces the source automatically.
RIDER = []   # no rider art in the boot animation any more (Hiden Intelligence login only)
UPSCALED = PROJECT / "work/upscaled"
# Optional downloaded interface sounds: Assets/13_SFX/<name>.(wav|mp3|aif|aiff|m4a|caf)
SFX_NAMES = ["boot", "tick", "type", "panel", "lock", "swish", "granted", "chatter", "converge", "boom", "shimmer", "slam", "flip", "whoosh"]
SFX_DIR = ASSETS / "13_SFX"
# System voice lines (clean recordings from the user, Assets/14_Voice/<name>.*), processed by Tools/voice_tool.swift.
VOICE_DIR = ASSETS / "14_Voice"
VOICE_NAMES = ["boot", "login", "sync", "sync_done", "granted", "welcome"]
VOICE_SETTINGS = APP_ROOT / "Tools/voice_settings.json"   # saved processing parameters + loudness targets
VOICE_KEYS = ["pitch_cents", "double_detune_cents", "double_level", "double_delay_ms", "distortion_mix", "slap_delay_mix", "reverb_wet"]

# ---------------------------------------------------------------- audio
AUDIO = [
    # id, SWF sound id, role.  Library WAV when catalogued, else raw SWF export (decoded here).
    ("driver_scan", 373, "scan ('ZO Driver Sounds Scan'), shared"),
    ("authorize_common", 439, "authorise voice ('PK Sounds Authorise'); both keys use this clip in the SWF (447 f7, 699 f9)"),
    ("driver_standby", 405, "standby loop ('ZO Driver Standby Henshin', loop_count 32767), shared"),
]


def sha256(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def rel(p):
    return os.path.relpath(p, PROJECT)


def png_size(p):
    with open(p, "rb") as f:
        head = f.read(24)
    return int.from_bytes(head[16:20], "big"), int.from_bytes(head[20:24], "big")


def svg_origin(p):
    """FFDec SVG: first <g transform="matrix(1,0,0,1,ox,oy)"> = position of the local origin in the canvas."""
    head = open(p, encoding="utf-8").read(2000)
    m = re.search(r'<g transform="matrix\(1\.0, 0\.0, 0\.0, 1\.0, (-?[\d.]+), (-?[\d.]+)\)"', head)
    return (float(m.group(1)), float(m.group(2))) if m else (0.0, 0.0)


def audible_window(path, thresh_db=-45.0):
    w = wave.open(str(path))
    n, ch, sr = w.getnframes(), w.getnchannels(), w.getframerate()
    d = array.array("h", w.readframes(n))
    win = sr // 100
    first = last = None
    for k in range(0, n - win, win):
        s = 0
        for j in range(k * ch, (k + win) * ch, 4 * ch):
            s += d[j] * d[j]
        db = 20 * math.log10(math.sqrt(s / (win / 4)) / 32768 + 1e-9)
        if db > thresh_db:
            if first is None:
                first = k
            last = k + win
    return n, sr, ch, first or 0, last or n


def ffdec(args, log):
    cmd = [str(JAVA), "-Xmx4g", "-Djava.awt.headless=true", f"-Duser.home={PROJECT / 'work/tools/java_home'}",
           "-jar", str(FFDEC)] + args
    with open(log, "a") as f:
        if subprocess.call(cmd, stdout=f, stderr=subprocess.STDOUT) != 0:
            sys.exit(f"FFDec failed, see {log}")
    shown = [a if not a.startswith("/") or a == str(SWF) else "<temp dir>" for a in args]
    return " ".join(shown).replace(str(PROJECT) + "/", "")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tool", required=True, help="compiled Tools/asset_tool.swift")
    ap.add_argument("--sfx-tool", required=True, help="compiled Tools/sfx_tool.swift (build-time sound design)")
    ap.add_argument("--voice-tool", required=True, help="compiled Tools/voice_tool.swift (system voice processing)")
    args = ap.parse_args()
    tool = args.tool
    if not JAVA.exists() or not FFDEC.exists():
        sys.exit(f"FFDec/Java not found ({FFDEC}). Resources/ already contains prepared files.")
    if sha256(SWF) != SWF_SHA:
        sys.exit("Source SWF hash mismatch; refusing to continue.")
    lib_index = {a["relative_path"]: a for a in json.load(open(ASSETS / "Metadata/assets.json"))}
    vfx_index = {a["path"]: a for a in json.load(open(ASSETS / "12_VFX/Metadata/vfx_assets.json"))}
    audio_index = {a["swf_sound_id"]: a for a in json.load(open(ASSETS / "10_Audio/Metadata/audio_assets.json"))}
    inventory = {s["id"]: s for s in json.load(open(SOUND_INVENTORY))["sounds"]}

    if OUT.exists():
        shutil.rmtree(OUT)
    for d in ("Images", "Audio", "FX"):
        (OUT / d).mkdir(parents=True)
    manifest = {"generated_by": rel(Path(__file__)), "image_scale": ZOOM, "images": [], "audio": [], "keys": {},
                "sequences": {}, "ffdec_commands": []}

    def add_image(name, src, role, source, counterpart=None, folder="Images", suffix="@3x", license="license_unknown"):
        dst = OUT / folder / f"{name}{suffix}.png"
        shutil.copyfile(src, dst)
        w, h = png_size(dst)
        entry = {"name": name, "file": f"{folder}/{dst.name}", "sha256": sha256(dst), "pixel_size": [w, h],
                 "role": role, "source": source, "license_status": license}
        if counterpart:
            cp = ASSETS / counterpart
            entry["library_counterpart_1x"] = {"path": rel(cp), "resolved": rel(Path(os.path.realpath(cp))), "sha256": sha256(cp)}
        manifest["images"].append(entry)
        return dst

    def bbox(p):
        x, y, w, h = map(int, subprocess.check_output([tool, "bbox", str(p)]).split())
        return [round(x / ZOOM, 2), round(y / ZOOM, 2), round(w / ZOOM, 2), round(h / ZOOM, 2)]

    with tempfile.TemporaryDirectory() as t:
        tmp = Path(t)
        log = tmp / "ffdec.log"
        sprite_ids = sorted({k["sprite"] for k in KEYS.values()})
        shape_ids = sorted({s[0] for s in SHAPES.values()})
        sel = ",".join(map(str, sprite_ids + shape_ids))
        manifest["ffdec_commands"].append(ffdec(["-ignorebackground", "-zoom", str(ZOOM), "-selectid", sel,
            "-format", "sprite:png,shape:png", "-export", "sprite,shape", str(tmp / "png"), str(SWF)], log))
        manifest["ffdec_commands"].append(ffdec(["-ignorebackground", "-selectid", sel,
            "-format", "sprite:svg,shape:svg", "-export", "sprite,shape", str(tmp / "svg"), str(SWF)], log))
        if MORPHS:   # none at the moment (the card wipe is drawn by the GPU)
            manifest["ffdec_commands"].append(ffdec(["-zoom", str(MORPH_ZOOM), "-selectid", ",".join(str(m[0]) for m in MORPHS.values()),
                "-morphNumFrames", "24", "-morphDuration", "0.8", "-format", "morphshape:png_frames", "-export", "morphshape",
                str(tmp / "morph"), str(SWF)], log))
        png = lambda kind, i, f=None: tmp / "png" / (f"sprites/DefineSprite_{i}/{f}.png" if kind == "sprite" else f"shapes/{i}.png")
        svg = lambda kind, i, f=None: tmp / "svg" / (f"sprites/DefineSprite_{i}/{f}.svg" if kind == "sprite" else f"shapes/{i}.svg")
        swf_src = lambda rid, extra=None: dict({"swf": rel(SWF), "swf_sha256": SWF_SHA, "resource_id": rid}, **(extra or {}))

        # Keys
        for key, info in KEYS.items():
            sid, prefix = info["sprite"], info["prefix"]
            origin = svg_origin(svg("sprite", sid, 1))
            for f in KEY_FRAMES:
                cp = f"{info['library_anim']}/frame_{f:04d}.png" if "library_anim" in info else (info.get("library_closed") if f == 1 else None)
                add_image(f"{prefix}_f{f:02d}", png("sprite", sid, f), f"{key} key, open sequence frame {f}/13",
                          swf_src(sid, {"frame": f, "method": f"FFDec sprite frame render, zoom {ZOOM}"}), cp)
            spec = {"sprite": sid, "frames": len(KEY_FRAMES),
                    "canvas_offset": [-origin[0], -origin[1]],         # canvas top-left in sprite coords
                    "closed_bbox": bbox(png("sprite", sid, 1)), "open_bbox": bbox(png("sprite", sid, 13))}
            manifest["keys"][key] = spec

        for name, (sid, counterpart, role) in SHAPES.items():
            add_image(name, png("shape", sid), role, swf_src(sid, {"method": f"FFDec shape render, zoom {ZOOM}"}), counterpart)

        # Morph VFX at 2x
        for name, (rid, libdir, role) in MORPHS.items():
            seq = json.load(open(ASSETS / libdir / "sequence.json"))
            a, b = seq["nonblank_frame_range"]
            for f in range(a, b + 1):
                add_image(f"{name}_f{f:02d}", tmp / "morph" / str(rid) / f"{f}_of_24.png", role,
                          swf_src(rid, {"frame": f, "method": f"FFDec morphshape png_frames 24 @ 0.8 s, zoom {MORPH_ZOOM}"}),
                          f"{libdir}/frame_{f:04d}.png", folder="FX", suffix="@2x")
            cw, ch = seq["canvas"]
            manifest["sequences"][name] = {"resource_id": rid, "frames": [a, b], "fps": 30, "canvas_1x": [cw, ch],
                                           "scale": MORPH_ZOOM, "timing_origin": seq["timing_origin"],
                                           "library_sequence": f"Assets/{libdir}/sequence.json"}

    for name, (p, role) in LIBRARY_COPIES.items():
        src = Path(os.path.realpath(ASSETS / p))
        dst = OUT / "Images" / f"{name}.png"
        shutil.copyfile(src, dst)
        manifest["images"].append({"name": name, "file": f"Images/{dst.name}", "sha256": sha256(dst),
                                   "pixel_size": list(png_size(dst)), "role": role,
                                   "source": {"library_path": p, "resolved": rel(src), "sha256": sha256(src),
                                              "asset_id": lib_index.get(p, {}).get("asset_id")},
                                   "license_status": "license_unknown"})

    for name, p, derive, role in RIDER:
        src = Path(os.path.realpath(ASSETS / p))
        up = UPSCALED / f"{name}_x4.png"
        dst = OUT / "Images" / f"{name}.png"
        info = {"library_path": f"Assets/{p}", "resolved": rel(src), "sha256": sha256(src)}
        if up.exists():
            shutil.copyfile(up, dst)
            info["upscaled"] = {"file": rel(up), "sha256": sha256(up), "method": "Real-ESRGAN ncnn-vulkan x4 (run on this Mac)"}
            scale = 4
        elif derive:
            subprocess.check_call([tool, derive[0], str(src), str(dst)] + list(derive[1:]), stdout=subprocess.DEVNULL)
            info["derived"] = f"asset_tool {' '.join(derive)} (alpha threshold + largest region, no resampling)"
            scale = 1
        else:
            shutil.copyfile(src, dst)
            scale = 1
        manifest["images"].append({"name": name, "file": f"Images/{dst.name}", "sha256": sha256(dst), "pixel_size": list(png_size(dst)),
                                   "scale": scale, "role": role, "source": info, "license_status": "license_unknown"})

    for name, (p, role) in VFX_COPIES.items():
        src = Path(os.path.realpath(ASSETS / p))
        meta = vfx_index.get(p) or vfx_index.get("Assets/" + p) or {}
        assert meta, f"{p} not in vfx_assets.json"
        dst = OUT / "FX" / f"{name}.png"
        shutil.copyfile(src, dst)
        assert not meta.get("sha256") or meta["sha256"] == sha256(dst), f"hash mismatch {p}"
        manifest["images"].append({"name": name, "file": f"FX/{dst.name}", "sha256": sha256(dst),
                                   "pixel_size": list(png_size(dst)), "role": role,
                                   "source": {"library_path": f"Assets/{p}", "resolved": rel(src), "author": meta.get("author"),
                                              "source_page": meta.get("source_page"), "asset_id": meta.get("asset_id")},
                                   "license_status": meta.get("license_status", "see Assets/12_VFX/Metadata/Licenses"),
                                   "attribution": meta.get("attribution")})

    with tempfile.TemporaryDirectory() as t:
        for cid, sound_id, role in AUDIO:
            dst = OUT / "Audio" / f"{cid}.wav"
            a = audio_index.get(sound_id)
            if a:
                src = Path(os.path.realpath(ASSETS / a["wav_path"]))
                shutil.copyfile(src, dst)
                assert sha256(dst) == a["wav_sha256"], f"hash mismatch {dst}"
                declared, seek = a["source_declared_samples"], a["source_mp3_seek_samples"]
                source = {"library_wav": a["wav_path"], "resolved": rel(src), "wav_sha256_in_library": a["wav_sha256"],
                          "original_mp3": a["original_path"], "original_mp3_sha256": a["original_sha256"],
                          "timeline_uses": a.get("all_source_timeline_uses")}
            else:
                # Not catalogued in Assets/10_Audio: raw MP3 exported earlier from the same SWF by FFDec.
                raw = RAW_SWF_SOUNDS / f"{sound_id}.mp3"
                inv = inventory[sound_id]
                subprocess.check_call(["afconvert", "-f", "WAVE", "-d", "LEI16", str(raw), str(dst)])
                declared, seek = inv["declared_samples"], inv["mp3_seek_samples"]
                source = {"raw_swf_export_mp3": rel(raw), "raw_mp3_sha256": sha256(raw), "swf": rel(SWF), "swf_sha256": SWF_SHA,
                          "decoder": "macOS afconvert (same as the library WAVs), PCM 16-bit, no resample / gain change",
                          "timeline_uses": inv.get("uses"), "note": "not in the curated audio library; extracted from the same SWF"}
            n, sr, ch, first, last = audible_window(dst)
            start = seek - MP3_DECODER_DELAY
            length = min(declared, n - start)
            manifest["audio"].append({
                "id": cid, "file": f"Audio/{dst.name}", "sha256": sha256(dst), "role": role, "swf_sound_id": sound_id,
                "sample_rate": sr, "channels": ch, "wav_frames": n, "swf_declared_samples": declared, "swf_mp3_seek_samples": seek,
                "play_start_frame": start, "play_frame_count": length, "play_duration_s": round(length / sr, 4),
                "audible_onset_s": round(first / sr, 3), "audible_end_s": round(last / sr, 3), "source": source,
                "audition_status": "not_listened (no audio-understanding tool available)", "license_status": "license_unknown"})

    # Optional downloaded interface sounds (else the app synthesises them).
    # HUD sounds: a downloaded file in Assets/13_SFX/<name>.* wins; otherwise the build-time design (Tools/sfx_tool.swift).
    for name in SFX_NAMES:
        src = None
        if SFX_DIR.exists():
            src = next((f for f in sorted(SFX_DIR.iterdir()) if f.stem == name and f.suffix.lower() in (".wav", ".mp3", ".aif", ".aiff", ".m4a", ".caf")), None)
        dst = OUT / "Audio" / f"sfx_{name}.wav"
        if src:
            subprocess.check_call(["afconvert", "-f", "WAVE", "-d", "LEI16@44100", "-c", "2", str(src), str(dst)])
            role, source, lic = f"HUD sound '{name}' (downloaded)", {"file": rel(src), "sha256": sha256(src)}, "see Assets/13_SFX"
        else:
            subprocess.check_call([args.sfx_tool, str(OUT / "Audio"), name], stdout=subprocess.DEVNULL)
            role, source, lic = f"HUD sound '{name}' (original, designed at build time)", {"generator": "Tools/sfx_tool.swift", "recipe": name}, "original"
        n, sr, ch, first, last = audible_window(dst)
        manifest["audio"].append({"id": f"sfx_{name}", "file": f"Audio/{dst.name}", "sha256": sha256(dst),
                                  "role": role, "sample_rate": sr, "channels": ch, "wav_frames": n,
                                  "play_start_frame": 0, "play_frame_count": n, "play_duration_s": round(n / sr, 4),
                                  "audible_onset_s": round(first / sr, 3), "audible_end_s": round(last / sr, 3),
                                  "source": source, "license_status": lic})

    # System voice: clean recording -> mechanical / ethereal processing. speech_end_s = end of the words in the
    # dry recording (the processed file adds a reverb tail after it).
    if VOICE_DIR.exists():
        sys.path.insert(0, str(APP_ROOT / "Tools"))
        from loudness import gated_rms_dbfs, scale_wav
        vs = json.load(open(VOICE_SETTINGS))
        vopts = [f"{k}={vs[k]}" for k in VOICE_KEYS]
        for name in VOICE_NAMES:
            src = next((f for f in sorted(VOICE_DIR.iterdir()) if f.stem == name and f.suffix.lower() in (".wav", ".mp3", ".aif", ".aiff", ".m4a", ".caf")), None)
            if not src:
                continue
            dst = OUT / "Audio" / f"voice_{name}.wav"
            subprocess.check_call([args.voice_tool, str(src), str(dst)] + vopts, stdout=subprocess.DEVNULL)
            # Same loudness whatever the effect amount: match the saved gated-RMS target of this line.
            target = vs.get("loudness_dbfs", {}).get(name)
            if target is not None:
                scale_wav(dst, 10 ** ((target - gated_rms_dbfs(dst)) / 20))
            with tempfile.TemporaryDirectory() as t:
                dry = Path(t) / "dry.wav"
                subprocess.check_call(["afconvert", "-f", "WAVE", "-d", "LEI16@44100", str(src), str(dry)])
                _, dsr, _, _, dlast = audible_window(dry)
            n, sr, ch, first, last = audible_window(dst)
            manifest["audio"].append({"id": f"voice_{name}", "file": f"Audio/{dst.name}", "sha256": sha256(dst),
                                      "role": f"system voice '{name}' (mechanical / ethereal processing)", "sample_rate": sr, "channels": ch,
                                      "wav_frames": n, "play_start_frame": 0, "play_frame_count": n, "play_duration_s": round(n / sr, 4),
                                      "audible_onset_s": round(first / sr, 3), "audible_end_s": round(last / sr, 3), "speech_end_s": round(dlast / dsr, 3),
                                      "source": {"file": rel(src), "sha256": sha256(src),
                                                 "processing": "Tools/voice_tool.swift " + " ".join(vopts), "preset": vs.get("preset"),
                                                 "loudness_target_dbfs": target, "loudness_dbfs": round(gated_rms_dbfs(dst), 2)},
                                      "license_status": "user's ElevenLabs plan (see Assets/14_Voice/SOURCES.md)"})

    write_credits()
    json.dump(manifest, open(OUT / "manifest.json", "w"), indent=1, ensure_ascii=False)
    write_markdown(manifest)
    print(f"images: {len(manifest['images'])}, audio: {len(manifest['audio'])} -> {rel(OUT)}")


def write_credits():
    txt = """Zero-One AI Launcher — credits (personal local prototype)

Generic VFX textures:
- Kenney Particle Pack — Kenney Vleugels (kenney.nl), CC0 1.0. Unchanged; tinted at runtime.
- Free UI Hologram Interface — Wenrexa (opengameart.org/content/free-ui-hologram-interface), CC0. Unchanged.
- Sci-Fi Hexagon Texture — Dustin 'Crimzan' Ludwig (opengameart.org/content/sci-fi-hexagon-texture), CC-BY 3.0
  (creativecommons.org/licenses/by/3.0/). Changes: the baked-lighting map was converted to a white
  luminance-to-alpha mask (asset library); the app tints it and fades it in as a background glow.

Hiden Intelligence logo, scan glow, wipe animation and the scan / authorise / standby audio: extracted from
the CometComics Zero-One Flash belt simulator. License unknown - not cleared for redistribution; all rights
belong to their owners (Toei / Ishimori Pro / Bandai). Personal local prototype only.
"""
    (OUT / "CREDITS.txt").write_text(txt, encoding="utf-8")


def write_markdown(m):
    L = ["# 实际使用的素材清单（自动生成）", "",
         f"生成脚本：`{m['generated_by']}`。Zero-One 美术 / 音频为 `license_unknown`，仅作个人本地原型；通用特效许可见下表与 `CREDITS.txt`。",
         "构建阶段的 FFDec 命令（未打包进 App）：", ""] + [f"- `ffdec {c}`" for c in m["ffdec_commands"]] + [
         "", "## 图片 / 特效", "", "| App 资源 | 像素 | SHA-256 | 来源 | 许可 | 素材库对应文件 |", "|---|---|---|---|---|---|"]
    for i in m["images"]:
        s = i["source"]
        if "resource_id" in s:
            src = f"SWF #{s['resource_id']}" + (f" 帧 {s['frame']}" if "frame" in s else "") + (" 合成" if "composite" in s.get("method", "") else "")
        else:
            src = f"`{s['library_path']}`"
        cp = i.get("library_counterpart_1x", {}).get("path", "—")
        L.append(f"| `{i['file']}` | {i['pixel_size'][0]}×{i['pixel_size'][1]} | `{i['sha256'][:16]}…` | {src} | {i['license_status']} | `{cp}` |")
    L += ["", "## 音频", "", "| App 资源 | SWF 声音 | 播放区间（帧） | 时长 | SHA-256 | 来源 | 用途 |", "|---|---|---|---|---|---|---|"]
    for a in m["audio"]:
        src = a["source"].get("library_wav") or a["source"].get("raw_swf_export_mp3") or a["source"].get("file") or a["source"].get("generator")
        L.append(f"| `{a['file']}` | {a.get('swf_sound_id', '—')} | {a['play_start_frame']}+{a['play_frame_count']} | "
                 f"{a['play_duration_s']} s | `{a['sha256'][:16]}…` | `{src}` | {a['role']} |")
    L += ["", "完整 SHA-256、原始 MP3 路径和合成校验结果见 `manifest.json`。", ""]
    (OUT / "ASSET_MANIFEST.md").write_text("\n".join(L), encoding="utf-8")


if __name__ == "__main__":
    main()
