#!/usr/bin/env python3
"""GUI control center for BBB presentation processing.

Features:
- Phase status overview (clips, split plan, split outputs, review, compose)
- Run key phases from GUI (make clips, auto detect, split, review, compose)
- Edit presentation metadata (presenter/title/info/start/end) in presentations_cut.yaml
- Visual webcam plan editor with per-segment overlay and active priority order
- Save compatible webcams_plan.manual.txt
"""

from __future__ import annotations

import argparse
import datetime as _dt
import html
import traceback
import os
import queue
import re
import subprocess
import sys
import threading
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Optional, Tuple

import tkinter as tk
from tkinter import messagebox, ttk

from PIL import Image, ImageDraw, ImageFont, ImageTk


GRID_CHOICES = (
    "1x1",
    "1x2",
    "1x3",
    "2x1",
    "2x2",
    "2x3",
    "3x1",
    "3x2",
    "3x3",
)


DEFAULT_1X2_BBOX = "0:270:1920:540"


_OVERLAY_FONT = None


def overlay_font():
    global _OVERLAY_FONT
    if _OVERLAY_FONT is not None:
        return _OVERLAY_FONT
    try:
        if hasattr(ImageFont, "load_default_imagefont"):
            _OVERLAY_FONT = ImageFont.load_default_imagefont()
        else:
            _OVERLAY_FONT = ImageFont.load_default()
    except Exception:
        _OVERLAY_FONT = None
    return _OVERLAY_FONT


@dataclass
class Segment:
    start: str
    end: str
    grid: str
    active: List[int]
    bbox: Optional[str] = None
    confidence: Optional[float] = None


def append_log(path: Path, text: str) -> None:
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        stamp = _dt.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        with path.open("a", encoding="utf-8") as fh:
            fh.write(f"\n[{stamp}]\n{text}\n")
    except Exception:
        pass


def segment_key(seg: Segment) -> Tuple[str, str]:
    return (seg.start, seg.end)


def segment_signature(seg: Segment) -> Tuple[str, Tuple[int, ...], str]:
    return (seg.grid, tuple(seg.active), seg.bbox or "")


def bbox_aspect(bbox: Optional[str], fallback_w: int = 1920, fallback_h: int = 1080) -> float:
    if not bbox:
        return float(fallback_w) / float(fallback_h)
    parts = bbox.split(":")
    if len(parts) != 4:
        return float(fallback_w) / float(fallback_h)
    try:
        bw = max(1.0, float(parts[2]))
        bh = max(1.0, float(parts[3]))
    except Exception:
        return float(fallback_w) / float(fallback_h)
    return bw / bh


def parse_time_token(token: str) -> float:
    token = str(token).strip()
    if not token:
        return 0.0
    parts = token.split(":")
    try:
        if len(parts) == 1:
            return float(parts[0])
        if len(parts) == 2:
            return float(parts[0]) * 60.0 + float(parts[1])
        if len(parts) == 3:
            return float(parts[0]) * 3600.0 + float(parts[1]) * 60.0 + float(parts[2])
    except ValueError:
        return 0.0
    return 0.0


def parse_grid(grid: str) -> Tuple[int, int]:
    m = re.match(r"^(\d+)x(\d+)$", grid.strip())
    if not m:
        return (1, 1)
    return (int(m.group(1)), int(m.group(2)))


def grid_cells_count(grid: str) -> int:
    rows, cols = parse_grid(grid)
    return max(1, rows * cols)


def parse_active(text: str) -> List[int]:
    out: List[int] = []
    for part in re.split(r"[\s,;]+", text.strip()):
        if not part:
            continue
        if part.isdigit():
            out.append(int(part))
    return out


def normalize_active(active: List[int], grid: str) -> List[int]:
    total = grid_cells_count(grid)
    seen = set()
    out: List[int] = []
    for v in active:
        if 1 <= v <= total and v not in seen:
            out.append(v)
            seen.add(v)
    if not out:
        out = [1]
    return out


def parse_plan_txt(path: Path) -> List[Segment]:
    segments: List[Segment] = []
    if not path.is_file():
        return segments
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        parts = line.split()
        if len(parts) < 4:
            continue
        start, end, grid, active = parts[:4]
        bbox = parts[4] if len(parts) >= 5 else None
        seg = Segment(start=start, end=end, grid=grid, active=normalize_active(parse_active(active), grid), bbox=bbox)
        segments.append(seg)
    return segments


def load_confidence(meta_path: Path) -> Dict[Tuple[str, str], float]:
    if not meta_path.is_file():
        return {}
    try:
        import json

        data = json.loads(meta_path.read_text(encoding="utf-8"))
    except Exception:
        return {}
    out: Dict[Tuple[str, str], float] = {}
    for seg in data.get("segments", []):
        k = (str(seg.get("start", "")), str(seg.get("end", "")))
        try:
            out[k] = float(seg.get("confidence", 0.0))
        except Exception:
            out[k] = 0.0
    return out


def ensure_preview_frame(webcam_file: Path, review_dir: Path, seg: Segment, index: int) -> Path:
    review_dir = Path(review_dir)
    webcam_file = Path(webcam_file)
    review_dir.mkdir(parents=True, exist_ok=True)

    safe_start = re.sub(r"[^0-9A-Za-z._-]+", "-", str(seg.start)).strip("-._") or "start"
    frame_file = Path(os.path.join(str(review_dir), f"seg{index+1:02d}_{safe_start}.jpg"))
    if frame_file.is_file() and frame_file.stat().st_size > 0:
        return frame_file

    t = max(0.0, parse_time_token(seg.start) + 2.0)
    cmd = [
        "ffmpeg",
        "-nostdin",
        "-v",
        "error",
        "-ss",
        f"{t:.3f}",
        "-i",
        str(webcam_file),
        "-frames:v",
        "1",
        str(frame_file),
    ]
    subprocess.run(cmd, check=False)
    return frame_file


def draw_overlay(base: Image.Image, seg: Segment) -> Image.Image:
    img = base.convert("RGB")
    draw = ImageDraw.Draw(img)
    font = overlay_font()

    w, h = img.size
    bx, by, bw, bh = (0, 0, w, h)
    if seg.bbox:
        parts = seg.bbox.split(":")
        if len(parts) == 4:
            try:
                bx, by, bw, bh = [int(float(p)) for p in parts]
            except Exception:
                bx, by, bw, bh = (0, 0, w, h)
    bx = max(0, min(w - 2, bx))
    by = max(0, min(h - 2, by))
    bw = max(2, min(w - bx, bw))
    bh = max(2, min(h - by, bh))

    draw.rectangle((bx, by, bx + bw, by + bh), outline=(255, 200, 0), width=3)

    rows, cols = parse_grid(seg.grid)
    rows = max(1, rows)
    cols = max(1, cols)

    for c in range(1, cols):
        x = bx + int(round(c * bw / cols))
        draw.line((x, by, x, by + bh), fill=(0, 255, 255), width=2)
    for r in range(1, rows):
        y = by + int(round(r * bh / rows))
        draw.line((bx, y, bx + bw, y), fill=(0, 255, 255), width=2)

    total = rows * cols
    active_map = {v: i + 1 for i, v in enumerate(seg.active)}

    for idx in range(1, total + 1):
        rr = (idx - 1) // cols
        cc = (idx - 1) % cols
        x0 = bx + int(round(cc * bw / cols))
        y0 = by + int(round(rr * bh / rows))

        label = f"{idx}"
        if idx in active_map:
            label = f"{idx}#{active_map[idx]}"
            color = (50, 220, 50)
        else:
            color = (255, 80, 80)

        draw.rectangle((x0 + 4, y0 + 4, x0 + 92, y0 + 28), fill=(0, 0, 0))
        if font is not None:
            draw.text((x0 + 8, y0 + 7), label, fill=color, font=font)
        else:
            draw.text((x0 + 8, y0 + 7), label, fill=color)

    return img


