#!/usr/bin/env python3

# Smart Video Encoder Library for macOS
# Copyright (c) 2025 Rodrigo Polo
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND.

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Optional

TOLERANCE = 1  # seconds
COLORS = ["no", "orange", "red", "yellow", "blue", "purple", "green", "gray"]
PRESETS = ["ultrafast", "superfast", "veryfast", "faster", "fast", "medium", "slow", "slower", "veryslow"]

# mediainfo → ffmpeg color metadata token mappings
_TRANSFER_MAP: dict[str, str] = {
    "HLG": "arib-std-b67",
    "SMPTE ST 2084": "smpte2084",
    "BT.709": "bt709",
    "BT.2020 (10-bit)": "bt2020-10",
    "BT.2020 (12-bit)": "bt2020-12",
    "Gamma 2.4": "bt470bg",
    "Gamma 2.2": "bt470m",
}
_PRIMARIES_MAP: dict[str, str] = {
    "BT.2020": "bt2020",
    "BT.709": "bt709",
    "Display P3": "smpte432",
    "DCI P3": "smpte431",
}
_MATRIX_MAP: dict[str, str] = {
    "BT.2020 non-constant": "bt2020nc",
    "BT.2020 constant": "bt2020c",
    "BT.709": "bt709",
}
_RANGE_MAP: dict[str, str] = {"Limited": "tv", "Full": "pc"}
_SDR_TOKENS = {"bt709", "bt470bg", "bt470m", "smpte170m", "smpte240m", ""}


@dataclass
class EncoderConfig:
    codec_label: str          # "HEVC" or "AVC"
    ffmpeg_codec: str         # "libx265" or "libx264"
    default_crf: int
    crf_min: int
    crf_max: int
    default_preset: str
    default_output_suffix: str
    skip_codec_ids: list[str]
    codec_tag: Optional[str] = None  # "hvc1" for HEVC, None for AVC
    supports_hdr: bool = False        # True for HEVC only

    # Runtime state set during main()
    crf: int = 0
    preset: str = ""
    output_suffix: str = ""
    original_suffix: str = ".done"
    skip: bool = False
    deinterlace: bool = False
    verbose: bool = False
    copy_dates: bool = False
    copy_tags: bool = False
    copy_comments: bool = False
    copy_permissions: bool = False
    after_encode: str = ""
    tag_color: str = "green"
    max_width: int = 0
    max_height: int = 0
    flip_rotate: str = ""
    no_video: bool = False
    no_audio: bool = False
    files: list[str] = field(default_factory=list)
    ffmpeg_path: str = ""
    fftool: str = ""


# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

def log(msg: str, config: EncoderConfig) -> None:
    if config.verbose:
        ts = datetime.now().strftime("%H:%M:%S")
        print(f"[{ts}] {msg}", file=sys.stderr)


def error(msg: str) -> None:
    print(f"[ERROR] {msg}", file=sys.stderr)


# ---------------------------------------------------------------------------
# Tool discovery
# ---------------------------------------------------------------------------

def find_tool(name: str) -> Optional[str]:
    path = shutil.which(name)
    if path:
        return path
    for candidate in [
        f"/opt/homebrew/bin/{name}",
        f"{Path.home()}/.local/bin/{name}",
        f"/usr/local/bin/{name}",
        f"/usr/bin/{name}",
    ]:
        if os.access(candidate, os.X_OK):
            return candidate
    return None


def check_dependencies() -> None:
    missing = [t for t in ("mediainfo", "ffmpeg") if find_tool(t) is None]
    if missing:
        lines = [f"Missing required tools: {', '.join(missing)}", "", "Installation suggestions:"]
        for t in missing:
            if t == "mediainfo":
                lines.append("  - Install MediaInfo:\n    brew install mediainfo")
            elif t == "ffmpeg":
                lines.append("  - Install FFmpeg:\n    brew install ffmpeg")
        raise SystemExit("\n".join(lines))


# ---------------------------------------------------------------------------
# File validation
# ---------------------------------------------------------------------------

