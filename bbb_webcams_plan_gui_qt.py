#!/usr/bin/env python3
"""Responsive Qt GUI for webcams plan editing.

This app focuses on the plan-editor workflow and reuses the parsing/overlay
helpers from bbb_webcams_plan_gui.py.
"""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import List, Optional, Tuple

try:
    from PySide6 import QtCore, QtGui, QtWidgets
except Exception:
    print("PySide6 is required. Install with: pip3 install PySide6", file=sys.stderr)
    raise

import bbb_webcams_plan_gui as core


DEFAULT_1X2_BBOX = "0:270:1920:540"


class PreviewLabel(QtWidgets.QLabel):
    clicked = QtCore.Signal(int, int)

    def mousePressEvent(self, event: QtGui.QMouseEvent) -> None:
        p = event.position().toPoint()
        self.clicked.emit(int(p.x()), int(p.y()))
        super().mousePressEvent(event)


class PlanEditorQt(QtWidgets.QMainWindow):
    def __init__(self, rec_dir: Path, num: str):
        super().__init__()
        self.rec_dir = rec_dir
        self.num = num
        self.out_dir = rec_dir / "output" / num
        self.webcam_file = self.out_dir / "webcam.mp4"
        self.slides_file = self.out_dir / "slides.mp4"
        self.deskshare_file = self.out_dir / "deskshare.mp4"
        self.auto_plan = self.out_dir / "webcams_plan.auto.txt"
        self.manual_plan = self.out_dir / "webcams_plan.manual.txt"
        self.meta_path = self.out_dir / "webcams_plan.auto.meta.json"
        self.review_dir = self.out_dir / "webcams" / "review_plan"
        self.yaml_path = rec_dir / "presentations_cut.yaml"
        self.webcam_file_s = str(self.webcam_file)
        self.review_dir_s = str(self.review_dir)

        self.segments: List[core.Segment] = []
        self.auto_segments_map: dict[Tuple[str, str], core.Segment] = {}
        self.changed_keys: set[Tuple[str, str]] = set()
        self.visible_indices: List[int] = []
        self.current_index: int = 0

        self.render_image: Optional[QtGui.QImage] = None
        self.edit_rect_src: Tuple[int, int, int, int] = (0, 0, 0, 0)
        self.edit_source_size: Tuple[int, int] = (0, 0)
        self.edit_display_rect: Tuple[int, int, int, int] = (0, 0, 0, 0)
        self.process: Optional[QtCore.QProcess] = None
        self._syncing_ui = False

        self.setWindowTitle(f"BBB Plan Editor (Qt) - {rec_dir.name} / {num}")
        self.resize(1500, 820)
        self.setMinimumSize(1100, 700)
        self._build_ui()
        self.load_metadata_fields()
        self.load_plan(prefer_manual=True)
        self.refresh_status()

    def _build_ui(self) -> None:
        root = QtWidgets.QWidget(self)
        self.setCentralWidget(root)
        layout = QtWidgets.QVBoxLayout(root)

        self.tabs = QtWidgets.QTabWidget()
        layout.addWidget(self.tabs, 1)

        self.tab_metadata = QtWidgets.QWidget()
        self.tab_pipeline = QtWidgets.QWidget()
        self.tab_plan = QtWidgets.QWidget()
        self.tabs.addTab(self.tab_metadata, "Metadata")
        self.tabs.addTab(self.tab_pipeline, "Pipeline")
        self.tabs.addTab(self.tab_plan, "Webcams Plan Editor")

        self._build_metadata_tab()
        self._build_pipeline_tab()
        self._build_plan_tab()

    def _build_metadata_tab(self) -> None:
        layout = QtWidgets.QVBoxLayout(self.tab_metadata)

        box = QtWidgets.QGroupBox("Presentation Metadata")
        form = QtWidgets.QFormLayout(box)

        self.meta_start_edit = QtWidgets.QLineEdit()
        self.meta_end_edit = QtWidgets.QLineEdit()
        self.meta_presenter_edit = QtWidgets.QLineEdit()
        self.meta_title_edit = QtWidgets.QLineEdit()
        self.meta_info_edit = QtWidgets.QLineEdit()

        form.addRow("Start", self.meta_start_edit)
        form.addRow("End", self.meta_end_edit)
        form.addRow("Author / Presenter", self.meta_presenter_edit)
        form.addRow("Short Title", self.meta_title_edit)
        form.addRow("Info", self.meta_info_edit)

        row = QtWidgets.QHBoxLayout()
        self.btn_reload_metadata = QtWidgets.QPushButton("Reload from YAML")
        self.btn_save_metadata = QtWidgets.QPushButton("Save metadata to YAML")
        row.addWidget(self.btn_reload_metadata)
        row.addWidget(self.btn_save_metadata)
        row.addStretch(1)
        form.addRow(row)

        layout.addWidget(box)
        layout.addStretch(1)

        self.btn_reload_metadata.clicked.connect(self.load_metadata_fields)
        self.btn_save_metadata.clicked.connect(self.save_metadata_fields)

    def _build_pipeline_tab(self) -> None:
        layout = QtWidgets.QVBoxLayout(self.tab_pipeline)

        meta_box = QtWidgets.QGroupBox("Context")
        meta_layout = QtWidgets.QFormLayout(meta_box)
        meta_layout.addRow("Recording", QtWidgets.QLabel(str(self.rec_dir)))
        meta_layout.addRow("Presentation", QtWidgets.QLabel(self.num))
        layout.addWidget(meta_box)

        guided_box = QtWidgets.QGroupBox("Guided Workflow (Recommended)")
        guided_layout = QtWidgets.QVBoxLayout(guided_box)
        guided_layout.addWidget(QtWidgets.QLabel("Use this simple flow: detect -> review/edit -> split+compose"))

        guided_btns = QtWidgets.QHBoxLayout()
        self.btn_guided_prepare = QtWidgets.QPushButton("1) Prepare clips + auto plan")
        self.btn_guided_review = QtWidgets.QPushButton("2) Open plan editor tab")
        self.btn_guided_finalize = QtWidgets.QPushButton("3) Split manual + compose")
        guided_btns.addWidget(self.btn_guided_prepare)
        guided_btns.addWidget(self.btn_guided_review)
        guided_btns.addWidget(self.btn_guided_finalize)
        guided_layout.addLayout(guided_btns)
        layout.addWidget(guided_box)

        run_box = QtWidgets.QGroupBox("Advanced Options")
        run_box.setCheckable(True)
        run_box.setChecked(False)
        run_layout = QtWidgets.QGridLayout(run_box)

        self.step_edit = QtWidgets.QLineEdit("2")
        self.step_edit.setFixedWidth(60)
        self.encoder_combo = QtWidgets.QComboBox()
        self.encoder_combo.addItems(["h264_videotoolbox", "libx264"])
        self.encoder_combo.setCurrentText("h264_videotoolbox")
        self.review_mode_combo = QtWidgets.QComboBox()
        self.review_mode_combo.addItems(["all", "changed", "low", "smart"])
        self.review_mode_combo.setCurrentText("smart")
        self.review_conf_edit = QtWidgets.QLineEdit("0.62")
        self.review_conf_edit.setFixedWidth(70)

        run_layout.addWidget(QtWidgets.QLabel("STEP"), 0, 0)
        run_layout.addWidget(self.step_edit, 0, 1)
        run_layout.addWidget(QtWidgets.QLabel("ENCODER"), 0, 2)
        run_layout.addWidget(self.encoder_combo, 0, 3)
        run_layout.addWidget(QtWidgets.QLabel("REVIEW_MODE"), 0, 4)
        run_layout.addWidget(self.review_mode_combo, 0, 5)
        run_layout.addWidget(QtWidgets.QLabel("REVIEW_CONF"), 0, 6)
        run_layout.addWidget(self.review_conf_edit, 0, 7)

        self.btn_make_clips = QtWidgets.QPushButton("1) Make clips")
        self.btn_auto_plan = QtWidgets.QPushButton("2) Auto detect plan")
        self.btn_review_assets = QtWidgets.QPushButton("3) Generate review assets")
        self.btn_split_manual = QtWidgets.QPushButton("4) Split webcams from manual plan")
        self.btn_compose = QtWidgets.QPushButton("5) Compose final video")
        self.btn_run_chain = QtWidgets.QPushButton("Run 2->3->4->5")
        self.btn_refresh_status = QtWidgets.QPushButton("Refresh status")

        run_layout.addWidget(self.btn_make_clips, 1, 0, 1, 2)
        run_layout.addWidget(self.btn_auto_plan, 1, 2, 1, 2)
        run_layout.addWidget(self.btn_review_assets, 1, 4, 1, 2)
        run_layout.addWidget(self.btn_split_manual, 2, 0, 1, 2)
        run_layout.addWidget(self.btn_compose, 2, 2, 1, 2)
        run_layout.addWidget(self.btn_run_chain, 2, 4, 1, 2)
        run_layout.addWidget(self.btn_refresh_status, 3, 0, 1, 2)
        layout.addWidget(run_box)

        status_box = QtWidgets.QGroupBox("What Remains")
        status_layout = QtWidgets.QFormLayout(status_box)
        self.status_labels = {
            "clips": QtWidgets.QLabel(),
            "auto_plan": QtWidgets.QLabel(),
            "manual_plan": QtWidgets.QLabel(),
            "split_outputs": QtWidgets.QLabel(),
            "review_assets": QtWidgets.QLabel(),
            "final_video": QtWidgets.QLabel(),
        }
        status_layout.addRow("Phase 2 clips", self.status_labels["clips"])
        status_layout.addRow("Auto plan", self.status_labels["auto_plan"])
        status_layout.addRow("Manual plan", self.status_labels["manual_plan"])
        status_layout.addRow("Split webcam clips", self.status_labels["split_outputs"])
        status_layout.addRow("Review assets", self.status_labels["review_assets"])
        status_layout.addRow("Final video", self.status_labels["final_video"])
        layout.addWidget(status_box)

        log_box = QtWidgets.QGroupBox("Logs")
        log_layout = QtWidgets.QVBoxLayout(log_box)
        self.log_text = QtWidgets.QPlainTextEdit()
        self.log_text.setReadOnly(True)
        self.log_text.setMaximumBlockCount(5000)
        log_layout.addWidget(self.log_text, 1)
        layout.addWidget(log_box, 1)

        self.btn_make_clips.clicked.connect(self.run_phase_make_clips)
        self.btn_auto_plan.clicked.connect(self.run_phase_auto_plan)
        self.btn_review_assets.clicked.connect(self.run_phase_review_assets)
        self.btn_split_manual.clicked.connect(self.run_phase_split_manual)
        self.btn_compose.clicked.connect(self.run_phase_compose)
        self.btn_run_chain.clicked.connect(self.run_pipeline_after_clips)
        self.btn_refresh_status.clicked.connect(self.refresh_status)
        self.btn_guided_prepare.clicked.connect(self.run_guided_prepare)
        self.btn_guided_review.clicked.connect(self.open_plan_tab)
        self.btn_guided_finalize.clicked.connect(self.run_guided_finalize)

    def _build_plan_tab(self) -> None:
        layout = QtWidgets.QVBoxLayout(self.tab_plan)

        top = QtWidgets.QHBoxLayout()
        layout.addLayout(top)

        self.btn_load_auto = QtWidgets.QPushButton("Load AUTO")
        self.btn_load_manual = QtWidgets.QPushButton("Load MANUAL")
        self.btn_save_manual = QtWidgets.QPushButton("Save manual")
        self.btn_auto_crop = QtWidgets.QPushButton("Auto crop top/bottom (1x2)")

        top.addWidget(self.btn_load_auto)
        top.addWidget(self.btn_load_manual)
        top.addWidget(self.btn_save_manual)
        top.addWidget(self.btn_auto_crop)

        top.addSpacing(14)
        top.addWidget(QtWidgets.QLabel("Filter"))
        self.filter_combo = QtWidgets.QComboBox()
        self.filter_combo.addItems(["all", "changed", "low", "changed+low"])
        top.addWidget(self.filter_combo)

        self.count_label = QtWidgets.QLabel("Segments: 0/0")
        top.addWidget(self.count_label)

        top.addSpacing(14)
        top.addWidget(QtWidgets.QLabel("REVIEW_CONF"))
        self.conf_edit = QtWidgets.QLineEdit("0.62")
        self.conf_edit.setFixedWidth(70)
        top.addWidget(self.conf_edit)

        self.side_by_side = QtWidgets.QCheckBox("Side-by-side AUTO/Current")
        self.side_by_side.setChecked(True)
        top.addWidget(self.side_by_side)
        self.btn_reset_layout = QtWidgets.QPushButton("Reset layout")
        top.addWidget(self.btn_reset_layout)
        top.addStretch(1)

        self.plan_splitter = QtWidgets.QSplitter(QtCore.Qt.Orientation.Horizontal)
        layout.addWidget(self.plan_splitter, 1)

        left = QtWidgets.QWidget()
        left_layout = QtWidgets.QVBoxLayout(left)
        self.seg_list = QtWidgets.QListWidget()
        left_layout.addWidget(self.seg_list, 1)
        self.plan_splitter.addWidget(left)

        right = QtWidgets.QWidget()
        right_layout = QtWidgets.QVBoxLayout(right)
        self.preview = PreviewLabel()
        self.preview.setAlignment(QtCore.Qt.AlignmentFlag.AlignCenter)
        self.preview.setMinimumHeight(340)
        self.preview.setStyleSheet("background:#111; border:1px solid #333;")
        right_layout.addWidget(self.preview, 1)

        form = QtWidgets.QGridLayout()
        right_layout.addLayout(form)

        self.info_label = QtWidgets.QLabel("Segment")
        form.addWidget(self.info_label, 0, 0, 1, 8)

        form.addWidget(QtWidgets.QLabel("Grid"), 1, 0)
        self.grid_edit = QtWidgets.QComboBox()
        self.grid_edit.addItems(list(core.GRID_CHOICES))
        self.grid_edit.setEditable(True)
        form.addWidget(self.grid_edit, 1, 1)

        form.addWidget(QtWidgets.QLabel("BBox x:y:w:h"), 1, 2)
        self.bbox_edit = QtWidgets.QLineEdit()
        form.addWidget(self.bbox_edit, 1, 3, 1, 3)

        form.addWidget(QtWidgets.QLabel("Active order (priority)"), 2, 0)
        self.active_list = QtWidgets.QListWidget()
        self.active_list.setSelectionMode(QtWidgets.QAbstractItemView.SelectionMode.ExtendedSelection)
        self.active_list.setMinimumHeight(150)
        form.addWidget(self.active_list, 3, 0, 4, 2)

        btn_col = QtWidgets.QVBoxLayout()
        self.btn_up = QtWidgets.QPushButton("Up")
        self.btn_down = QtWidgets.QPushButton("Down")
        self.btn_remove = QtWidgets.QPushButton("Remove")
        self.btn_keep = QtWidgets.QPushButton("Keep selected")
        self.btn_reset = QtWidgets.QPushButton("Reset 1..N")
        self.btn_apply = QtWidgets.QPushButton("Apply segment edits")
        for b in [self.btn_up, self.btn_down, self.btn_remove, self.btn_keep, self.btn_reset, self.btn_apply]:
            btn_col.addWidget(b)
        btn_col.addStretch(1)
        form.addLayout(btn_col, 3, 2, 4, 1)

        nav = QtWidgets.QHBoxLayout()
        self.btn_prev = QtWidgets.QPushButton("Prev")
        self.btn_next = QtWidgets.QPushButton("Next")
        nav.addWidget(self.btn_prev)
        nav.addWidget(self.btn_next)
        nav.addStretch(1)
        right_layout.addLayout(nav)

        self.plan_splitter.addWidget(right)
        self.reset_plan_splitter()

        self.btn_load_auto.clicked.connect(lambda: self.load_plan(prefer_manual=False))
        self.btn_load_manual.clicked.connect(lambda: self.load_plan(prefer_manual=True, force_manual=True))
        self.btn_save_manual.clicked.connect(self.save_manual_plan)
        self.btn_auto_crop.clicked.connect(self.auto_crop_top_bottom_for_1x2)

        self.filter_combo.currentTextChanged.connect(lambda _v: self.apply_segment_filter(reload_segment=True))
        self.conf_edit.editingFinished.connect(lambda: self.apply_segment_filter(reload_segment=True))
        self.side_by_side.stateChanged.connect(lambda _v: self.refresh_current_preview())
        self.btn_reset_layout.clicked.connect(self.reset_plan_splitter)

        self.seg_list.currentRowChanged.connect(self._on_seg_list_row_changed)
        self.preview.clicked.connect(self._on_preview_click)

        self.grid_edit.currentTextChanged.connect(self._on_grid_changed)
        self.btn_up.clicked.connect(self._active_up)
        self.btn_down.clicked.connect(self._active_down)
        self.btn_remove.clicked.connect(self._active_remove)
        self.btn_keep.clicked.connect(self._keep_only_selected_active)
        self.btn_reset.clicked.connect(self._active_reset)
        self.btn_apply.clicked.connect(self.commit_current_segment)
        self.btn_prev.clicked.connect(self.prev_segment)
        self.btn_next.clicked.connect(self.next_segment)

        self._resize_timer = QtCore.QTimer(self)
        self._resize_timer.setSingleShot(True)
        self._resize_timer.setInterval(70)
        self._resize_timer.timeout.connect(self._render_current_to_preview)

    def reset_plan_splitter(self) -> None:
        total = max(1200, self.width() - 80)
        left = max(320, int(total * 0.28))
        right = max(700, total - left)
        if hasattr(self, "plan_splitter"):
            self.plan_splitter.setSizes([left, right])

    def resizeEvent(self, event: QtGui.QResizeEvent) -> None:
        self._resize_timer.start()
        super().resizeEvent(event)

    def _phase_env(self) -> QtCore.QProcessEnvironment:
        env = QtCore.QProcessEnvironment.systemEnvironment()
        env.insert("BBB_VENC", self.encoder_combo.currentText().strip() or "h264_videotoolbox")
        env.insert("STEP", self.step_edit.text().strip() or "2")
        env.insert("REVIEW_MODE", self.review_mode_combo.currentText().strip() or "smart")
        env.insert("REVIEW_CONFIDENCE", self.review_conf_edit.text().strip() or "0.62")
        return env

    def _log(self, text: str) -> None:
        self.log_text.moveCursor(QtGui.QTextCursor.MoveOperation.End)
        self.log_text.insertPlainText(text)
        self.log_text.moveCursor(QtGui.QTextCursor.MoveOperation.End)

    def _set_busy(self, busy: bool) -> None:
        buttons = [
            self.btn_make_clips,
            self.btn_auto_plan,
            self.btn_review_assets,
            self.btn_split_manual,
            self.btn_compose,
            self.btn_run_chain,
        ]
        for btn in buttons:
            btn.setEnabled(not busy)

    def _run_cmd(self, cmd: List[str], env: Optional[QtCore.QProcessEnvironment] = None, done=None) -> None:
        if self.process is not None:
            QtWidgets.QMessageBox.warning(self, "Busy", "A command is already running. Please wait.")
            return

        self._log("\n$ " + " ".join(cmd) + "\n")
        proc = QtCore.QProcess(self)
        proc.setProgram(cmd[0])
        proc.setArguments(cmd[1:])
        proc.setWorkingDirectory(str(Path.cwd()))
        if env is not None:
            proc.setProcessEnvironment(env)
        proc.setProcessChannelMode(QtCore.QProcess.ProcessChannelMode.MergedChannels)
        proc.readyReadStandardOutput.connect(lambda: self._log(bytes(proc.readAllStandardOutput()).decode(errors="replace")))

        def finished(exit_code: int, _status) -> None:
            self._log(f"\n[exit {exit_code}]\n")
            self.process = None
            self._set_busy(False)
            if done is not None:
                done(exit_code)

        proc.finished.connect(finished)
        self.process = proc
        self._set_busy(True)
        proc.start()

    def run_phase_make_clips(self) -> None:
        self._run_cmd(["./bbb_make_clips.sh", str(self.rec_dir), "encode", self.num], env=self._phase_env(), done=lambda _c: self.refresh_status())

    def run_phase_auto_plan(self) -> None:
        env = self._phase_env()
        env.insert("REVIEW", "0")
        env.insert("APPLY", "0")
        env.insert("SPLIT", "0")
        self._run_cmd(["./bbb_split_webcams_v3.sh", str(self.rec_dir), self.num], env=env, done=lambda _c: self._after_auto_plan())

    def _after_auto_plan(self) -> None:
        self.load_plan(prefer_manual=False)
        self.refresh_status()

    def run_phase_review_assets(self) -> None:
        self._run_cmd(["./bbb_review_webcams.sh", str(self.rec_dir), self.num], env=self._phase_env(), done=lambda _c: self.refresh_status())

    def run_phase_split_manual(self) -> None:
        self.save_manual_plan(show_message=False)
        env = self._phase_env()
        env.insert("MANUAL_PLAN", str(self.manual_plan))
        self._run_cmd(["./bbb_split_webcams.sh", str(self.rec_dir), self.num], env=env, done=lambda _c: self.refresh_status())

    def run_phase_compose(self) -> None:
        self._run_cmd(["./bbb_compose.sh", str(self.rec_dir), self.num], env=self._phase_env(), done=lambda _c: self.refresh_status())

    def open_plan_tab(self) -> None:
        self.tabs.setCurrentWidget(self.tab_plan)

    def run_guided_prepare(self) -> None:
        def after_make(code: int) -> None:
            if code != 0:
                self.refresh_status()
                return
            env = self._phase_env()
            env.insert("REVIEW", "0")
            env.insert("APPLY", "0")
            env.insert("SPLIT", "0")
            self._run_cmd(["./bbb_split_webcams_v3.sh", str(self.rec_dir), self.num], env=env, done=lambda _c: self._after_auto_plan())

        self._run_cmd(["./bbb_make_clips.sh", str(self.rec_dir), "encode", self.num], env=self._phase_env(), done=after_make)

    def run_guided_finalize(self) -> None:
        self.save_manual_plan(show_message=False)

        def after_split(code: int) -> None:
            if code != 0:
                self.refresh_status()
                return
            self._run_cmd(["./bbb_compose.sh", str(self.rec_dir), self.num], env=self._phase_env(), done=lambda _c: self.refresh_status())

        env = self._phase_env()
        env.insert("MANUAL_PLAN", str(self.manual_plan))
        self._run_cmd(["./bbb_split_webcams.sh", str(self.rec_dir), self.num], env=env, done=after_split)

    def run_pipeline_after_clips(self) -> None:
        self.save_manual_plan(show_message=False)
        steps: List[Tuple[List[str], QtCore.QProcessEnvironment]] = []
        env_split = self._phase_env()
        env_split.insert("MANUAL_PLAN", str(self.manual_plan))
        steps.append((["./bbb_split_webcams.sh", str(self.rec_dir), self.num], env_split))
        steps.append((["./bbb_review_webcams.sh", str(self.rec_dir), self.num], self._phase_env()))
        steps.append((["./bbb_compose.sh", str(self.rec_dir), self.num], self._phase_env()))

        def run_next(i: int, prev_code: int = 0) -> None:
            if prev_code != 0:
                self.refresh_status()
                return
            if i >= len(steps):
                self.refresh_status()
                return
            cmd_i, env_i = steps[i]
            self._run_cmd(cmd_i, env=env_i, done=lambda code: run_next(i + 1, code))

        run_next(0)

    def refresh_status(self) -> None:
        clips_ok = all(path.is_file() for path in (self.webcam_file, self.slides_file, self.deskshare_file))
        auto_ok = self.auto_plan.is_file() and self.auto_plan.stat().st_size > 0
        manual_ok = self.manual_plan.is_file() and self.manual_plan.stat().st_size > 0

        split_dir = self.out_dir / "webcams"
        split_count = len(list(split_dir.glob("seg*s_cam*-of-*.mp4"))) if split_dir.is_dir() else 0
        split_ok = split_count > 0

        review_dir = split_dir / "review"
        review_ok = (review_dir / "contact-sheet.jpg").is_file() and (review_dir / "webcams-review.mp4").is_file()

        finals = [p for p in self.out_dir.glob("*.mp4") if p.name not in {"webcam.mp4", "slides.mp4", "deskshare.mp4"}]
        final_ok = len(finals) > 0

        self.status_labels["clips"].setText("OK" if clips_ok else "TODO")
        self.status_labels["auto_plan"].setText("OK" if auto_ok else "TODO")
        self.status_labels["manual_plan"].setText("OK" if manual_ok else "TODO")
        self.status_labels["split_outputs"].setText(f"OK ({split_count} clips)" if split_ok else "TODO")
        self.status_labels["review_assets"].setText("OK" if review_ok else "TODO")
        self.status_labels["final_video"].setText(f"OK ({len(finals)} file(s))" if final_ok else "TODO")

    def _review_threshold(self) -> float:
        try:
            return float(self.conf_edit.text().strip() or "0.62")
        except Exception:
            return 0.62

    def load_metadata_fields(self) -> None:
        if not self.yaml_path.is_file():
            return
        fields = core.read_presentation_fields(self.yaml_path, self.num)
        self.meta_start_edit.setText(fields.get("start", ""))
        self.meta_end_edit.setText(fields.get("end", ""))
        self.meta_presenter_edit.setText(fields.get("presenter", ""))
        self.meta_title_edit.setText(fields.get("short_title", ""))
        self.meta_info_edit.setText(fields.get("info", ""))

    def save_metadata_fields(self) -> None:
        if not self.yaml_path.is_file():
            QtWidgets.QMessageBox.critical(self, "YAML missing", f"Cannot find {self.yaml_path}")
            return

        updates = {
            "start": self.meta_start_edit.text().strip(),
            "end": self.meta_end_edit.text().strip(),
            "presenter": self.meta_presenter_edit.text().strip(),
            "short_title": self.meta_title_edit.text().strip(),
            "info": self.meta_info_edit.text().strip(),
        }
        try:
            core.write_presentation_fields(self.yaml_path, self.num, updates)
        except Exception as exc:
            QtWidgets.QMessageBox.critical(self, "Save failed", str(exc))
            return
        QtWidgets.QMessageBox.information(self, "Saved", f"Updated metadata in\n{self.yaml_path}")

    def _refresh_changed_flags(self) -> None:
        changed: set[Tuple[str, str]] = set()
        for seg in self.segments:
            key = core.segment_key(seg)
            base = self.auto_segments_map.get(key)
            if base is None or core.segment_signature(base) != core.segment_signature(seg):
                changed.add(key)
        self.changed_keys = changed

    def apply_segment_filter(self, reload_segment: bool = True) -> None:
        if not self.segments:
            self.visible_indices = []
            self.seg_list.clear()
            self.count_label.setText("Segments: 0/0")
            return

        mode = self.filter_combo.currentText().strip() or "all"
        threshold = self._review_threshold()

        indices: List[int] = []
        for i, seg in enumerate(self.segments):
            is_changed = core.segment_key(seg) in self.changed_keys
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
        self.count_label.setText(f"Segments: {len(self.visible_indices)}/{len(self.segments)}")
        self._populate_segment_list()

        if not self.visible_indices:
            self.info_label.setText("No segment matches current filter")
            self.preview.clear()
            return

        if self.current_index not in self.visible_indices:
            self.current_index = self.visible_indices[0]
        if reload_segment:
            self._load_segment(self.current_index)

    def load_plan(self, prefer_manual: bool = True, force_manual: bool = False) -> None:
        auto_segments = core.parse_plan_txt(self.auto_plan)
        self.auto_segments_map = {core.segment_key(seg): seg for seg in auto_segments}

        src = self.auto_plan
        if force_manual:
            src = self.manual_plan
        elif prefer_manual and self.manual_plan.is_file() and self.manual_plan.stat().st_size > 0:
            src = self.manual_plan

        if not src.is_file():
            src = self.auto_plan
        if not src.is_file():
            # New presentations may not have generated plan files yet.
            # Keep the app usable and guide the user to the pipeline step.
            self.segments = []
            self.visible_indices = []
            self.seg_list.clear()
            self.count_label.setText("Segments: 0/0")
            self.info_label.setText("No plan yet. Run Guided Step 1 in Pipeline to generate clips and auto plan.")
            self.preview.clear()
            return

        self.segments = core.parse_plan_txt(src)
        conf_map = core.load_confidence(self.meta_path)
        for seg in self.segments:
            seg.confidence = conf_map.get((seg.start, seg.end))

        self._refresh_changed_flags()
        self.current_index = 0
        self.apply_segment_filter(reload_segment=False)
        if self.visible_indices:
            self.current_index = self.visible_indices[0]
            self._load_segment(self.current_index)

    def _populate_segment_list(self) -> None:
        self.seg_list.clear()
        for pos, idx in enumerate(self.visible_indices, start=1):
            seg = self.segments[idx]
            conf = ""
            if seg.confidence is not None:
                conf = f"  conf={seg.confidence:.3f}"
            mark = "*" if core.segment_key(seg) in self.changed_keys else " "
            label = f"{mark}{pos:02d} [{idx+1:02d}]  {seg.start}->{seg.end}  {seg.grid}  {','.join(map(str, seg.active))}{conf}"
            self.seg_list.addItem(label)

    def _ensure_preview_frame_local(self, seg: core.Segment, index: int) -> str:
        os.makedirs(self.review_dir_s, exist_ok=True)
        safe_start = re.sub(r"[^0-9A-Za-z._-]+", "-", str(seg.start)).strip("-._") or "start"
        frame_file = os.path.join(self.review_dir_s, f"seg{index+1:02d}_{safe_start}.jpg")
        if os.path.isfile(frame_file) and os.path.getsize(frame_file) > 0:
            return frame_file

        t = max(0.0, core.parse_time_token(seg.start) + 2.0)
        cmd = [
            "ffmpeg",
            "-nostdin",
            "-v",
            "error",
            "-ss",
            f"{t:.3f}",
            "-i",
            self.webcam_file_s,
            "-frames:v",
            "1",
            frame_file,
        ]
        subprocess.run(cmd, check=False)
        return frame_file

    def _blank_qimage(self, width: int = 960, height: int = 540) -> QtGui.QImage:
        img = QtGui.QImage(width, height, QtGui.QImage.Format.Format_RGB32)
        img.fill(QtGui.QColor(35, 35, 35))
        return img

    def _detect_vertical_content_bounds_qt(
        self,
        image: QtGui.QImage,
        dark_threshold: int = 18,
        min_active_ratio: float = 0.03,
        mean_floor: float = 14.0,
        white_threshold: int = 245,
        white_banner_ratio: float = 0.92,
    ) -> Tuple[int, int]:
        gray = image.convertToFormat(QtGui.QImage.Format.Format_Grayscale8)
        w = gray.width()
        h = gray.height()
        if w <= 0 or h <= 0:
            return (0, 0)

        step = 2 if w >= 640 else 1
        samples = max(1, w // step)
        min_active = max(1, int(samples * min_active_ratio))

        active_rows: List[bool] = [False] * h
        for y in range(h):
            bright = 0
            white = 0
            row_sum = 0
            for x in range(0, w, step):
                v = QtGui.QColor(gray.pixel(x, y)).value()
                row_sum += v
                if v > dark_threshold:
                    bright += 1
                if v >= white_threshold:
                    white += 1
            mean_v = row_sum / float(samples)
            white_ratio = white / float(samples)
            # Treat near-solid white bands as non-content so top/bottom banners
            # are trimmed before 1x2 cropping.
            if white_ratio >= white_banner_ratio:
                active_rows[y] = False
            else:
                active_rows[y] = bright >= min_active or mean_v > mean_floor

        top = 0
        while top < h and not active_rows[top]:
            top += 1

        bottom = h - 1
        while bottom >= 0 and not active_rows[bottom]:
            bottom -= 1

        if bottom <= top:
            return (0, h)

        pad = 3
        top = max(0, top - pad)
        bottom = min(h - 1, bottom + pad)
        return (top, bottom + 1)

    def _parse_bbox(self, bbox: str) -> Optional[Tuple[int, int, int, int]]:
        parts = bbox.split(":")
        if len(parts) != 4:
            return None
        try:
            x, y, w, h = [int(float(p)) for p in parts]
        except Exception:
            return None
        if w <= 0 or h <= 0:
            return None
        return (x, y, w, h)

    def _draw_overlay_qt(self, base: QtGui.QImage, seg: core.Segment) -> QtGui.QImage:
        img = base.convertToFormat(QtGui.QImage.Format.Format_RGB32)
        painter = QtGui.QPainter(img)
        painter.setRenderHint(QtGui.QPainter.RenderHint.Antialiasing, False)

        w = img.width()
        h = img.height()
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

        painter.setPen(QtGui.QPen(QtGui.QColor(255, 200, 0), 3))
        painter.drawRect(bx, by, bw, bh)

        rows, cols = core.parse_grid(seg.grid)
        rows = max(1, rows)
        cols = max(1, cols)

        painter.setPen(QtGui.QPen(QtGui.QColor(0, 255, 255), 2))
        for c in range(1, cols):
            x = bx + int(round(c * bw / cols))
            painter.drawLine(x, by, x, by + bh)
        for r in range(1, rows):
            y = by + int(round(r * bh / rows))
            painter.drawLine(bx, y, bx + bw, y)

        total = rows * cols
        active_map = {v: i + 1 for i, v in enumerate(seg.active)}
        font = QtGui.QFont("Menlo", 10)
        painter.setFont(font)
        for idx in range(1, total + 1):
            rr = (idx - 1) // cols
            cc = (idx - 1) % cols
            x0 = bx + int(round(cc * bw / cols))
            y0 = by + int(round(rr * bh / rows))

            label = f"{idx}"
            color = QtGui.QColor(255, 80, 80)
            if idx in active_map:
                label = f"{idx}#{active_map[idx]}"
                color = QtGui.QColor(50, 220, 50)

            painter.fillRect(x0 + 4, y0 + 4, 88, 24, QtGui.QColor(0, 0, 0))
            painter.setPen(QtGui.QPen(color))
            painter.drawText(x0 + 8, y0 + 21, label)

        painter.end()
        return img

    def _segment_frame(self, idx: int) -> QtGui.QImage:
        seg = self.segments[idx]
        frame_path = self._ensure_preview_frame_local(seg, idx)
        if not os.path.isfile(frame_path) or os.path.getsize(frame_path) == 0:
            return self._blank_qimage()
        img = QtGui.QImage(frame_path)
        if img.isNull():
            return self._blank_qimage()
        return img

    def _render_segment_view(self, idx: int) -> Tuple[QtGui.QImage, Tuple[int, int, int, int], Tuple[int, int]]:
        seg = self.segments[idx]
        base = self._segment_frame(idx)
        cur = self._draw_overlay_qt(base.copy(), seg)

        if not self.side_by_side.isChecked():
            return cur, (0, 0, cur.width(), cur.height()), (cur.width(), cur.height())

        auto_seg = self.auto_segments_map.get(core.segment_key(seg))
        auto = self._draw_overlay_qt(base.copy(), auto_seg if auto_seg is not None else seg)

        header_h = 28
        gap = 8
        panel_w = max(auto.width(), cur.width())
        panel_h = max(auto.height(), cur.height())
        canvas = QtGui.QImage(panel_w * 2 + gap, panel_h + header_h, QtGui.QImage.Format.Format_RGB32)
        canvas.fill(QtGui.QColor(24, 24, 24))
        painter = QtGui.QPainter(canvas)
        painter.setFont(QtGui.QFont("Menlo", 11))
        painter.setPen(QtGui.QPen(QtGui.QColor(180, 220, 255)))
        painter.drawText(10, 18, "AUTO")
        painter.setPen(QtGui.QPen(QtGui.QColor(120, 255, 120)))
        painter.drawText(panel_w + gap + 10, 18, "CURRENT (editable)")
        painter.drawImage(0, header_h, auto)
        painter.drawImage(panel_w + gap, header_h, cur)
        painter.end()
        return canvas, (panel_w + gap, header_h, cur.width(), cur.height()), (cur.width(), cur.height())

    def _render_current_to_preview(self) -> None:
        if self.render_image is None:
            return

        canvas_w = max(64, self.preview.width() - 4)
        canvas_h = max(64, self.preview.height() - 4)

        img = self.render_image
        ratio = min(canvas_w / img.width(), canvas_h / img.height(), 1.0)
        disp_w = max(1, int(img.width() * ratio))
        disp_h = max(1, int(img.height() * ratio))

        resized = img.scaled(disp_w, disp_h, QtCore.Qt.AspectRatioMode.KeepAspectRatio, QtCore.Qt.TransformationMode.SmoothTransformation)
        pix = QtGui.QPixmap.fromImage(resized)
        self.preview.setPixmap(pix)

        ex, ey, ew, eh = self.edit_rect_src
        scale_x = float(disp_w) / float(img.width())
        scale_y = float(disp_h) / float(img.height())
        drx = int(round(ex * scale_x))
        dry = int(round(ey * scale_y))
        drw = max(1, int(round(ew * scale_x)))
        drh = max(1, int(round(eh * scale_y)))
        self.edit_display_rect = (drx, dry, drw, drh)

    def _load_segment(self, idx: int) -> None:
        if not self.segments:
            return
        idx = max(0, min(len(self.segments) - 1, idx))
        self.current_index = idx
        seg = self.segments[idx]
        self._syncing_ui = True
        try:
            if idx in self.visible_indices:
                vis = self.visible_indices.index(idx)
                self.seg_list.blockSignals(True)
                self.seg_list.setCurrentRow(vis)
                self.seg_list.blockSignals(False)

            self.grid_edit.blockSignals(True)
            self.grid_edit.setCurrentText(seg.grid)
            self.grid_edit.blockSignals(False)
            self.bbox_edit.setText(seg.bbox or "")

            self.active_list.clear()
            for v in seg.active:
                self.active_list.addItem(str(v))

            conf = "n/a" if seg.confidence is None else f"{seg.confidence:.3f}"
            self.info_label.setText(f"Segment {idx+1}/{len(self.segments)}  |  {seg.start} -> {seg.end}  |  confidence={conf}")

            img, edit_rect_src, edit_src_size = self._render_segment_view(idx)
            self.render_image = img
            self.edit_rect_src = edit_rect_src
            self.edit_source_size = edit_src_size
            self._render_current_to_preview()
        finally:
            self.grid_edit.blockSignals(False)
            self.seg_list.blockSignals(False)
            self._syncing_ui = False

    def _on_seg_list_row_changed(self, row: int) -> None:
        if self._syncing_ui:
            return
        if row < 0 or row >= len(self.visible_indices):
            return
        self.commit_current_segment(silent=True)
        self._load_segment(self.visible_indices[row])

    def _active_values(self) -> List[int]:
        out: List[int] = []
        for i in range(self.active_list.count()):
            txt = self.active_list.item(i).text().strip()
            if txt.isdigit():
                out.append(int(txt))
        return out

    def _set_active_values(self, values: List[int]) -> None:
        self.active_list.clear()
        for v in values:
            self.active_list.addItem(str(v))

    def _on_grid_changed(self, text: str) -> None:
        if self._syncing_ui:
            return
        grid = text.strip()
        if not grid:
            return
        if grid == "1x2" and not self.bbox_edit.text().strip():
            self.bbox_edit.setText(DEFAULT_1X2_BBOX)
        active = core.normalize_active(self._active_values(), grid)
        self._set_active_values(active)

    def _active_up(self) -> None:
        row = self.active_list.currentRow()
        if row <= 0:
            return
        item = self.active_list.takeItem(row)
        self.active_list.insertItem(row - 1, item)
        self.active_list.setCurrentRow(row - 1)

    def _active_down(self) -> None:
        row = self.active_list.currentRow()
        if row < 0 or row >= self.active_list.count() - 1:
            return
        item = self.active_list.takeItem(row)
        self.active_list.insertItem(row + 1, item)
        self.active_list.setCurrentRow(row + 1)

    def _active_remove(self) -> None:
        row = self.active_list.currentRow()
        if row >= 0:
            self.active_list.takeItem(row)

    def _keep_only_selected_active(self) -> None:
        rows = sorted(set(i.row() for i in self.active_list.selectedIndexes()))
        if not rows:
            QtWidgets.QMessageBox.information(self, "Nothing selected", "Select one or more webcam cells first.")
            return
        values: List[int] = []
        for r in rows:
            txt = self.active_list.item(r).text().strip()
            if txt.isdigit():
                values.append(int(txt))
        values = core.normalize_active(values, self.grid_edit.currentText().strip() or "1x1")
        self._set_active_values(values)
        self.commit_current_segment(silent=True)
        self._load_segment(self.current_index)

    def _active_reset(self) -> None:
        total = core.grid_cells_count(self.grid_edit.currentText().strip())
        self._set_active_values(list(range(1, total + 1)))

    def commit_current_segment(self, silent: bool = False) -> bool:
        if self._syncing_ui:
            return True
        if not self.segments:
            return False
        seg = self.segments[self.current_index]
        grid = self.grid_edit.currentText().strip()
        if not grid or "x" not in grid:
            if not silent:
                QtWidgets.QMessageBox.critical(self, "Invalid grid", "Grid must be RxC, e.g. 2x2")
            return False

        active = core.normalize_active(self._active_values(), grid)
        bbox = self.bbox_edit.text().strip()
        if grid == "1x2" and not bbox:
            bbox = DEFAULT_1X2_BBOX
            self.bbox_edit.setText(bbox)
        if bbox:
            parts = bbox.split(":")
            if len(parts) != 4:
                if not silent:
                    QtWidgets.QMessageBox.critical(self, "Invalid bbox", "BBox must be x:y:w:h")
                return False

        seg.grid = grid
        seg.active = active
        seg.bbox = bbox or None

        self._syncing_ui = True
        try:
            self._refresh_changed_flags()
            self.apply_segment_filter(reload_segment=False)
            if self.current_index in self.visible_indices:
                self.seg_list.blockSignals(True)
                self.seg_list.setCurrentRow(self.visible_indices.index(self.current_index))
                self.seg_list.blockSignals(False)
        finally:
            self.seg_list.blockSignals(False)
            self._syncing_ui = False
        return True

    def prev_segment(self) -> None:
        if not self.commit_current_segment():
            return
        if self.current_index not in self.visible_indices:
            if self.visible_indices:
                self._load_segment(self.visible_indices[0])
            return
        vis = self.visible_indices.index(self.current_index)
        self._load_segment(self.visible_indices[max(0, vis - 1)])

    def next_segment(self) -> None:
        if not self.commit_current_segment():
            return
        if self.current_index not in self.visible_indices:
            if self.visible_indices:
                self._load_segment(self.visible_indices[0])
            return
        vis = self.visible_indices.index(self.current_index)
        self._load_segment(self.visible_indices[min(len(self.visible_indices) - 1, vis + 1)])

    def save_manual_plan(self, show_message: bool = True) -> None:
        if not self.segments:
            if show_message:
                QtWidgets.QMessageBox.warning(self, "No segments", "Nothing to save")
            return
        if not self.commit_current_segment(silent=True):
            return

        lines = ["# edited in bbb_webcams_plan_gui_qt.py", "# start end grid active [bbox]"]
        for seg in self.segments:
            active = ",".join(str(v) for v in seg.active)
            row = f"{seg.start} {seg.end} {seg.grid} {active}"
            if seg.bbox:
                row += f" {seg.bbox}"
            lines.append(row)

        self.manual_plan.write_text("\n".join(lines) + "\n", encoding="utf-8")
        self.refresh_status()
        if show_message:
            QtWidgets.QMessageBox.information(self, "Saved", f"Manual plan saved:\n{self.manual_plan}")

    def _preview_point_to_source(self, px: int, py: int) -> Optional[Tuple[float, float]]:
        pix = self.preview.pixmap()
        if pix is None:
            return None

        lbl_w = self.preview.width()
        lbl_h = self.preview.height()
        pix_w = pix.width()
        pix_h = pix.height()
        off_x = max(0, (lbl_w - pix_w) // 2)
        off_y = max(0, (lbl_h - pix_h) // 2)

        lx = px - off_x
        ly = py - off_y
        if lx < 0 or ly < 0 or lx >= pix_w or ly >= pix_h:
            return None

        rx, ry, rw, rh = self.edit_display_rect
        if rw <= 0 or rh <= 0:
            return None

        ex = lx - rx
        ey = ly - ry
        if ex < 0 or ey < 0 or ex >= rw or ey >= rh:
            return None

        src_w, src_h = self.edit_source_size
        if src_w <= 0 or src_h <= 0:
            return None

        sx = float(ex) * float(src_w) / float(rw)
        sy = float(ey) * float(src_h) / float(rh)
        return (sx, sy)

    def _on_preview_click(self, px: int, py: int) -> None:
        if not self.segments:
            return
        pt = self._preview_point_to_source(px, py)
        if pt is None:
            return
        seg = self.segments[self.current_index]
        idx = None
        for cell, x0, y0, x1, y1 in core.segment_cell_rects(seg, self.edit_source_size[0], self.edit_source_size[1]):
            if x0 <= pt[0] < x1 and y0 <= pt[1] < y1:
                idx = cell
                break
        if idx is None:
            return

        active = self._active_values()
        if idx in active:
            active = [v for v in active if v != idx]
            if not active:
                active = [idx]
        else:
            active.append(idx)
        active = core.normalize_active(active, self.grid_edit.currentText().strip() or "1x1")
        self._set_active_values(active)
        self.commit_current_segment(silent=True)
        self._load_segment(self.current_index)

    def refresh_current_preview(self) -> None:
        if self.segments:
            self._load_segment(self.current_index)

    def auto_crop_top_bottom_for_1x2(self) -> None:
        if not self.segments:
            return
        grid = self.grid_edit.currentText().strip()
        if grid != "1x2":
            QtWidgets.QMessageBox.information(self, "Grid not 1x2", "This helper is intended for 1x2 segments.")
            return

        seg = self.segments[self.current_index]
        base = self._segment_frame(self.current_index)
        top, bottom_ex = self._detect_vertical_content_bounds_qt(base)

        # If default detection is weak (near full frame), try stricter settings.
        if (bottom_ex - top) >= (base.height() - 12):
            t2, b2 = self._detect_vertical_content_bounds_qt(
                base,
                dark_threshold=28,
                min_active_ratio=0.08,
                mean_floor=24.0,
            )
            if (b2 - t2) < (bottom_ex - top):
                top, bottom_ex = t2, b2

        # Final fallback: if still full-frame-ish, reuse AUTO bbox for this segment.
        if (bottom_ex - top) >= (base.height() - 12):
            auto_seg = self.auto_segments_map.get(core.segment_key(seg))
            if auto_seg is not None and auto_seg.bbox:
                parsed = self._parse_bbox(auto_seg.bbox)
                if parsed is not None:
                    _x, ay, aw, ah = parsed
                    if aw > 0 and ah > 0 and ah < (base.height() - 8):
                        top = max(0, ay)
                        bottom_ex = min(base.height(), ay + ah)

        crop_h = max(1, bottom_ex - top)
        self.bbox_edit.setText(f"0:{top}:{base.width()}:{crop_h}")
        self.commit_current_segment(silent=True)
        self._load_segment(self.current_index)


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description="BBB Qt webcams plan editor")
    p.add_argument("recording_dir", help="Recording folder, e.g. 2026-08-04")
    p.add_argument("num", help="Presentation number, e.g. 01")
    return p


def main() -> int:
    args = build_parser().parse_args()
    rec_dir = Path(args.recording_dir)
    if not rec_dir.is_dir():
        print(f"Recording directory not found: {rec_dir}", file=sys.stderr)
        return 2

    app = QtWidgets.QApplication(sys.argv)
    win = PlanEditorQt(rec_dir, str(args.num))
    win.show()
    return app.exec()


if __name__ == "__main__":
    raise SystemExit(main())