def segment_cell_rects(seg: Segment, width: int, height: int) -> List[Tuple[int, int, int, int, int]]:
    bx, by, bw, bh = (0, 0, width, height)
    if seg.bbox:
        parts = seg.bbox.split(":")
        if len(parts) == 4:
            try:
                bx, by, bw, bh = [int(float(p)) for p in parts]
            except Exception:
                bx, by, bw, bh = (0, 0, width, height)

    bx = max(0, min(width - 2, bx))
    by = max(0, min(height - 2, by))
    bw = max(2, min(width - bx, bw))
    bh = max(2, min(height - by, bh))

    rows, cols = parse_grid(seg.grid)
    rows = max(1, rows)
    cols = max(1, cols)

    out: List[Tuple[int, int, int, int, int]] = []
    idx = 1
    for rr in range(rows):
        y0 = by + int(round(rr * bh / rows))
        y1 = by + int(round((rr + 1) * bh / rows))
        for cc in range(cols):
            x0 = bx + int(round(cc * bw / cols))
            x1 = bx + int(round((cc + 1) * bw / cols))
            out.append((idx, x0, y0, x1, y1))
            idx += 1
    return out


def detect_vertical_content_bounds(
    image: Image.Image,
    dark_threshold: int = 18,
    min_active_ratio: float = 0.03,
) -> Tuple[int, int]:
    """Return (top, bottom_exclusive) content bounds to trim black top/bottom bars."""
    gray = image.convert("L")
    w, h = gray.size
    if w <= 0 or h <= 0:
        return (0, 0)

    pix = gray.load()
    step = 2 if w >= 640 else 1
    samples = max(1, w // step)
    min_active = max(1, int(samples * min_active_ratio))

    active_rows: List[bool] = [False] * h
    for y in range(h):
        bright = 0
        row_sum = 0
        for x in range(0, w, step):
            v = int(pix[x, y])
            row_sum += v
            if v > dark_threshold:
                bright += 1
        mean_v = row_sum / float(samples)
        active_rows[y] = bright >= min_active or mean_v > 14.0

    top = 0
    while top < h and not active_rows[top]:
        top += 1

    bottom = h - 1
    while bottom >= 0 and not active_rows[bottom]:
        bottom -= 1

    if bottom <= top:
        return (0, h)

    # Small safety padding keeps edges from looking too tight.
    pad = 3
    top = max(0, top - pad)
    bottom = min(h - 1, bottom + pad)
    return (top, bottom + 1)


def dequote(value: str) -> str:
    value = value.strip()
    if len(value) >= 2 and ((value[0] == '"' and value[-1] == '"') or (value[0] == "'" and value[-1] == "'")):
        return value[1:-1]
    return value


def read_presentation_fields(yaml_path: Path, target_num: str) -> Dict[str, str]:
    lines = yaml_path.read_text(encoding="utf-8").splitlines()

    blocks: List[Tuple[int, int]] = []
    start = None
    for i, line in enumerate(lines):
        m = re.match(r"^(\s*)-\s*num\s*:\s*(.+?)\s*$", line)
        if m:
            if start is not None:
                blocks.append((start, i))
            start = i
    if start is not None:
        blocks.append((start, len(lines)))

    block = None
    for a, b in blocks:
        m = re.match(r"^\s*-\s*num\s*:\s*(.+?)\s*$", lines[a])
        if m and dequote(m.group(1)) == target_num:
            block = (a, b)
            break
    if block is None:
        return {}

    a, b = block
    out: Dict[str, str] = {}
    for i in range(a, b):
        m = re.match(r"^\s*(start|end|presenter|short_title|info)\s*:\s*(.*?)\s*$", lines[i])
        if m:
            out[m.group(1)] = dequote(m.group(2))
    return out


def write_presentation_fields(yaml_path: Path, target_num: str, updates: Dict[str, str]) -> None:
    lines = yaml_path.read_text(encoding="utf-8").splitlines()

    blocks: List[Tuple[int, int]] = []
    start = None
    for i, line in enumerate(lines):
        m = re.match(r"^(\s*)-\s*num\s*:\s*(.+?)\s*$", line)
        if m:
            if start is not None:
                blocks.append((start, i))
            start = i
    if start is not None:
        blocks.append((start, len(lines)))

    block = None
    for a, b in blocks:
        m = re.match(r"^\s*-\s*num\s*:\s*(.+?)\s*$", lines[a])
        if m and dequote(m.group(1)) == target_num:
            block = (a, b)
            break

    if block is None:
        raise RuntimeError(f"Presentation {target_num} not found in {yaml_path}")

    a, b = block
    item_indent = len(re.match(r"^(\s*)-\s*num\s*:", lines[a]).group(1))
    prop_indent = " " * (item_indent + 2)

    new_block: List[str] = []
    existing = {k: False for k in updates.keys()}

    for i in range(a, b):
        line = lines[i]
        if i == a:
            new_block.append(line)
            continue

        m = re.match(r"^\s*(start|end|presenter|short_title|info)\s*:\s*(.*?)\s*$", line)
        if m and m.group(1) in updates:
            key = m.group(1)
            val = updates[key]
            new_block.append(f'{prop_indent}{key}: "{val}"')
            existing[key] = True
        else:
            new_block.append(line)

    insert_pos = 1
    ordered = ["start", "end", "presenter", "short_title", "info"]
    for key in ordered:
        if key in updates and not existing.get(key, False):
            new_block.insert(insert_pos, f'{prop_indent}{key}: "{updates[key]}"')
            insert_pos += 1

    updated = lines[:a] + new_block + lines[b:]
    yaml_path.write_text("\n".join(updated) + "\n", encoding="utf-8")


class PlanEditorApp:
    def __init__(self, root: tk.Tk, rec_dir: Path, num: str, crash_log_path: Path):
        self.root = root
        self.rec_dir = rec_dir
        self.num = num
        self.crash_log_path = crash_log_path

        self.repo_root = Path.cwd()
        self.out_dir = rec_dir / "output" / num
        self.webcam_file = self.out_dir / "webcam.mp4"
        self.auto_plan = self.out_dir / "webcams_plan.auto.txt"
        self.meta_path = self.out_dir / "webcams_plan.auto.meta.json"
        self.manual_plan = self.out_dir / "webcams_plan.manual.txt"
        self.review_dir = self.out_dir / "webcams" / "review_plan"
        self.yaml_path = rec_dir / "presentations_cut.yaml"

        self.segments: List[Segment] = []
        self.auto_segments_map: Dict[Tuple[str, str], Segment] = {}
        self.changed_keys: set[Tuple[str, str]] = set()
        self.visible_indices: List[int] = []
        self.current_index = 0
        self.tk_img = None
        self.current_display_size: Tuple[int, int] = (0, 0)
        self.current_image_size: Tuple[int, int] = (0, 0)
        self.current_preview_offset: Tuple[int, int] = (0, 0)
        self.current_edit_display_rect: Tuple[int, int, int, int] = (0, 0, 0, 0)
        self.current_edit_source_size: Tuple[int, int] = (0, 0)
        self.current_render_image: Optional[Image.Image] = None
        self.current_edit_rect_src: Tuple[int, int, int, int] = (0, 0, 0, 0)
        self.resize_after_id: Optional[str] = None

        self.log_queue: "queue.Queue[str]" = queue.Queue()
        self.run_thread: Optional[threading.Thread] = None

        self.root.title(f"BBB Control Center - {rec_dir.name} / {num}")
        self.root.geometry("1480x920")
        self.root.report_callback_exception = self._tk_callback_exception

        self._build_ui()
        self._load_yaml_fields()
        self.load_plan(prefer_manual=True)
        self.refresh_status()
        self._tick_log_queue()

    def _tk_callback_exception(self, exc, val, tb) -> None:
        details = "".join(traceback.format_exception(exc, val, tb))
        append_log(self.crash_log_path, "[GUI callback error]\n" + details)
        self._log("\n[GUI callback error]\n" + details + "\n")
        messagebox.showerror("GUI callback error", details)

    def _build_ui(self) -> None:
        top = ttk.Frame(self.root, padding=8)
        top.pack(fill=tk.X)

        ttk.Label(top, text=f"Recording: {self.rec_dir}").pack(anchor=tk.W)
        ttk.Label(top, text=f"Presentation: {self.num}").pack(anchor=tk.W)

        tabs = ttk.Notebook(self.root)
        tabs.pack(fill=tk.BOTH, expand=True)

        self.tab_status = ttk.Frame(tabs, padding=8)
        self.tab_plan = ttk.Frame(tabs, padding=8)
        self.tab_log = ttk.Frame(tabs, padding=8)

        tabs.add(self.tab_status, text="Pipeline")
        tabs.add(self.tab_plan, text="Webcams Plan Editor")
        tabs.add(self.tab_log, text="Logs")

        self._build_status_tab()
        self._build_plan_tab()
        self._build_log_tab()

    def _build_status_tab(self) -> None:
        meta_box = ttk.LabelFrame(self.tab_status, text="Presentation Metadata", padding=8)
        meta_box.pack(fill=tk.X)

        self.start_var = tk.StringVar()
        self.end_var = tk.StringVar()
        self.presenter_var = tk.StringVar()
        self.title_var = tk.StringVar()
        self.info_var_meta = tk.StringVar()

        ttk.Label(meta_box, text="Start").grid(row=0, column=0, sticky="w")
        ttk.Entry(meta_box, textvariable=self.start_var, width=12).grid(row=0, column=1, sticky="w", padx=(4, 12))
        ttk.Label(meta_box, text="End").grid(row=0, column=2, sticky="w")
        ttk.Entry(meta_box, textvariable=self.end_var, width=12).grid(row=0, column=3, sticky="w", padx=(4, 12))

        ttk.Label(meta_box, text="Presenter").grid(row=1, column=0, sticky="w", pady=(6, 0))
        ttk.Entry(meta_box, textvariable=self.presenter_var, width=30).grid(row=1, column=1, columnspan=3, sticky="we", padx=(4, 12), pady=(6, 0))

        ttk.Label(meta_box, text="Short Title").grid(row=2, column=0, sticky="w", pady=(6, 0))
        ttk.Entry(meta_box, textvariable=self.title_var, width=40).grid(row=2, column=1, columnspan=3, sticky="we", padx=(4, 12), pady=(6, 0))

        ttk.Label(meta_box, text="Info").grid(row=3, column=0, sticky="w", pady=(6, 0))
        ttk.Entry(meta_box, textvariable=self.info_var_meta, width=60).grid(row=3, column=1, columnspan=3, sticky="we", padx=(4, 12), pady=(6, 0))

        ttk.Button(meta_box, text="Save metadata to YAML", command=self.save_yaml_fields).grid(row=4, column=0, columnspan=2, sticky="w", pady=(10, 0))

        status_box = ttk.LabelFrame(self.tab_status, text="What Remains", padding=8)
        status_box.pack(fill=tk.X, pady=(10, 0))

        self.status_vars = {
            "clips": tk.StringVar(),
            "auto_plan": tk.StringVar(),
            "manual_plan": tk.StringVar(),
            "split_outputs": tk.StringVar(),
            "review_assets": tk.StringVar(),
            "final_video": tk.StringVar(),
        }

        row = 0
        for key, label in [
            ("clips", "Phase 2 clips (webcam/slides/deskshare)"),
            ("auto_plan", "Auto plan from OpenCV"),
            ("manual_plan", "Manual plan reviewed"),
            ("split_outputs", "Split webcam clips"),
            ("review_assets", "Review assets (contact-sheet/video)"),
            ("final_video", "Final composed video"),
        ]:
            ttk.Label(status_box, text=label).grid(row=row, column=0, sticky="w")
            ttk.Label(status_box, textvariable=self.status_vars[key]).grid(row=row, column=1, sticky="w", padx=(10, 0))
            row += 1

        ttk.Button(status_box, text="Refresh status", command=self.refresh_status).grid(row=row, column=0, sticky="w", pady=(8, 0))

        run_box = ttk.LabelFrame(self.tab_status, text="Run Phases", padding=8)
        run_box.pack(fill=tk.X, pady=(10, 0))

        ttk.Button(run_box, text="1) Make clips (phase 2)", command=self.run_phase_make_clips).grid(row=0, column=0, sticky="w")
        ttk.Button(run_box, text="2) Auto detect plan (v3)", command=self.run_phase_auto_plan).grid(row=0, column=1, sticky="w", padx=(10, 0))
        ttk.Button(run_box, text="3) Generate split review assets", command=self.run_phase_review_assets).grid(row=0, column=2, sticky="w", padx=(10, 0))

        ttk.Button(run_box, text="4) Split webcams from manual plan", command=self.run_phase_split_manual).grid(row=1, column=0, sticky="w", pady=(8, 0))
        ttk.Button(run_box, text="5) Compose final video", command=self.run_phase_compose).grid(row=1, column=1, sticky="w", padx=(10, 0), pady=(8, 0))
        ttk.Button(run_box, text="Run 2->3->4->5", command=self.run_pipeline_after_clips).grid(row=1, column=2, sticky="w", padx=(10, 0), pady=(8, 0))

        opts = ttk.Frame(run_box)
        opts.grid(row=2, column=0, columnspan=3, sticky="w", pady=(10, 0))

        self.step_var = tk.StringVar(value="2")
        self.review_mode_var = tk.StringVar(value="smart")
        self.review_conf_var = tk.StringVar(value="0.62")

        ttk.Label(opts, text="STEP").pack(side=tk.LEFT)
        ttk.Entry(opts, textvariable=self.step_var, width=5).pack(side=tk.LEFT, padx=(4, 12))
        ttk.Label(opts, text="REVIEW_MODE").pack(side=tk.LEFT)
        ttk.Combobox(opts, textvariable=self.review_mode_var, values=("all", "changed", "low", "smart"), width=9, state="readonly").pack(side=tk.LEFT, padx=(4, 12))
        ttk.Label(opts, text="REVIEW_CONF").pack(side=tk.LEFT)
        ttk.Entry(opts, textvariable=self.review_conf_var, width=6).pack(side=tk.LEFT, padx=(4, 0))

    def _build_plan_tab(self) -> None:
        top = ttk.Frame(self.tab_plan)
        top.pack(fill=tk.X)

        ttk.Button(top, text="Load AUTO plan", command=lambda: self.load_plan(prefer_manual=False)).pack(side=tk.LEFT)
        ttk.Button(top, text="Load MANUAL plan", command=lambda: self.load_plan(prefer_manual=True, force_manual=True)).pack(side=tk.LEFT, padx=(6, 0))
        ttk.Button(top, text="Save manual plan", command=self.save_manual_plan).pack(side=tk.LEFT, padx=(12, 0))
        ttk.Button(top, text="Split only changed", command=self.run_phase_split_changed).pack(side=tk.LEFT, padx=(6, 0))
        ttk.Button(top, text="Auto-fix low confidence", command=self.apply_assistant_suggestions).pack(side=tk.LEFT, padx=(6, 0))
        ttk.Button(top, text="Export HTML report", command=self.export_html_report).pack(side=tk.LEFT, padx=(6, 0))
        ttk.Button(top, text="Refresh image", command=self.refresh_current_preview).pack(side=tk.LEFT, padx=(6, 0))

        self.filter_mode_var = tk.StringVar(value="all")
        ttk.Label(top, text="Filter").pack(side=tk.LEFT, padx=(10, 0))
        ttk.Combobox(
            top,
            textvariable=self.filter_mode_var,
            values=("all", "changed", "low", "changed+low"),
            width=12,
            state="readonly",
        ).pack(side=tk.LEFT, padx=(4, 6))
        ttk.Button(top, text="Apply filter", command=self.apply_segment_filter).pack(side=tk.LEFT)

        self.filter_count_var = tk.StringVar(value="Segments: 0/0")
        ttk.Label(top, textvariable=self.filter_count_var).pack(side=tk.LEFT, padx=(8, 0))

        self.side_by_side_var = tk.BooleanVar(value=False)
        ttk.Checkbutton(top, text="Side-by-side AUTO/Current", variable=self.side_by_side_var, command=self.refresh_current_preview).pack(side=tk.LEFT, padx=(8, 0))

        ttk.Label(top, text="Grids: 1x1, 1x2, 1x3, 2x1, 2x2, 2x3, 3x1, 3x2, 3x3 (custom allowed)").pack(side=tk.LEFT, padx=(18, 0))

        body = ttk.PanedWindow(self.tab_plan, orient=tk.HORIZONTAL)
        body.pack(fill=tk.BOTH, expand=True, pady=(8, 0))

        left = ttk.Frame(body)
        right = ttk.Frame(body)
        body.add(left, weight=1)
        body.add(right, weight=3)

        list_wrap = ttk.Frame(left)
        list_wrap.pack(fill=tk.BOTH, expand=True)

        self.seg_list = tk.Listbox(list_wrap, width=52, height=36)
        self.seg_list.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)
        seg_scroll = ttk.Scrollbar(list_wrap, orient=tk.VERTICAL, command=self.seg_list.yview)
        seg_scroll.pack(side=tk.LEFT, fill=tk.Y)
        self.seg_list.configure(yscrollcommand=seg_scroll.set)
        self.seg_list.bind("<<ListboxSelect>>", self._on_list_select)

        self.preview_canvas = tk.Canvas(right, bg="#111111", width=1020, height=620, highlightthickness=1, highlightbackground="#333333")
        self.preview_canvas.pack(fill=tk.BOTH, expand=True)
        self.preview_canvas.bind("<Button-1>", self._on_preview_click)
        self.preview_canvas.bind("<Shift-Button-1>", self._on_preview_shift_click)
        self.preview_canvas.bind("<Configure>", self._on_preview_canvas_configure)

        self.timeline_canvas = tk.Canvas(right, bg="#202020", width=1020, height=54, highlightthickness=1, highlightbackground="#3a3a3a")
        self.timeline_canvas.pack(fill=tk.X, pady=(6, 0))
        self.timeline_canvas.bind("<Button-1>", self._on_timeline_click)
        self.timeline_canvas.bind("<Configure>", self._on_timeline_canvas_configure)

        form = ttk.Frame(right)
        form.pack(fill=tk.X, pady=(8, 0))

        self.seg_info_var = tk.StringVar(value="")
        ttk.Label(form, textvariable=self.seg_info_var).grid(row=0, column=0, columnspan=8, sticky="w")

        ttk.Label(form, text="Grid").grid(row=1, column=0, sticky="w")
        self.grid_var = tk.StringVar()
        self.grid_combo = ttk.Combobox(form, textvariable=self.grid_var, values=GRID_CHOICES, width=8)
        self.grid_combo.grid(row=1, column=1, sticky="w", padx=(4, 10))
        self.grid_combo.bind("<<ComboboxSelected>>", self._on_grid_changed)

        ttk.Label(form, text="BBox x:y:w:h").grid(row=1, column=2, sticky="w")
        self.bbox_var = tk.StringVar()
        ttk.Entry(form, textvariable=self.bbox_var, width=26).grid(row=1, column=3, sticky="w", padx=(4, 10))
        ttk.Button(form, text="Clear bbox", command=lambda: self.bbox_var.set("")).grid(row=1, column=4, sticky="w")
        ttk.Button(form, text="Auto crop top/bottom (1x2)", command=self.auto_crop_top_bottom_for_1x2).grid(row=1, column=5, sticky="w", padx=(8, 0))
        self.auto_tb_on_grid_var = tk.BooleanVar(value=False)
        ttk.Checkbutton(form, text="Auto when grid=1x2", variable=self.auto_tb_on_grid_var).grid(row=2, column=3, columnspan=3, sticky="w", pady=(4, 0))

        ttk.Label(form, text="Active order (priority)").grid(row=2, column=0, sticky="w", pady=(8, 0))
        self.active_list = tk.Listbox(form, width=18, height=6, selectmode=tk.EXTENDED)
        self.active_list.grid(row=3, column=0, rowspan=5, columnspan=2, sticky="nw")

        btns = ttk.Frame(form)
        btns.grid(row=3, column=2, sticky="nw")
        ttk.Button(btns, text="Up", command=self._active_up).pack(fill=tk.X)
        ttk.Button(btns, text="Down", command=self._active_down).pack(fill=tk.X, pady=2)
        ttk.Button(btns, text="Remove", command=self._active_remove).pack(fill=tk.X)
        ttk.Button(btns, text="Keep selected", command=self._keep_only_selected_active).pack(fill=tk.X, pady=(2, 0))

        addf = ttk.Frame(form)
        addf.grid(row=4, column=2, sticky="nw", pady=(6, 0))
        self.add_var = tk.StringVar()
        ttk.Entry(addf, textvariable=self.add_var, width=6).pack(side=tk.LEFT)
        ttk.Button(addf, text="Add", command=self._active_add).pack(side=tk.LEFT, padx=(4, 0))

        ttk.Button(form, text="Reset 1..N", command=self._active_reset).grid(row=5, column=2, sticky="w", pady=(6, 0))
        ttk.Button(form, text="Apply segment edits", command=self.commit_current_segment).grid(row=6, column=2, sticky="w", pady=(6, 0))

        nav = ttk.Frame(self.tab_plan)
        nav.pack(fill=tk.X, pady=(8, 0))
        ttk.Button(nav, text="Prev", command=self.prev_segment).pack(side=tk.LEFT)
        ttk.Button(nav, text="Next", command=self.next_segment).pack(side=tk.LEFT, padx=(6, 0))

    def _build_log_tab(self) -> None:
        self.log_text = tk.Text(self.tab_log, wrap="word", height=35)
        self.log_text.pack(fill=tk.BOTH, expand=True)
        self.log_text.configure(state=tk.DISABLED)

        controls = ttk.Frame(self.tab_log)
        controls.pack(fill=tk.X, pady=(6, 0))
        ttk.Button(controls, text="Clear log", command=self.clear_log).pack(side=tk.LEFT)

    def _log(self, msg: str) -> None:
        self.log_queue.put(msg)

    def _tick_log_queue(self) -> None:
        try:
            while True:
                line = self.log_queue.get_nowait()
                self.log_text.configure(state=tk.NORMAL)
                self.log_text.insert(tk.END, line)
                self.log_text.see(tk.END)
                self.log_text.configure(state=tk.DISABLED)
        except queue.Empty:
            pass
        self.root.after(120, self._tick_log_queue)

    def clear_log(self) -> None:
        self.log_text.configure(state=tk.NORMAL)
        self.log_text.delete("1.0", tk.END)
        self.log_text.configure(state=tk.DISABLED)

    def _run_cmd_async(self, cmd: List[str], env: Optional[Dict[str, str]] = None, done=None) -> None:
        if self.run_thread and self.run_thread.is_alive():
            messagebox.showwarning("Busy", "A command is already running. Please wait.")
            return

        self._log("\n$ " + " ".join(cmd) + "\n")

        def worker() -> None:
            proc = subprocess.Popen(
                cmd,
                cwd=str(self.repo_root),
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                env=env,
            )
            assert proc.stdout is not None
            for line in proc.stdout:
                self._log(line)
            code = proc.wait()
            self._log(f"\n[exit {code}]\n")
            if done:
                self.root.after(0, lambda: done(code))

        self.run_thread = threading.Thread(target=worker, daemon=True)
        self.run_thread.start()

    def _phase_env(self) -> Dict[str, str]:
        env = os.environ.copy()
        env["BBB_VENC"] = "libx264"
        env["STEP"] = self.step_var.get().strip() or "2"
        env["REVIEW_MODE"] = self.review_mode_var.get().strip() or "smart"
        env["REVIEW_CONFIDENCE"] = self.review_conf_var.get().strip() or "0.62"
        return env

    def run_phase_make_clips(self) -> None:
        env = self._phase_env()
        cmd = ["./bbb_make_clips.sh", str(self.rec_dir), "encode", self.num]
        self._run_cmd_async(cmd, env=env, done=lambda _c: self.refresh_status())

    def run_phase_auto_plan(self) -> None:
        env = self._phase_env()
        env["REVIEW"] = "0"
        env["APPLY"] = "0"
        env["SPLIT"] = "0"
        cmd = ["./bbb_split_webcams_v3.sh", str(self.rec_dir), self.num]
        self._run_cmd_async(cmd, env=env, done=lambda _c: self._after_auto_plan())

    def _after_auto_plan(self) -> None:
        self.load_plan(prefer_manual=False)
        self.refresh_status()

    def _refresh_changed_flags(self) -> None:
        changed: set[Tuple[str, str]] = set()
        for seg in self.segments:
            key = segment_key(seg)
            base = self.auto_segments_map.get(key)
            if base is None or segment_signature(base) != segment_signature(seg):
                changed.add(key)
        self.changed_keys = changed

    def apply_segment_filter(self, reload_segment: bool = True) -> None:
        if not self.segments:
            self.visible_indices = []
            self.seg_list.delete(0, tk.END)
            self.filter_count_var.set("Segments: 0/0")
            return

        mode = self.filter_mode_var.get().strip() or "all"
        try:
            threshold = float(self.review_conf_var.get().strip() or "0.62")
        except Exception:
            threshold = 0.62

        indices: List[int] = []
        for i, seg in enumerate(self.segments):
            is_changed = segment_key(seg) in self.changed_keys
            conf = seg.confidence if seg.confidence is not None else 1.0
            is_low = conf < threshold

            keep = True
            if mode == "changed":
                keep = is_changed
            elif mode == "low":
                keep = is_low
            elif mode == "changed+low":
                keep = is_changed and is_low
            if keep:
                indices.append(i)

        self.visible_indices = indices
        self.filter_count_var.set(f"Segments: {len(self.visible_indices)}/{len(self.segments)}")
        self._populate_segment_list()

        if not self.visible_indices:
            self.seg_info_var.set("No segment matches current filter")
            self.preview_canvas.delete("all")
            return

        if self.current_index not in self.visible_indices:
            self.current_index = self.visible_indices[0]
        if reload_segment:
            self._load_segment(self.current_index)

    def run_phase_split_manual(self) -> None:
        self.save_manual_plan(silent=True)
        env = self._phase_env()
        env["MANUAL_PLAN"] = str(self.manual_plan)
        cmd = ["./bbb_split_webcams.sh", str(self.rec_dir), self.num]
        self._run_cmd_async(cmd, env=env, done=lambda _c: self.refresh_status())

    def run_phase_split_changed(self) -> None:
        self.save_manual_plan(silent=True)
        self._refresh_changed_flags()
        if not self.changed_keys:
            messagebox.showinfo("No changes", "No segment differs from AUTO baseline.")
            return

        changed_plan = self.out_dir / "webcams_plan.changed.txt"
        lines = ["# changed segments only", "# start end grid active [bbox]"]
        for seg in self.segments:
            if segment_key(seg) not in self.changed_keys:
                continue
            active = ",".join(str(v) for v in seg.active)
            row = f"{seg.start} {seg.end} {seg.grid} {active}"
            if seg.bbox:
                row += f" {seg.bbox}"
            lines.append(row)
        changed_plan.write_text("\n".join(lines) + "\n", encoding="utf-8")

        env = self._phase_env()
        env["MANUAL_PLAN"] = str(changed_plan)
        env["PARTIAL_SPLIT"] = "1"
        cmd = ["./bbb_split_webcams.sh", str(self.rec_dir), self.num]
        self._run_cmd_async(cmd, env=env, done=lambda _c: self.refresh_status())

    def apply_assistant_suggestions(self) -> None:
        try:
            threshold = float(self.review_conf_var.get().strip() or "0.62")
        except Exception:
            threshold = 0.62

        changed = 0
        for seg in self.segments:
            conf = seg.confidence if seg.confidence is not None else 1.0
            if conf >= threshold:
                continue
            aspect = bbox_aspect(seg.bbox)
            if seg.grid == "2x3" and aspect >= 2.2:
                seg.grid = "1x2"
                seg.active = [1, 2]
                changed += 1
                continue
            if seg.grid == "2x3":
                seg.grid = "2x2"
                seg.active = [v for v in seg.active if v <= 4] or [1, 2, 3]
                changed += 1
                continue
            if seg.grid == "2x2" and aspect >= 2.35 and len(seg.active) >= 2:
                seg.grid = "1x2"
                seg.active = [1, 2]
                changed += 1

            seg.active = normalize_active(seg.active, seg.grid)

        self._refresh_changed_flags()
        self._populate_segment_list()
        self._draw_timeline()
        if self.segments:
            self._load_segment(self.current_index)
        messagebox.showinfo("Assistant", f"Applied suggestions to {changed} low-confidence segment(s).")

    def export_html_report(self) -> None:
        if not self.segments:
            messagebox.showwarning("No segments", "Nothing to export")
            return

        report_dir = self.out_dir / "webcams" / "review_plan"
        report_dir.mkdir(parents=True, exist_ok=True)
        report_file = report_dir / "report.html"

        rows: List[str] = []
        for i, seg in enumerate(self.segments):
            key = segment_key(seg)
            base = self.auto_segments_map.get(key)
            changed = base is None or segment_signature(base) != segment_signature(seg)
            frame = ensure_preview_frame(self.webcam_file, report_dir, seg, i)
            conf = "n/a" if seg.confidence is None else f"{seg.confidence:.3f}"
            base_grid = base.grid if base else "-"
            base_active = ",".join(map(str, base.active)) if base else "-"
            base_bbox = base.bbox or "-" if base else "-"
            cur_active = ",".join(map(str, seg.active))
            cur_bbox = seg.bbox or "-"
            rows.append(
                "<tr>"
                f"<td>{i+1}</td>"
                f"<td>{html.escape(seg.start)} - {html.escape(seg.end)}</td>"
                f"<td>{conf}</td>"
                f"<td>{'YES' if changed else 'NO'}</td>"
                f"<td>{html.escape(base_grid)} / {html.escape(base_active)} / {html.escape(base_bbox)}</td>"
                f"<td>{html.escape(seg.grid)} / {html.escape(cur_active)} / {html.escape(cur_bbox)}</td>"
                f"<td><img src='{html.escape(frame.name)}' width='320'></td>"
                "</tr>"
            )

        html_doc = (
            "<html><head><meta charset='utf-8'><title>Webcams Plan Report</title>"
            "<style>body{font-family:Arial,Helvetica,sans-serif} table{border-collapse:collapse;width:100%}"
            "th,td{border:1px solid #ccc;padding:6px;vertical-align:top} th{background:#f2f2f2}</style>"
            "</head><body>"
            f"<h1>Webcams Plan Report - {html.escape(self.rec_dir.name)} / {html.escape(self.num)}</h1>"
            "<table><thead><tr><th>#</th><th>Segment</th><th>Confidence</th><th>Changed</th><th>Auto</th><th>Current</th><th>Preview</th></tr></thead><tbody>"
            + "\n".join(rows)
            + "</tbody></table></body></html>"
        )
        report_file.write_text(html_doc, encoding="utf-8")
        messagebox.showinfo("Report exported", f"HTML report:\n{report_file}")

    def run_phase_review_assets(self) -> None:
        env = self._phase_env()
        cmd = ["./bbb_review_webcams.sh", str(self.rec_dir), self.num]
        self._run_cmd_async(cmd, env=env, done=lambda _c: self.refresh_status())

    def run_phase_compose(self) -> None:
        env = self._phase_env()
        cmd = ["./bbb_compose.sh", str(self.rec_dir), self.num]
        self._run_cmd_async(cmd, env=env, done=lambda _c: self.refresh_status())

    def run_pipeline_after_clips(self) -> None:
        self.save_manual_plan(silent=True)
        env = self._phase_env()

        steps = [
            (["./bbb_split_webcams.sh", str(self.rec_dir), self.num], {**env, "MANUAL_PLAN": str(self.manual_plan)}),
            (["./bbb_review_webcams.sh", str(self.rec_dir), self.num], env.copy()),
            (["./bbb_compose.sh", str(self.rec_dir), self.num], env.copy()),
        ]

        def run_next(i: int, code_prev: int = 0) -> None:
            if code_prev != 0:
                self.refresh_status()
                return
            if i >= len(steps):
                self.refresh_status()
                return
            cmd, env_i = steps[i]
            self._run_cmd_async(cmd, env=env_i, done=lambda code: run_next(i + 1, code))

        run_next(0)

    def _load_yaml_fields(self) -> None:
        if not self.yaml_path.is_file():
            return
        fields = read_presentation_fields(self.yaml_path, self.num)
        self.start_var.set(fields.get("start", ""))
        self.end_var.set(fields.get("end", ""))
        self.presenter_var.set(fields.get("presenter", ""))
        self.title_var.set(fields.get("short_title", ""))
        self.info_var_meta.set(fields.get("info", ""))

    def save_yaml_fields(self) -> None:
        if not self.yaml_path.is_file():
            messagebox.showerror("YAML missing", f"Cannot find {self.yaml_path}")
            return
        updates = {
            "start": self.start_var.get().strip(),
            "end": self.end_var.get().strip(),
            "presenter": self.presenter_var.get().strip(),
            "short_title": self.title_var.get().strip(),
            "info": self.info_var_meta.get().strip(),
        }
        try:
            write_presentation_fields(self.yaml_path, self.num, updates)
        except Exception as exc:
            messagebox.showerror("Save failed", str(exc))
            return
        messagebox.showinfo("Saved", f"Updated metadata in {self.yaml_path}")

    def refresh_status(self) -> None:
        clips_ok = all((self.out_dir / n).is_file() for n in ("webcam.mp4", "slides.mp4", "deskshare.mp4"))
        auto_ok = self.auto_plan.is_file() and self.auto_plan.stat().st_size > 0
        manual_ok = self.manual_plan.is_file() and self.manual_plan.stat().st_size > 0

        split_dir = self.out_dir / "webcams"
        split_count = len(list(split_dir.glob("seg*s_cam*-of-*.mp4"))) if split_dir.is_dir() else 0
        split_ok = split_count > 0

        review_dir = split_dir / "review"
        review_ok = (review_dir / "contact-sheet.jpg").is_file() and (review_dir / "webcams-review.mp4").is_file()

        finals = [
            p
            for p in self.out_dir.glob("*.mp4")
            if p.name not in {"webcam.mp4", "slides.mp4", "deskshare.mp4"}
        ]
        final_ok = len(finals) > 0

        self.status_vars["clips"].set("OK" if clips_ok else "TODO")
        self.status_vars["auto_plan"].set("OK" if auto_ok else "TODO")
        self.status_vars["manual_plan"].set("OK" if manual_ok else "TODO")
        self.status_vars["split_outputs"].set(f"OK ({split_count} clips)" if split_ok else "TODO")
        self.status_vars["review_assets"].set("OK" if review_ok else "TODO")
        self.status_vars["final_video"].set(f"OK ({len(finals)} file(s))" if final_ok else "TODO")

    def load_plan(self, prefer_manual: bool = True, force_manual: bool = False) -> None:
        auto_segments = parse_plan_txt(self.auto_plan)
        self.auto_segments_map = {segment_key(seg): seg for seg in auto_segments}

        src = self.auto_plan
        if force_manual:
            src = self.manual_plan
        elif prefer_manual and self.manual_plan.is_file() and self.manual_plan.stat().st_size > 0:
            src = self.manual_plan

        if not src.is_file():
            src = self.auto_plan
        if not src.is_file():
            messagebox.showerror("Plan missing", f"No plan file found in {self.out_dir}")
            return

        self.segments = parse_plan_txt(src)
        conf_map = load_confidence(self.meta_path)
        for seg in self.segments:
            seg.confidence = conf_map.get((seg.start, seg.end))

        self._refresh_changed_flags()

        self.current_index = 0
        self.apply_segment_filter(reload_segment=False)
        self._draw_timeline()
        if self.visible_indices:
            self.current_index = self.visible_indices[0]
            self._load_segment(self.current_index)

    def _populate_segment_list(self) -> None:
        self.seg_list.delete(0, tk.END)
        if self.filter_mode_var.get().strip() == "all" and not self.visible_indices:
            self.visible_indices = list(range(len(self.segments)))
        for pos, idx in enumerate(self.visible_indices, start=1):
            seg = self.segments[idx]
            conf = ""
            if seg.confidence is not None:
                conf = f"  conf={seg.confidence:.3f}"
            mark = "*" if segment_key(seg) in self.changed_keys else " "
            label = f"{mark}{pos:02d} [{idx+1:02d}]  {seg.start}->{seg.end}  {seg.grid}  {','.join(map(str, seg.active))}{conf}"
            self.seg_list.insert(tk.END, label)

    def _draw_timeline(self) -> None:
        self.timeline_canvas.delete("all")
        if not self.segments:
            return

        w = max(10, int(self.timeline_canvas.winfo_width() or 1020))
        h = max(10, int(self.timeline_canvas.winfo_height() or 54))

        start0 = parse_time_token(self.segments[0].start)
        endn = parse_time_token(self.segments[-1].end)
        total = max(1.0, endn - start0)

        for i, seg in enumerate(self.segments):
            a = parse_time_token(seg.start)
            b = parse_time_token(seg.end)
            x0 = int((a - start0) / total * (w - 1))
            x1 = max(x0 + 2, int((b - start0) / total * (w - 1)))
            conf = seg.confidence if seg.confidence is not None else 0.8
            if conf < 0.45:
                fill = "#c0392b"
            elif conf < 0.65:
                fill = "#f39c12"
            else:
                fill = "#27ae60"
            if segment_key(seg) in self.changed_keys:
                outline = "#ffffff"
                width = 2
            else:
                outline = "#222222"
                width = 1
            self.timeline_canvas.create_rectangle(x0, 8, x1, h - 8, fill=fill, outline=outline, width=width)
            if i == self.current_index:
                self.timeline_canvas.create_line(x0, 2, x0, h - 2, fill="#00d9ff", width=2)

    def _on_timeline_canvas_configure(self, _event=None) -> None:
        self._draw_timeline()

    def _on_preview_canvas_configure(self, _event=None) -> None:
        # Redrawing after a short delay keeps resize smooth and avoids
        # repeatedly rebuilding images while the user is still dragging.
        if self.resize_after_id:
            self.root.after_cancel(self.resize_after_id)
        self.resize_after_id = self.root.after(80, self._redraw_current_preview)

    def _redraw_current_preview(self) -> None:
        self.resize_after_id = None
        if not self.segments or self.current_render_image is None:
            return
        self._render_current_to_canvas()

    def _on_timeline_click(self, event) -> None:
        if not self.segments:
            return
        w = max(10, int(self.timeline_canvas.winfo_width() or 1020))
        pos = min(max(0, int(event.x)), w - 1)

        start0 = parse_time_token(self.segments[0].start)
        endn = parse_time_token(self.segments[-1].end)
        total = max(1.0, endn - start0)
        t = start0 + (pos / float(w - 1)) * total

        pick = 0
        for i, seg in enumerate(self.segments):
            a = parse_time_token(seg.start)
            b = parse_time_token(seg.end)
            if a <= t <= b:
                pick = i
                break
        self.commit_current_segment(silent=True)
        self._load_segment(pick)

    def _preview_point_to_source(self, px: int, py: int) -> Optional[Tuple[float, float]]:
        rx, ry, rw, rh = self.current_edit_display_rect
        src_w, src_h = self.current_edit_source_size
        if rw <= 0 or rh <= 0 or src_w <= 0 or src_h <= 0:
            return None
        lx = px - rx
        ly = py - ry
        if lx < 0 or ly < 0 or lx >= rw or ly >= rh:
            return None
        sx = float(lx) * float(src_w) / float(rw)
        sy = float(ly) * float(src_h) / float(rh)
        return (sx, sy)

    def _cell_at_source_point(self, seg: Segment, sx: float, sy: float) -> Optional[int]:
        img_w, img_h = self.current_image_size
        if img_w <= 0 or img_h <= 0:
            return None
        for idx, x0, y0, x1, y1 in segment_cell_rects(seg, img_w, img_h):
            if x0 <= sx < x1 and y0 <= sy < y1:
                return idx
        return None

    def _toggle_active_cell(self, idx: int, append_only: bool = False) -> None:
        active = self._get_active_list()
        if append_only:
            if idx in active:
                active = [v for v in active if v != idx]
            active.append(idx)
        else:
            if idx in active:
                active = [v for v in active if v != idx]
                if not active:
                    active = [idx]
            else:
                active.append(idx)
        active = normalize_active(active, self.grid_var.get().strip() or "1x1")
        self._set_active_list(active)
        self.commit_current_segment(silent=True)
        self._load_segment(self.current_index)

    def _on_preview_click(self, event) -> None:
        if not self.segments:
            return
        pt = self._preview_point_to_source(int(event.x), int(event.y))
        if pt is None:
            return
        seg = self.segments[self.current_index]
        cell = self._cell_at_source_point(seg, pt[0], pt[1])
        if cell is None:
            return
        self._toggle_active_cell(cell, append_only=False)

    def _on_preview_shift_click(self, event) -> None:
        if not self.segments:
            return
        pt = self._preview_point_to_source(int(event.x), int(event.y))
        if pt is None:
            return
        seg = self.segments[self.current_index]
        cell = self._cell_at_source_point(seg, pt[0], pt[1])
        if cell is None:
            return
        self._toggle_active_cell(cell, append_only=True)

    def _segment_frame(self, idx: int) -> Image.Image:
        seg = self.segments[idx]
        frame_path = ensure_preview_frame(self.webcam_file, self.review_dir, seg, idx)
        if not frame_path.is_file() or frame_path.stat().st_size == 0:
            img = Image.new("RGB", (960, 540), color=(35, 35, 35))
            draw = ImageDraw.Draw(img)
            draw.text((20, 20), "Preview frame unavailable", fill=(255, 120, 120))
            return img
        base = Image.open(frame_path).convert("RGB")
        return base

    def _render_segment_view(self, idx: int) -> Tuple[Image.Image, Tuple[int, int, int, int], Tuple[int, int]]:
        seg = self.segments[idx]
        base = self._segment_frame(idx)
        cur = draw_overlay(base.copy(), seg)

        if not self.side_by_side_var.get():
            return cur, (0, 0, cur.width, cur.height), (cur.width, cur.height)

        auto_seg = self.auto_segments_map.get(segment_key(seg))
        auto = draw_overlay(base.copy(), auto_seg if auto_seg is not None else seg)

        header_h = 28
        gap = 8
        panel_w = max(auto.width, cur.width)
        panel_h = max(auto.height, cur.height)
        canvas = Image.new("RGB", (panel_w * 2 + gap, panel_h + header_h), color=(24, 24, 24))
        draw = ImageDraw.Draw(canvas)
        draw.text((10, 6), "AUTO", fill=(180, 220, 255))
        draw.text((panel_w + gap + 10, 6), "CURRENT (editable)", fill=(120, 255, 120))
        canvas.paste(auto, (0, header_h))
        canvas.paste(cur, (panel_w + gap, header_h))
        edit_rect = (panel_w + gap, header_h, cur.width, cur.height)
        return canvas, edit_rect, (cur.width, cur.height)

    def _render_current_to_canvas(self) -> None:
        if self.current_render_image is None:
            return

        img = self.current_render_image
        self.current_image_size = (img.width, img.height)

        canvas_w = int(self.preview_canvas.winfo_width() or 1020)
        canvas_h = int(self.preview_canvas.winfo_height() or 620)
        max_w = max(64, canvas_w - 8)
        max_h = max(64, canvas_h - 8)
        ratio = min(max_w / img.width, max_h / img.height, 1.0)
        disp_w = max(1, int(img.width * ratio))
        disp_h = max(1, int(img.height * ratio))
        disp = img.resize((disp_w, disp_h), Image.Resampling.LANCZOS)
        self.current_display_size = (disp_w, disp_h)

        off_x = max(0, (canvas_w - disp_w) // 2)
        off_y = max(0, (canvas_h - disp_h) // 2)
        self.current_preview_offset = (off_x, off_y)

        ex, ey, ew, eh = self.current_edit_rect_src
        scale_x = float(disp_w) / float(img.width)
        scale_y = float(disp_h) / float(img.height)
        drx = off_x + int(round(ex * scale_x))
        dry = off_y + int(round(ey * scale_y))
        drw = max(1, int(round(ew * scale_x)))
        drh = max(1, int(round(eh * scale_y)))
        self.current_edit_display_rect = (drx, dry, drw, drh)

        self.tk_img = ImageTk.PhotoImage(disp)
        self.preview_canvas.delete("all")
        self.preview_canvas.create_image(off_x, off_y, image=self.tk_img, anchor=tk.NW)
        self._draw_timeline()

    def _load_segment(self, idx: int) -> None:
        if not self.segments:
            return
        idx = max(0, min(len(self.segments) - 1, idx))
        self.current_index = idx
        seg = self.segments[idx]

        self.seg_list.selection_clear(0, tk.END)
        if idx in self.visible_indices:
            vis = self.visible_indices.index(idx)
            self.seg_list.selection_set(vis)
            self.seg_list.see(vis)

        self.grid_var.set(seg.grid)
        self.bbox_var.set(seg.bbox or "")
        self._set_active_list(seg.active)

        conf = "n/a" if seg.confidence is None else f"{seg.confidence:.3f}"
        self.seg_info_var.set(f"Segment {idx+1}/{len(self.segments)}  |  {seg.start} -> {seg.end}  |  confidence={conf}")

        img, edit_rect_src, edit_src_size = self._render_segment_view(idx)
        self.current_render_image = img
        self.current_edit_rect_src = edit_rect_src
        self.current_edit_source_size = edit_src_size
        self._render_current_to_canvas()

    def refresh_current_preview(self) -> None:
        if not self.segments:
            return
        self._load_segment(self.current_index)

    def _set_active_list(self, values: List[int]) -> None:
        self.active_list.delete(0, tk.END)
        for v in values:
            self.active_list.insert(tk.END, str(v))

    def _get_active_list(self) -> List[int]:
        vals: List[int] = []
        for i in range(self.active_list.size()):
            s = self.active_list.get(i).strip()
            if s.isdigit():
                vals.append(int(s))
        return vals

    def _on_list_select(self, _event=None) -> None:
        sel = self.seg_list.curselection()
        if not sel:
            return
        self.commit_current_segment(silent=True)
        vis = int(sel[0])
        if vis < 0 or vis >= len(self.visible_indices):
            return
        self._load_segment(self.visible_indices[vis])

    def _on_grid_changed(self, _event=None) -> None:
        grid = self.grid_var.get().strip()
        if not re.match(r"^\d+x\d+$", grid):
            return
        if grid == "1x2" and not self.bbox_var.get().strip():
            self.bbox_var.set(DEFAULT_1X2_BBOX)
        active = normalize_active(self._get_active_list(), grid)
        self._set_active_list(active)
        if grid == "1x2" and self.auto_tb_on_grid_var.get():
            self.auto_crop_top_bottom_for_1x2(silent=True)

    def auto_crop_top_bottom_for_1x2(self, silent: bool = False) -> None:
        if not self.segments:
            return

        grid = self.grid_var.get().strip()
        if grid != "1x2":
            if not silent:
                messagebox.showinfo("Grid not 1x2", "This auto-crop helper is intended for 1x2 segments.")
            return

        base = self._segment_frame(self.current_index)
        top, bottom_ex = detect_vertical_content_bounds(base)
        crop_h = max(1, bottom_ex - top)

        # Ignore weak detections that would crop almost nothing.
        removed = base.height - crop_h
        if removed < 8 and not silent:
            messagebox.showinfo("No significant blank bars", "No strong top/bottom blank area detected for this segment.")

        self.bbox_var.set(f"0:{top}:{base.width}:{crop_h}")
        self.commit_current_segment(silent=True)
        self._load_segment(self.current_index)

    def _active_up(self) -> None:
        sel = self.active_list.curselection()
        if not sel:
            return
        i = int(sel[0])
        if i <= 0:
            return
        v = self.active_list.get(i)
        self.active_list.delete(i)
        self.active_list.insert(i - 1, v)
        self.active_list.selection_set(i - 1)

    def _active_down(self) -> None:
        sel = self.active_list.curselection()
        if not sel:
            return
        i = int(sel[0])
        if i >= self.active_list.size() - 1:
            return
        v = self.active_list.get(i)
        self.active_list.delete(i)
        self.active_list.insert(i + 1, v)
        self.active_list.selection_set(i + 1)

    def _active_remove(self) -> None:
        sel = self.active_list.curselection()
        if not sel:
            return
        self.active_list.delete(int(sel[0]))

    def _keep_only_selected_active(self) -> None:
        sel = list(self.active_list.curselection())
        if not sel:
            messagebox.showinfo("Nothing selected", "Select one or more webcam cells in Active order first.")
            return
        values: List[int] = []
        for i in sel:
            s = self.active_list.get(i).strip()
            if s.isdigit():
                values.append(int(s))
        if not values:
            return
        values = normalize_active(values, self.grid_var.get().strip() or "1x1")
        self._set_active_list(values)
        self.commit_current_segment(silent=True)
        self._load_segment(self.current_index)

    def _active_add(self) -> None:
        s = self.add_var.get().strip()
        if not s.isdigit():
            return
        v = int(s)
        total = grid_cells_count(self.grid_var.get())
        if not (1 <= v <= total):
            messagebox.showwarning("Invalid index", f"Index must be in 1..{total}")
            return
        cur = self._get_active_list()
        if v not in cur:
            self.active_list.insert(tk.END, str(v))
        self.add_var.set("")

    def _active_reset(self) -> None:
        total = grid_cells_count(self.grid_var.get())
        vals = list(range(1, total + 1))
        self._set_active_list(vals)

    def commit_current_segment(self, silent: bool = False) -> bool:
        if not self.segments:
            return False
        seg = self.segments[self.current_index]
        grid = self.grid_var.get().strip()
        if not re.match(r"^\d+x\d+$", grid):
            if not silent:
                messagebox.showerror("Invalid grid", "Grid must be RxC, e.g. 2x2")
            return False

        active = normalize_active(self._get_active_list(), grid)
        bbox = self.bbox_var.get().strip()
        if grid == "1x2" and not bbox:
            bbox = DEFAULT_1X2_BBOX
            self.bbox_var.set(bbox)
        if bbox:
            parts = bbox.split(":")
            if len(parts) != 4:
                if not silent:
                    messagebox.showerror("Invalid bbox", "BBox must be x:y:w:h")
                return False
            for p in parts:
                if not p.strip().replace(".", "", 1).isdigit():
                    if not silent:
                        messagebox.showerror("Invalid bbox", "BBox must be x:y:w:h")
                    return False

        seg.grid = grid
        seg.active = active
        seg.bbox = bbox or None

        self._refresh_changed_flags()
        self.apply_segment_filter(reload_segment=False)
        if self.current_index in self.visible_indices:
            vis = self.visible_indices.index(self.current_index)
            self.seg_list.selection_set(vis)
        return True

    def prev_segment(self) -> None:
        if not self.commit_current_segment():
            return
        if self.current_index not in self.visible_indices:
            if self.visible_indices:
                self._load_segment(self.visible_indices[0])
            return
        vis = self.visible_indices.index(self.current_index)
        vis = max(0, vis - 1)
        self._load_segment(self.visible_indices[vis])

    def next_segment(self) -> None:
        if not self.commit_current_segment():
            return
        if self.current_index not in self.visible_indices:
            if self.visible_indices:
                self._load_segment(self.visible_indices[0])
            return
        vis = self.visible_indices.index(self.current_index)
        vis = min(len(self.visible_indices) - 1, vis + 1)
        self._load_segment(self.visible_indices[vis])

    def save_manual_plan(self, silent: bool = False) -> None:
        if not self.segments:
            if not silent:
                messagebox.showwarning("No segments", "Nothing to save")
            return
        if not self.commit_current_segment(silent=silent):
            return

        lines = ["# edited in bbb_webcams_plan_gui.py", "# start end grid active [bbox]"]
        for seg in self.segments:
            active = ",".join(str(v) for v in seg.active)
            row = f"{seg.start} {seg.end} {seg.grid} {active}"
            if seg.bbox:
                row += f" {seg.bbox}"
            lines.append(row)

        self.manual_plan.write_text("\n".join(lines) + "\n", encoding="utf-8")
        self.refresh_status()
        if not silent:
            messagebox.showinfo("Saved", f"Manual plan saved:\n{self.manual_plan}")


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description="BBB GUI control center")
    p.add_argument("recording_dir", help="Recording folder, e.g. 2026-08-04")
    p.add_argument("num", help="Presentation number, e.g. 01")
    p.add_argument("--diag", action="store_true", help="Run GUI environment diagnostics and exit")
    p.add_argument("--self-test", action="store_true", help="Construct app and exit (no mainloop)")
    p.add_argument("--crash-log", default="", help="Custom crash log path (default: <recording>/output/<NUM>/gui-crash.log)")
    return p


def main() -> int:
    args = build_parser().parse_args()
    rec_dir = Path(args.recording_dir)
    num = str(args.num)
    default_crash_log = rec_dir / "output" / num / "gui-crash.log"
    crash_log = Path(args.crash_log) if str(args.crash_log).strip() else default_crash_log

    if not rec_dir.is_dir():
        print(f"Recording directory not found: {rec_dir}", file=sys.stderr)
        return 2

    if args.diag:
        print("GUI Diagnostics")
        print(f"python: {sys.executable}")
        print(f"platform: {sys.platform}")
        print(f"recording_dir_exists: {rec_dir.is_dir()}")
        print(f"crash_log: {crash_log}")
        try:
            import tkinter as _tk  # noqa: F401
            print("tkinter_import: OK")
        except Exception as exc:
            append_log(crash_log, f"tkinter_import FAIL\n{exc}")
            print(f"tkinter_import: FAIL ({exc})")
            return 4
        try:
            t = tk.Tk()
            t.update_idletasks()
            t.destroy()
            print("tk_window_create: OK")
        except Exception as exc:
            append_log(crash_log, f"tk_window_create FAIL\n{exc}")
            print(f"tk_window_create: FAIL ({exc})")
            print("hint: launch from native Terminal.app, not VS Code sandbox/integrated runner")
            return 5
        return 0

    try:
        root = tk.Tk()
    except tk.TclError as exc:
        append_log(crash_log, f"tk.Tk() failed\n{exc}")
        print("GUI error: unable to open window. Ensure a desktop session is available.", file=sys.stderr)
        print(str(exc), file=sys.stderr)
        print(f"crash log: {crash_log}", file=sys.stderr)
        print("hint: run in Terminal.app with: python3 bbb_webcams_plan_gui.py 2026-08-04 01", file=sys.stderr)
        return 3

    def _global_excepthook(exc_type, exc_value, exc_tb):
        details = "".join(traceback.format_exception(exc_type, exc_value, exc_tb))
        append_log(crash_log, "[GUI fatal error]\n" + details)
        print(details, file=sys.stderr)
        print(f"crash log: {crash_log}", file=sys.stderr)
        try:
            messagebox.showerror("GUI fatal error", details)
        except Exception:
            pass

    sys.excepthook = _global_excepthook

    try:
        _app = PlanEditorApp(root, rec_dir, num, crash_log)
    except Exception as exc:
        details = traceback.format_exc()
        append_log(crash_log, "[App init error]\n" + details)
        root.destroy()
        print("Error while initializing GUI:", file=sys.stderr)
        print(details, file=sys.stderr)
        print(f"crash log: {crash_log}", file=sys.stderr)
        return 1

    if args.self_test:
        root.update_idletasks()
        root.destroy()
        print("self_test: OK")
        return 0

    root.mainloop()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