def validate_video_file(path: str) -> None:
    p = Path(path)
    if not p.exists():
        raise ValueError(f"File '{path}' does not exist")
    if not os.access(path, os.R_OK):
        raise ValueError(f"File '{path}' is not readable")
    result = subprocess.run(
        ["mediainfo", path],
        capture_output=True, text=True
    )
    if "Video" not in result.stdout.splitlines():
        raise ValueError(f"File '{path}' doesn't appear to be a valid video")


# ---------------------------------------------------------------------------
# Filter builders
# ---------------------------------------------------------------------------

def get_resize_filter(width: int, height: int, max_w: int, max_h: int, config: EncoderConfig) -> str:
    if max_w <= 0 or max_h <= 0:
        return ""
    if width >= height:
        log(f"Horizontal video", config)
        if width > max_w or height > max_h:
            log(f"Resolution exceeds {max_w}x{max_h} limit.", config)
            new_w = max_w
            new_h = (int(height * max_w / width) // 2) * 2
            return f"scale={new_w}:{new_h},setsar=1:1"
    else:
        log("Vertical video", config)
        if width > max_h or height > max_w:
            log(f"Resolution exceeds {max_h}x{max_w} limit.", config)
            new_h = max_w
            new_w = (int(width * max_w / height) // 2) * 2
            return f"scale={new_w}:{new_h},setsar=1:1"
    return ""


def get_rotate_filter(flip_rotate: str) -> str:
    return {
        "right": "transpose=1",
        "left": "transpose=2",
        "upside-down": "transpose=1,transpose=1",
        "horizontal": "hflip",
        "vertical": "vflip",
    }.get(flip_rotate, "")


# ---------------------------------------------------------------------------
# Audio codec argument builder
# ---------------------------------------------------------------------------

def get_audio_codec_args(json_info: dict, config: EncoderConfig) -> list[str]:
    tracks = [t for t in json_info.get("media", {}).get("track", []) if t.get("@type") == "Audio"]
    if not tracks:
        log("No audio tracks found. Creating video-only output.", config)
        return []

    log("Processing audio tracks...", config)
    args: list[str] = []

    for idx, track in enumerate(tracks):
        track_id = track.get("ID", str(idx))
        fmt = track.get("Format", "Unknown")
        lang = track.get("Language") or "und"
        if lang == "null":
            lang = "und"

        # Resolve channel count
        raw_ch = (
            track.get("Channels")
            or track.get("channel_s")
            or track.get("Channels_Original")
            or "2"
        )
        if raw_ch in (None, "null"):
            raw_ch = "2"
        if raw_ch == "Mono":
            channels = 1
        elif raw_ch == "Stereo":
            channels = 2
        else:
            digits = re.sub(r"[^0-9]", "", str(raw_ch))
            channels = int(digits) if digits else 2

        log(f"  Track ID: {track_id}, Format: {fmt}, Channels: {channels}, Language: {lang}", config)

        i = str(idx)
        if channels == 1:
            args += [f"-c:a:{i}", "aac", f"-b:a:{i}", "64k", f"-ac:a:{i}", "1"]
            log(f"  Setting mono AAC (64k) for track {track_id}", config)
        elif channels == 2:
            args += [f"-c:a:{i}", "aac", f"-b:a:{i}", "128k", f"-ac:a:{i}", "2"]
            log(f"  Setting stereo AAC (128k) for track {track_id}", config)
        elif channels == 6:
            if fmt in ("AC-3", "E-AC-3"):
                args += [f"-c:a:{i}", "aac", f"-b:a:{i}", "384k",
                         f"-filter:a:{i}", "channelmap=channel_layout=5.1"]
                log(f"  Setting 5.1 AAC (384k) with AC-3 channel mapping for track {track_id}", config)
            elif fmt == "DTS":
                args += [f"-c:a:{i}", "aac", f"-b:a:{i}", "384k",
                         f"-filter:a:{i}", "channelmap=channel_layout=5.1:map=1|2|0|5|3|4"]
                log(f"  Setting 5.1 AAC (384k) with DTS channel remapping for track {track_id}", config)
            else:
                args += [f"-c:a:{i}", "aac", f"-b:a:{i}", "384k",
                         f"-filter:a:{i}", "channelmap=channel_layout=5.1"]
                log(f"  Setting 5.1 AAC (384k) with generic 5.1 mapping for track {track_id}", config)
        elif channels > 6:
            args += [f"-c:a:{i}", "aac", f"-b:a:{i}", "384k",
                     f"-filter:a:{i}", "pan=5.1|FL=FL|FR=FR|FC=FC|LFE=LFE|BL=SL+BL|BR=SR+BR"]
            log(f"  Setting downmixed 5.1 AAC (384k) for track {track_id}", config)
        else:
            args += [f"-c:a:{i}", "aac", f"-b:a:{i}", "128k", f"-ac:a:{i}", "2"]
            log(f"  Setting downmixed stereo AAC (128k) for track {track_id}", config)

        if lang != "und":
            args += [f"-metadata:s:a:{i}", f"language={lang}"]

    return args


# ---------------------------------------------------------------------------
# macOS attribute copying
# ---------------------------------------------------------------------------

def copy_attributes(src: str, dst: str, config: EncoderConfig) -> None:
    if config.copy_dates:
        st = os.stat(src)
        os.utime(dst, (st.st_atime, st.st_mtime))

    if config.copy_tags:
        mdls = subprocess.run(
            ["mdls", "-plist", "-", "-name", "_kMDItemUserTags", src],
            capture_output=True
        )
        plutil = subprocess.run(
            ["plutil", "-convert", "json", "-o", "-", "-"],
            input=mdls.stdout, capture_output=True, text=True
        )
        if plutil.returncode == 0 and plutil.stdout.strip():
            try:
                data = json.loads(plutil.stdout)
                tags = data.get("_kMDItemUserTags", data) if isinstance(data, dict) else data
                if tags:
                    tag_str = "(" + ",".join(f'"{t}"' for t in tags) + ")"
                    subprocess.run(
                        ["xattr", "-w", "com.apple.metadata:_kMDItemUserTags", tag_str, dst],
                        check=False
                    )
            except (json.JSONDecodeError, TypeError):
                pass

    if config.copy_comments:
        get_comment = subprocess.run(
            ["osascript", "-e",
             f'tell application "Finder" to get comment of (POSIX file "{src}" as alias)'],
            capture_output=True, text=True
        )
        comment = get_comment.stdout.strip()
        if comment:
            subprocess.run(
                ["osascript", "-e",
                 f'tell application "Finder" to set comment of (POSIX file "{dst}" as alias) to "{comment}"'],
                capture_output=True
            )

    if config.copy_permissions:
        src_mode = os.stat(src).st_mode & 0o777
        os.chmod(dst, src_mode)


def set_color_tag(file_path: str, color_name: str) -> None:
    idx = COLORS.index(color_name) if color_name in COLORS else 0
    result = subprocess.run(
        ["osascript", "-e",
         f'tell application "Finder" to set label index of (POSIX file "{file_path}" as alias) to {idx}'],
        capture_output=True
    )
    if result.returncode == 0:
        print(f"Set color label '{color_name}' (index {idx}) for '{file_path}'")
    else:
        print(f"Error: Failed to set color label for '{file_path}'", file=sys.stderr)


def after_encoding(input_path: Path, config: EncoderConfig) -> None:
    if not config.after_encode:
        return
    action = config.after_encode
    if action == "label":
        log("Setting color tag", config)
        set_color_tag(str(input_path), config.tag_color)
    elif action == "rename":
        renamed = input_path.with_name(input_path.stem + config.original_suffix + input_path.suffix)
        print(f"⚠️  Renaming original to {renamed.name}", file=sys.stderr)
        input_path.rename(renamed)
    elif action == "delete":
        print("❗️ Deleting original", file=sys.stderr)
        input_path.unlink()


# ---------------------------------------------------------------------------
# HDR detection and argument building
# ---------------------------------------------------------------------------

def _parse_mastering_display(vt: dict) -> str:
    """Parse mediainfo mastering display fields into x265-params master-display string.

    Returns "" if the fields are absent or unparseable.
    """
    raw_primaries = vt.get("MasteringDisplay_ColorPrimaries", "")
    raw_luminance = vt.get("MasteringDisplay_Luminance", "")
    if not raw_primaries or not raw_luminance:
        return ""
    try:
        # Parse chromaticity coords from:
        # "R: x=0.680000 y=0.320000, G: x=0.265000 y=0.690000, B: x=0.150000 y=0.060000, White point: x=0.312700 y=0.329000"
        def _xy(label: str) -> tuple[int, int]:
            pattern = rf"{label}.*?x=([\d.]+).*?y=([\d.]+)"
            m = re.search(pattern, raw_primaries, re.IGNORECASE)
            if not m:
                raise ValueError(f"Missing {label} in mastering primaries")
            return round(float(m.group(1)) * 50000), round(float(m.group(2)) * 50000)

        rx, ry = _xy("R:")
        gx, gy = _xy("G:")
        bx, by = _xy("B:")
        wx, wy = _xy("White point")

        # Parse luminance from: "min: 0.010000 cd/m2, max: 1000 cd/m2"
        lum_m = re.search(r"min:\s*([\d.]+).*?max:\s*([\d.]+)", raw_luminance, re.IGNORECASE)
        if not lum_m:
            raise ValueError("Cannot parse mastering luminance")
        lum_min = round(float(lum_m.group(1)) * 10000)
        lum_max = round(float(lum_m.group(2)) * 10000)

        return f"G({gx},{gy})B({bx},{by})R({rx},{ry})WP({wx},{wy})L({lum_max},{lum_min})"
    except (ValueError, AttributeError):
        return ""


def detect_hdr(vt: dict) -> dict:
    """Detect HDR metadata from a mediainfo Video track dict.

    Returns a dict with ffmpeg tokens and flags describing the color space.
    """
    transfer_raw = vt.get("transfer_characteristics", "")
    primaries_raw = vt.get("colour_primaries", "")
    matrix_raw = vt.get("matrix_coefficients", "")
    range_raw = vt.get("colour_range", "")
    bit_depth = int(re.sub(r"[^0-9]", "", str(vt.get("BitDepth", "8"))) or "8")

    transfer = _TRANSFER_MAP.get(transfer_raw, "")
    primaries = _PRIMARIES_MAP.get(primaries_raw, "")
    colorspace = _MATRIX_MAP.get(matrix_raw, "")
    color_range = _RANGE_MAP.get(range_raw, "tv")

    is_hdr10 = transfer == "smpte2084"
    is_hlg = transfer == "arib-std-b67"
    is_hdr = (
        transfer not in _SDR_TOKENS
        or primaries not in _SDR_TOKENS
        or colorspace not in _SDR_TOKENS
    ) and bool(transfer or primaries or colorspace)

    master_display = _parse_mastering_display(vt) if is_hdr10 else ""
    max_cll = re.sub(r"[^0-9]", "", str(vt.get("MaxCLL", "")))
    max_fall = re.sub(r"[^0-9]", "", str(vt.get("MaxFALL", "")))
    pix_fmt = "yuv420p10le" if bit_depth >= 10 else "yuv420p"

    return {
        "is_hdr": is_hdr,
        "is_hdr10": is_hdr10,
        "is_hlg": is_hlg,
        "pix_fmt": pix_fmt,
        "transfer": transfer,
        "primaries": primaries,
        "colorspace": colorspace,
        "color_range": color_range,
        "master_display": master_display,
        "max_cll": max_cll,
        "max_fall": max_fall,
    }


def get_hdr_video_args(hdr: dict, ffmpeg_codec: str) -> list[str]:
    """Return the extra ffmpeg args needed to preserve HDR color metadata."""
    args: list[str] = []
    if hdr["primaries"]:
        args += ["-color_primaries", hdr["primaries"]]
    if hdr["transfer"]:
        args += ["-color_trc", hdr["transfer"]]
    if hdr["colorspace"]:
        args += ["-colorspace", hdr["colorspace"]]
    args += ["-color_range", hdr["color_range"]]

    # HDR10 + libx265: embed SEI mastering display metadata
    if hdr["is_hdr10"] and ffmpeg_codec == "libx265":
        params = ["hdr-opt=1", "repeat-headers=1"]
        if hdr["primaries"]:
            params.append(f"colorprim={hdr['primaries']}")
        if hdr["transfer"]:
            params.append(f"transfer={hdr['transfer']}")
        if hdr["colorspace"]:
            params.append(f"colormatrix={hdr['colorspace']}")
        if hdr["master_display"]:
            params.append(f"master-display={hdr['master_display']}")
        if hdr["max_cll"] and hdr["max_fall"]:
            params.append(f"max-cll={hdr['max_cll']},{hdr['max_fall']}")
        args += ["-x265-params", ":".join(params)]

    return args


# ---------------------------------------------------------------------------
# Core encode function
# ---------------------------------------------------------------------------

def encode(input_file: str, config: EncoderConfig) -> None:
    input_path = Path(input_file).resolve()
    output_path = input_path.parent / (input_path.stem + config.output_suffix + ".mp4")

    log(f"=== Processing: {input_file} ===", config)

    # Analyse with mediainfo
    result = subprocess.run(
        ["mediainfo", "--Output=JSON", input_file],
        capture_output=True, text=True, check=True
    )
    json_info = json.loads(result.stdout)
    tracks = json_info.get("media", {}).get("track", [])

    video_tracks = [t for t in tracks if t.get("@type") == "Video"]
    if not video_tracks:
        raise RuntimeError(f"No video track found in '{input_file}'")
    vt = video_tracks[0]

    # Codec detection for skip
    codec_format = vt.get("Format", "")
    codec_id = vt.get("CodecID", "")
    already_target = codec_format in config.skip_codec_ids or codec_id in config.skip_codec_ids

    # Dimensions
    raw_w = re.sub(r"[^0-9]", "", str(vt.get("Width", "0")))
    raw_h = re.sub(r"[^0-9]", "", str(vt.get("Height", "0")))
    input_width = int(raw_w) if raw_w else 0
    input_height = int(raw_h) if raw_h else 0
    original_duration = float(vt.get("Duration") or 0)

    log(f"Current dimensions: {input_width}x{input_height}", config)

    resize_filter = get_resize_filter(input_width, input_height, config.max_width, config.max_height, config)
    rotate_filter = get_rotate_filter(config.flip_rotate)

    if not already_target:
        log(f"File is not encoded with {config.codec_label} codec.", config)

    if config.skip and already_target and not resize_filter:
        print(f"Video is already {config.codec_label} and does not require resizing, skipping encoding.", file=sys.stderr)
        return

    # Audio args
    if config.no_audio:
        audio_args = ["-an"]
        log("Audio disabled via --noaudio flag", config)
    else:
        audio_args = get_audio_codec_args(json_info, config)

    print(f"Encoding: {input_file}", file=sys.stderr)
    print(f"Output:   {output_path}", file=sys.stderr)

    # Video codec args
    if config.no_video:
        video_codec_args = ["-vn"]
        vf_args: list[str] = []
        hdr: Optional[dict] = None
        log("Video disabled via --novideo flag", config)
    else:
        # HDR detection (HEVC only)
        if config.supports_hdr:
            hdr = detect_hdr(vt)
            pix_fmt = hdr["pix_fmt"]
            if hdr["is_hdr"]:
                hdr_type = "HLG" if hdr["is_hlg"] else ("HDR10" if hdr["is_hdr10"] else "HDR")
                log(f"HDR detected: {hdr_type} — preserving color metadata", config)
            else:
                log("No HDR metadata detected, encoding as SDR", config)
        else:
            hdr = None
            pix_fmt = "yuv420p"

        video_codec_args = ["-pix_fmt", pix_fmt, "-c:v", config.ffmpeg_codec,
                            "-crf", str(config.crf), "-preset", config.preset]
        if config.codec_tag:
            video_codec_args += ["-tag:v", config.codec_tag]
        if hdr and hdr["is_hdr"]:
            video_codec_args += get_hdr_video_args(hdr, config.ffmpeg_codec)

        filters = []
        if config.deinterlace:
            filters.append("yadif")
        if resize_filter:
            filters.append(resize_filter)
        if rotate_filter:
            filters.append(rotate_filter)
        vf_args = ["-vf", ",".join(filters)] if filters else []

    cmd = (
        [config.fftool, "-hwaccel", "auto", "-y", "-hide_banner", "-i", input_file]
        + video_codec_args
        + vf_args
        + audio_args
        + ["-movflags", "+faststart", str(output_path)]
    )

    if config.verbose:
        formatted = " \\\n  ".join(cmd)
        log(f"Executing:\n  {formatted}", config)

    try:
        subprocess.run(cmd, check=True)
    except subprocess.CalledProcessError:
        if output_path.exists():
            output_path.unlink()
        raise RuntimeError("Conversion failed.")

    log("Conversion completed, verifying output file.", config)

    # Verify output
    verify = subprocess.run(
        ["mediainfo", "--Output=JSON", str(output_path)],
        capture_output=True, text=True, check=True
    )
    out_json = json.loads(verify.stdout)
    out_video = next((t for t in out_json.get("media", {}).get("track", []) if t.get("@type") == "Video"), None)
    if out_video is None:
        raise RuntimeError("Output file has no video track.")

    output_duration = float(out_video.get("Duration") or 0)
    log(f"Original duration: {original_duration}, Output duration: {output_duration}", config)

    if abs(original_duration - output_duration) <= TOLERANCE:
        log("✅ Duration difference is within tolerance.", config)
        copy_attributes(input_file, str(output_path), config)
        after_encoding(input_path, config)
    else:
        raise RuntimeError(
            f"❌ Duration difference exceeds tolerance! "
            f"({original_duration:.3f}s vs {output_duration:.3f}s)"
        )


# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

class _CrfAction(argparse.Action):
    def __init__(self, option_strings, dest, crf_min, crf_max, **kwargs):
        self._crf_min = crf_min
        self._crf_max = crf_max
        super().__init__(option_strings, dest, type=int, **kwargs)

    def __call__(self, parser, namespace, values, option_string=None):
        if not (self._crf_min <= values <= self._crf_max):
            parser.error(f"CRF must be between {self._crf_min} and {self._crf_max}")
        setattr(namespace, self.dest, values)


def build_arg_parser(config: EncoderConfig) -> argparse.ArgumentParser:
    prog = f"to{config.codec_label.lower()}.py"
    parser = argparse.ArgumentParser(
        prog=prog,
        description=f"Smart {config.codec_label} encoder for macOS",
        formatter_class=argparse.RawTextHelpFormatter,
    )

    parser.add_argument("-v", "--verbose", action="store_true",
                        help=f"Enable verbose output\n* Default: Off")
    parser.add_argument("-s", "--size", metavar="WxH",
                        help="Set maximum video dimensions (e.g., 3840x2160)")
    parser.add_argument("-c", "--crf",
                        action=_CrfAction, crf_min=config.crf_min, crf_max=config.crf_max,
                        default=config.default_crf,
                        metavar=str(config.default_crf),
                        help=(f"Set {config.codec_label} CRF value\n"
                              f"{config.crf_min}-{config.crf_max}, default: {config.default_crf}"))
    parser.add_argument("-p", "--preset", choices=PRESETS, default=config.default_preset,
                        help=(f"Set {config.codec_label} encoding preset\n"
                              f"* Default: {config.default_preset}"))
    parser.add_argument("-a", "--after-encode", choices=["label", "rename", "delete"],
                        default="", metavar="ACTION",
                        help="Action after encoding: label, rename, delete")
    parser.add_argument("-t", "--tag-color",
                        choices=["orange", "red", "yellow", "blue", "purple", "green", "gray"],
                        default="green",
                        help="Finder color tag for --after-encode=label\n* Default: green")
    parser.add_argument("-r", "--flip-rotate",
                        choices=["right", "left", "upside-down", "horizontal", "vertical"],
                        default="", metavar="DIRECTION",
                        help="Apply rotation/flip filter")
    parser.add_argument("--skip", action="store_true",
                        help=f"Skip if already {config.codec_label} and dimensions are met")
    parser.add_argument("--deinterlace", action="store_true",
                        help="Apply yadif deinterlacing filter")
    parser.add_argument("--osufix", default=config.default_output_suffix, metavar="SUFFIX",
                        help=f"Output filename suffix (default: {config.default_output_suffix})")
    parser.add_argument("--isufix", default=".done", metavar="SUFFIX",
                        help="Input filename suffix after encoding (default: .done)")
    parser.add_argument("--dates", action="store_true",
                        help="Copy file modification dates to output")
    parser.add_argument("--tags", action="store_true",
                        help="Copy Finder tags to output")
    parser.add_argument("--comments", action="store_true",
                        help="Copy Finder comments to output")
    parser.add_argument("--permissions", action="store_true",
                        help="Copy file permissions to output")
    parser.add_argument("--novideo", action="store_true",
                        help="Exclude video stream from output (-vn)")
    parser.add_argument("--noaudio", action="store_true",
                        help="Exclude audio stream from output (-an)")
    parser.add_argument("files", nargs="+", metavar="FILE",
                        help="One or more input video files to process")

    return parser


def _validate_suffix(value: str, name: str, parser: argparse.ArgumentParser) -> str:
    if not re.search(r"[a-zA-Z]", value) or not re.fullmatch(r"[a-zA-Z0-9._]+", value):
        parser.error(f"{name} must contain at least one letter and only alphanumeric characters, dots, or underscores")
    return value


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main(config: EncoderConfig) -> None:
    parser = build_arg_parser(config)
    args = parser.parse_args()

    if args.files is None or len(args.files) == 0:
        parser.error("No input files specified")

    # Apply parsed args into config
    config.verbose = args.verbose
    config.crf = args.crf
    config.preset = args.preset
    config.after_encode = args.after_encode or ""
    config.tag_color = args.tag_color
    config.flip_rotate = args.flip_rotate or ""
    config.skip = args.skip
    config.deinterlace = args.deinterlace
    config.output_suffix = _validate_suffix(args.osufix, "--osufix", parser)
    config.original_suffix = _validate_suffix(args.isufix, "--isufix", parser)
    config.copy_dates = args.dates
    config.copy_tags = args.tags
    config.copy_comments = args.comments
    config.copy_permissions = args.permissions
    config.no_video = args.novideo
    config.no_audio = args.noaudio
    config.files = args.files

    if args.size:
        m = re.fullmatch(r"(\d+)x(\d+)", args.size)
        if not m or int(m.group(1)) <= 0 or int(m.group(2)) <= 0:
            parser.error("Size must be in the format NUMBERxNUMBER with positive integers (e.g., 3840x2160)")
        config.max_width = int(m.group(1))
        config.max_height = int(m.group(2))

    check_dependencies()

    ffmpeg_path = find_tool("ffmpeg")
    fpb_path = find_tool("fpb")
    config.ffmpeg_path = ffmpeg_path
    config.fftool = fpb_path if fpb_path else ffmpeg_path

    log(f"Using encoder: {config.fftool}", config)

    failed: list[str] = []
    for f in config.files:
        try:
            validate_video_file(f)
            encode(f, config)
        except Exception as exc:
            error(f"Failed to process '{f}': {exc}")
            failed.append(f)

    if failed:
        error(f"Failed to process {len(failed)} file(s): {', '.join(failed)}")
        sys.exit(1)

    print("Successfully processed all files!", file=sys.stderr)
