"""SystemSnapshot - клікабельне меню (Tkinter) для Setup.ps1 / Take-SystemSnapshot.ps1."""
import json
import os
import queue
import shutil
import string
import subprocess
import sys
import threading
import tkinter as tk
from tkinter import filedialog, messagebox, scrolledtext, ttk

APP_DIR = os.path.dirname(os.path.abspath(__file__))
SETUP_PS1 = os.path.join(APP_DIR, "Setup.ps1")
SNAPSHOT_PS1 = os.path.join(APP_DIR, "Take-SystemSnapshot.ps1")
RESTORE_PS1 = os.path.join(APP_DIR, "Restore-SystemSnapshot.ps1")
README = os.path.join(APP_DIR, "README.md")

CREATE_NO_WINDOW = 0x08000000

# Категорії знімка - id має збігатися з Id у функції Step всередині Take-SystemSnapshot.ps1.
# Свідомо лише те, що реально треба, аби не шукати все заново після переустановки:
# програми, репозиторії, розширення програм, візуальне оформлення. Без заліза,
# компонентів реєстру, автозапуску тощо.
SNAPSHOT_STEP_GROUPS = [
    ("Категорії знімка", [
        ("programs", "Встановлені програми (winget + повний список)", True),
        ("vscode_ext", "Розширення VS Code", True),
        ("settings", "Налаштування (git, SSH, PowerShell, Windows Terminal, VS Code)", True),
        ("repos", "Git-репозиторії (спитає, на яких дисках шукати)", True),
        ("visual", "Візуальне оформлення (шпалина, тема, панель задач, провідник)", True),
    ]),
]

# Кроки встановлення залежностей - id має збігатися з id у Invoke-DependencySetup.
SETUP_STEPS = [
    ("unblock", "Розблокувати файли репозиторію (Unblock-File)", True),
    ("execpolicy", "Виправити ExecutionPolicy (CurrentUser -> RemoteSigned)", True),
    ("winget", "Перевірити / відновити winget", True),
    ("pwsh", "Встановити PowerShell 7 (якщо відсутній)", True),
]


def find_powershell() -> str:
    for exe in ("pwsh", "powershell"):
        path = shutil.which(exe)
        if path:
            return exe
    return "powershell"


def desktop_dir() -> str:
    return os.path.join(os.path.expanduser("~"), "Desktop")


def desktop_shortcut_path() -> str:
    return os.path.join(desktop_dir(), "SystemSnapshot.lnk")


def create_desktop_shortcut(exe: str) -> str:
    """Створює/перезаписує ярлик SystemSnapshot.lnk на робочому столі (через WScript.Shell)."""
    lnk = desktop_shortcut_path()
    target = os.path.join(APP_DIR, "Menu.cmd")

    def q(s: str) -> str:
        return "'" + s.replace("'", "''") + "'"

    script = (
        "$ws = New-Object -ComObject WScript.Shell; "
        f"$sc = $ws.CreateShortcut({q(lnk)}); "
        f"$sc.TargetPath = {q(target)}; "
        f"$sc.WorkingDirectory = {q(APP_DIR)}; "
        "$sc.IconLocation = 'shell32.dll,167'; "
        "$sc.Description = 'SystemSnapshot - знімок налаштувань Windows'; "
        "$sc.Save()"
    )
    subprocess.run(
        [exe, "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", script],
        stdin=subprocess.DEVNULL, capture_output=True, text=True, encoding="utf-8", errors="replace",
        cwd=APP_DIR, creationflags=CREATE_NO_WINDOW, timeout=15, check=True,
    )
    return lnk


def list_drives():
    drives = []
    for letter in string.ascii_uppercase:
        if os.path.exists(f"{letter}:\\"):
            drives.append(f"{letter}:")
    return drives


def find_last_snapshot():
    candidates = find_all_snapshots()
    return max(candidates, key=os.path.getmtime) if candidates else None


def find_all_snapshots():
    candidates = []
    for base in (desktop_dir(), APP_DIR):
        if os.path.isdir(base):
            for name in os.listdir(base):
                full = os.path.join(base, name)
                if os.path.isdir(full) and name.startswith("SystemSnapshot_"):
                    candidates.append(full)
    return sorted(candidates, key=os.path.getmtime, reverse=True)


def snapshot_display_name(path: str) -> str:
    """'SystemSnapshot_2026-09-13_093442' -> '13.09.2026 09:34:42'."""
    base = os.path.basename(path.rstrip("\\/"))
    prefix = "SystemSnapshot_"
    if base.startswith(prefix):
        rest = base[len(prefix):]
        try:
            date_part, time_part = rest.split("_")
            y, m, d = date_part.split("-")
            hh, mm, ss = time_part[0:2], time_part[2:4], time_part[4:6]
            return f"{d}.{m}.{y} {hh}:{mm}:{ss}"
        except ValueError:
            pass
    return base


def inspect_snapshot(exe, snapshot_dir):
    """Питає Restore-SystemSnapshot.ps1 -List, що саме є в цьому знімку. Повертає (dict, помилка-або-None)."""
    try:
        result = subprocess.run(
            [exe, "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", RESTORE_PS1,
             "-SnapshotDir", snapshot_dir, "-List"],
            stdin=subprocess.DEVNULL, capture_output=True, text=True, encoding="utf-8", errors="replace",
            cwd=APP_DIR, creationflags=CREATE_NO_WINDOW, timeout=30,
        )
        return json.loads(result.stdout.strip()), None
    except Exception as e:
        return None, str(e)


# Категорії - id пунктів мають збігатися з тим, що розуміє Restore-SystemSnapshot.ps1 (-Steps).
def build_restore_groups(catalog: dict):
    groups = []
    if catalog.get("winget"):
        groups.append(("Програми (winget import)", [
            (f"winget:{p['id']}", p["label"], True) for p in catalog["winget"]
        ]))
    if catalog.get("vscode_ext"):
        groups.append(("Розширення VS Code", [
            (f"vscode:{e['id']}", e["label"], True) for e in catalog["vscode_ext"]
        ]))
    if catalog.get("config_files"):
        groups.append(("Налаштування", [
            (c["id"], c["label"], False) for c in catalog["config_files"]
        ]))
    if catalog.get("repos"):
        groups.append(("Git-репозиторії", [
            (f"repo:{r['id']}", r["label"], False) for r in catalog["repos"]
        ]))
    if catalog.get("visual"):
        groups.append(("Візуальне оформлення", [
            ("visual", "Шпалина, тема, панель задач, провідник (перезапустить провідник)", False),
        ]))
    return groups


class ScrollableFrame(ttk.Frame):
    """Frame з вертикальною прокруткою для довгого списку чекбоксів."""

    def __init__(self, master, height=260, **kwargs):
        super().__init__(master, **kwargs)
        canvas = tk.Canvas(self, height=height, highlightthickness=0)
        vbar = ttk.Scrollbar(self, orient="vertical", command=canvas.yview)
        self.inner = ttk.Frame(canvas)

        self.inner.bind("<Configure>", lambda e: canvas.configure(scrollregion=canvas.bbox("all")))
        canvas.create_window((0, 0), window=self.inner, anchor="nw")
        canvas.configure(yscrollcommand=vbar.set)

        canvas.pack(side="left", fill="both", expand=True)
        vbar.pack(side="right", fill="y")

        def on_wheel(event):
            canvas.yview_scroll(int(-1 * (event.delta / 120)), "units")

        canvas.bind("<Enter>", lambda e: canvas.bind_all("<MouseWheel>", on_wheel))
        canvas.bind("<Leave>", lambda e: canvas.unbind_all("<MouseWheel>"))


class StepChecklist(ttk.Frame):
    """Групований список чекбоксів + Обрати все / Зняти все + лічильник вибраного."""

    def __init__(self, master, groups, **kwargs):
        super().__init__(master, **kwargs)
        self.vars: dict[str, tk.BooleanVar] = {}
        self.total_count = sum(len(items) for _, items in groups)
        self._group_ids: dict[int, list[str]] = {}
        self._group_master_vars: dict[int, tk.BooleanVar] = {}
        self._suspend_group_sync = False

        top = ttk.Frame(self)
        top.pack(fill="x", pady=(0, 4))
        ttk.Button(top, text="Обрати все", command=lambda: self._set_all(True)).pack(side="left")
        ttk.Button(top, text="Зняти все", command=lambda: self._set_all(False)).pack(side="left", padx=(6, 0))
        self.count_label = ttk.Label(top, text="")
        self.count_label.pack(side="right")

        scroll = ScrollableFrame(self)
        scroll.pack(fill="both", expand=True)

        for gi, (group_title, items) in enumerate(groups):
            heading = f"{group_title}  ({len(items)})" if group_title else f"Пункти ({len(items)})"
            ids = [step_id for step_id, _, _ in items]
            self._group_ids[gi] = ids

            if len(items) > 1:
                # Чекбокс-заголовок категорії - "обрати всі з цієї категорії" одним кліком,
                # замість ручного клацання по кожному з десятків пунктів.
                master_var = tk.BooleanVar(value=all(default for _, _, default in items))
                self._group_master_vars[gi] = master_var
                header = ttk.Checkbutton(
                    scroll.inner, text=heading, variable=master_var,
                    command=lambda gi=gi: self._toggle_group(gi),
                )
                box = ttk.LabelFrame(scroll.inner, labelwidget=header)
            else:
                box = ttk.LabelFrame(scroll.inner, text=heading)
            box.pack(fill="x", expand=True, padx=2, pady=4, anchor="w")

            for step_id, label, default in items:
                var = tk.BooleanVar(value=default)
                var.trace_add("write", lambda *_, gi=gi: self._on_item_change(gi))
                self.vars[step_id] = var
                ttk.Checkbutton(box, text=label, variable=var).pack(anchor="w", padx=6, pady=1)

        self._update_count()

    def _on_item_change(self, gi: int):
        self._update_count()
        if self._suspend_group_sync:
            return
        master_var = self._group_master_vars.get(gi)
        if master_var is None:
            return
        all_checked = all(self.vars[sid].get() for sid in self._group_ids[gi])
        master_var.set(all_checked)

    def _toggle_group(self, gi: int):
        value = self._group_master_vars[gi].get()
        self._suspend_group_sync = True
        for sid in self._group_ids[gi]:
            self.vars[sid].set(value)
        self._suspend_group_sync = False
        self._update_count()

    def _update_count(self):
        self.count_label.configure(text=f"Обрано: {len(self.selected())} з {self.total_count}")

    def _set_all(self, value: bool):
        self._suspend_group_sync = True
        for var in self.vars.values():
            var.set(value)
        self._suspend_group_sync = False
        for master_var in self._group_master_vars.values():
            master_var.set(value)
        self._update_count()

    def selected(self):
        return [step_id for step_id, var in self.vars.items() if var.get()]


class LogWindow(tk.Toplevel):
    """Toplevel, що запускає PowerShell-скрипт і показує його вивід наживо."""

    def __init__(self, master, title, exe, args, total_steps=None):
        super().__init__(master)
        self.title(title)
        self.geometry("820x520")
        self.minsize(560, 360)
        self.proc = None
        self.out_queue: "queue.Queue" = queue.Queue()
        self.total_steps = total_steps
        self.done_steps = 0

        top = ttk.Frame(self)
        top.pack(fill="x", padx=8, pady=(8, 0))
        self.progress = ttk.Progressbar(top, mode="determinate", maximum=max(total_steps or 1, 1))
        self.progress.pack(fill="x", side="left", expand=True)
        self.progress_label = ttk.Label(top, text=f"0 / {total_steps}" if total_steps else "")
        self.progress_label.pack(side="left", padx=(8, 0))

        self.text = scrolledtext.ScrolledText(
            self, wrap="word", font=("Consolas", 10),
            background="#101418", foreground="#d7dde3",
            insertbackground="#d7dde3", state="disabled",
        )
        self.text.pack(fill="both", expand=True, padx=8, pady=(6, 4))
        self.text.tag_configure("ok", foreground="#63d47a")
        self.text.tag_configure("skip", foreground="#e0b34d")
        self.text.tag_configure("warn", foreground="#ff6b6b")
        self.text.tag_configure("unselected", foreground="#5c6672")

        bottom = ttk.Frame(self)
        bottom.pack(fill="x", padx=8, pady=(0, 8))
        self.status = ttk.Label(bottom, text="Виконується...")
        self.status.pack(side="left")
        self.close_btn = ttk.Button(bottom, text="Закрити", command=self.destroy, state="disabled")
        self.close_btn.pack(side="right")

        self.protocol("WM_DELETE_WINDOW", self._on_close_request)
        self._start(exe, args)
        self.after(80, self._poll)

    def _start(self, exe, args):
        def worker():
            try:
                self.proc = subprocess.Popen(
                    [exe, "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", *args],
                    stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                    text=True, encoding="utf-8", errors="replace", bufsize=1,
                    cwd=APP_DIR, creationflags=CREATE_NO_WINDOW,
                )
                for line in self.proc.stdout:
                    self.out_queue.put(line.rstrip("\n"))
                self.proc.wait()
                self.out_queue.put(("__DONE__", self.proc.returncode))
            except Exception as e:
                self.out_queue.put(f"Помилка запуску: {e}")
                self.out_queue.put(("__DONE__", -1))

        threading.Thread(target=worker, daemon=True).start()

    def _poll(self):
        try:
            while True:
                item = self.out_queue.get_nowait()
                if isinstance(item, tuple):
                    self._finish(item[1])
                else:
                    self._append(item)
        except queue.Empty:
            pass
        if self.proc is None or self.proc.poll() is None:
            self.after(80, self._poll)

    def _append(self, line: str):
        stripped = line.rstrip()
        is_step_end = False
        if stripped.endswith("не вибрано"):
            tag = "unselected"
            is_step_end = True
        elif stripped.endswith("OK"):
            tag = "ok"
            is_step_end = True
        elif "пропущено" in line or "SKIP" in line:
            tag = "skip"
            is_step_end = True
        elif "УВАГА" in line or "!!!" in line or "омилка" in line.lower():
            tag = "warn"
        else:
            tag = None
        self.text.configure(state="normal")
        self.text.insert("end", line + "\n", tag or ())
        self.text.see("end")
        self.text.configure(state="disabled")

        if is_step_end and self.total_steps:
            self.done_steps = min(self.done_steps + 1, self.total_steps)
            self.progress.configure(value=self.done_steps)
            self.progress_label.configure(text=f"{self.done_steps} / {self.total_steps}")

    def _finish(self, returncode):
        ok = returncode == 0
        self.status.configure(text="Готово" if ok else "Завершено з помилкою")
        if self.total_steps:
            self.progress.configure(value=self.total_steps)
            self.progress_label.configure(text=f"{self.total_steps} / {self.total_steps}")
        self.close_btn.configure(state="normal")
        if not ok:
            messagebox.showerror(
                "Помилка виконання",
                "Скрипт завершився з помилкою і не доробив усе заплановане.\n"
                "Що саме пішло не так - в кінці тексту у вікні логу (виділено червоним).",
            )

    def _on_close_request(self):
        if self.proc and self.proc.poll() is None:
            if not messagebox.askyesno("Процес ще виконується", "Перервати виконання і закрити вікно?"):
                return
            try:
                self.proc.terminate()
            except Exception:
                pass
        self.destroy()


class DriveDialog(tk.Toplevel):
    """Питає, на яких дисках шукати git-репозиторії. self.result = список дисків або None (скасовано)."""

    def __init__(self, master):
        super().__init__(master)
        self.title("Диски для пошуку репозиторіїв")
        self.geometry("320x280")
        self.transient(master)
        self.grab_set()
        self.result = None

        frm = ttk.Frame(self, padding=12)
        frm.pack(fill="both", expand=True)
        ttk.Label(frm, text="На яких дисках шукати git-репозиторії?",
                  wraplength=280, justify="left").pack(anchor="w", pady=(0, 8))

        self.vars: dict[str, tk.BooleanVar] = {}
        drives = list_drives()
        for d in drives:
            var = tk.BooleanVar(value=False)
            self.vars[d] = var
            ttk.Checkbutton(frm, text=d, variable=var).pack(anchor="w")
        if not drives:
            ttk.Label(frm, text="Дисків не знайдено.").pack(anchor="w")

        btns = ttk.Frame(frm)
        btns.pack(fill="x", pady=(12, 0), side="bottom")
        ttk.Button(btns, text="Скасувати", command=self._cancel).pack(side="right", padx=(6, 0))
        ttk.Button(btns, text="Гаразд", command=self._ok).pack(side="right")
        self.protocol("WM_DELETE_WINDOW", self._cancel)

    def _ok(self):
        chosen = [d for d, v in self.vars.items() if v.get()]
        if not chosen:
            messagebox.showwarning(
                "Диск не обрано",
                "Познач хоча б один диск, або натисни «Скасувати», щоб пропустити пошук репозиторіїв.",
            )
            return
        self.result = chosen
        self.destroy()

    def _cancel(self):
        self.result = None
        self.destroy()


class SnapshotDialog(tk.Toplevel):
    def __init__(self, master, on_start):
        super().__init__(master)
        self.title("Зробити знімок системи")
        self.geometry("560x560")
        self.minsize(480, 420)
        self.transient(master)
        self.grab_set()
        self.on_start = on_start

        frm = ttk.Frame(self, padding=12)
        frm.pack(fill="both", expand=True)

        ttk.Label(frm, text="Куди зберегти знімок:").pack(anchor="w")
        path_row = ttk.Frame(frm)
        path_row.pack(fill="x", pady=(2, 8))
        self.out_var = tk.StringVar(value=desktop_dir())
        ttk.Entry(path_row, textvariable=self.out_var).pack(side="left", fill="x", expand=True)
        ttk.Button(path_row, text="Огляд...", command=self._browse).pack(side="left", padx=(6, 0))

        ttk.Label(frm, text="Що саме зібрати:").pack(anchor="w")
        self.checklist = StepChecklist(frm, SNAPSHOT_STEP_GROUPS)
        self.checklist.pack(fill="both", expand=True, pady=(2, 8))

        btns = ttk.Frame(frm)
        btns.pack(fill="x", pady=(10, 0))
        ttk.Button(btns, text="Скасувати", command=self.destroy).pack(side="right", padx=(6, 0))
        ttk.Button(btns, text="Почати", command=self._start).pack(side="right")

    def _browse(self):
        d = filedialog.askdirectory(initialdir=self.out_var.get() or desktop_dir())
        if d:
            self.out_var.set(d)

    def _start(self):
        steps = self.checklist.selected()
        if not steps:
            messagebox.showwarning("Нічого не обрано", "Вибери хоча б один пункт для знімка.")
            return

        repo_drives = []
        if "repos" in steps:
            dlg = DriveDialog(self)
            self.wait_window(dlg)
            if dlg.result:
                repo_drives = dlg.result
            else:
                steps = [s for s in steps if s != "repos"]

        if not steps:
            # Диски не обрано (скасовано) і крім "repos" нічого іншого не позначено -
            # без цієї перевірки пішов би порожній -Steps, а порожній -Steps для
            # PowerShell-скрипта означає "нічого не фільтрувати" - тобто зібрало б УСЕ.
            messagebox.showwarning("Нічого не обрано", "Диски не обрано, інших пунктів немає - знімок скасовано.")
            return

        out = self.out_var.get().strip() or desktop_dir()
        args = [SNAPSHOT_PS1, "-OutputRoot", out, "-NoPrompt", "-Steps", "|".join(steps)]
        if repo_drives:
            args += ["-RepoDrives", "|".join(repo_drives)]
        self.destroy()
        self.on_start(args, len(steps))


class SetupDialog(tk.Toplevel):
    def __init__(self, master, on_start):
        super().__init__(master)
        self.title("Встановити залежності")
        self.geometry("460x360")
        self.minsize(400, 300)
        self.transient(master)
        self.grab_set()
        self.on_start = on_start

        frm = ttk.Frame(self, padding=12)
        frm.pack(fill="both", expand=True)

        ttk.Label(frm, text="Що саме встановити / перевірити:").pack(anchor="w")
        self.checklist = StepChecklist(frm, [("", SETUP_STEPS)])
        self.checklist.pack(fill="both", expand=True, pady=(4, 8))

        btns = ttk.Frame(frm)
        btns.pack(fill="x")
        ttk.Button(btns, text="Скасувати", command=self.destroy).pack(side="right", padx=(6, 0))
        ttk.Button(btns, text="Встановити", command=self._start).pack(side="right")

    def _start(self):
        steps = self.checklist.selected()
        if not steps:
            messagebox.showwarning("Нічого не обрано", "Вибери хоча б один пункт.")
            return
        self.destroy()
        self.on_start([SETUP_PS1, "-Steps", "|".join(steps)], len(steps))


class RestoreDialog(tk.Toplevel):
    """Вибір знімка + чекбокс-список того, що з нього можна автоматично встановити/відновити."""

    def __init__(self, master, exe, on_start):
        super().__init__(master)
        self.title("Встановити зі знімка")
        self.geometry("600x660")
        self.minsize(500, 440)
        self.transient(master)
        self.grab_set()
        self.exe = exe
        self.on_start = on_start
        self.checklist = None

        frm = ttk.Frame(self, padding=12)
        frm.pack(fill="both", expand=True)

        ttk.Label(frm, text="Який знімок відновлювати:").pack(anchor="w")
        path_row = ttk.Frame(frm)
        path_row.pack(fill="x", pady=(2, 4))
        snapshots = find_all_snapshots()
        self._display_to_path = {snapshot_display_name(p): p for p in snapshots}
        display_values = list(self._display_to_path.keys())
        self.dir_var = tk.StringVar(value=snapshots[0] if snapshots else "")
        self.display_var = tk.StringVar(value=display_values[0] if display_values else "")
        self.combo = ttk.Combobox(path_row, textvariable=self.display_var, values=display_values, state="readonly")
        self.combo.pack(side="left", fill="x", expand=True)
        self.combo.bind("<<ComboboxSelected>>", self._on_combo_select)
        ttk.Button(path_row, text="Огляд...", command=self._browse).pack(side="left", padx=(6, 0))

        self.path_label = ttk.Label(frm, text=self.dir_var.get(), style="Desc.TLabel")
        self.path_label.pack(anchor="w")

        self.info_label = ttk.Label(frm, text="", foreground="#b45309")
        self.info_label.pack(anchor="w", pady=(0, 4))

        ttk.Label(frm, text="Що встановити / відновити:").pack(anchor="w")
        ttk.Label(
            frm, text="Пакети/розширення лише ставляться. Налаштування і візуальне "
                      "оформлення можуть перезаписати поточне, але спершу бекапляться (*.bak-...). "
                      "Репозиторії клонуються тільки в нову папку - якщо вона вже існує, пункт просто пропускається.",
            style="Desc.TLabel", wraplength=560, justify="left",
        ).pack(anchor="w", pady=(0, 4))
        self.checklist_holder = ttk.Frame(frm)
        self.checklist_holder.pack(fill="both", expand=True, pady=(2, 8))

        btns = ttk.Frame(frm)
        btns.pack(fill="x")
        ttk.Button(btns, text="Скасувати", command=self.destroy).pack(side="right", padx=(6, 0))
        self.start_btn = ttk.Button(btns, text="Встановити", command=self._start)
        self.start_btn.pack(side="right")

        if snapshots:
            self._reload()
        else:
            self.info_label.configure(text="Знімків не знайдено (робочий стіл і ця папка). Натисни «Огляд...».")
            self.start_btn.configure(state="disabled")

    def _on_combo_select(self, _event=None):
        self.dir_var.set(self._display_to_path[self.display_var.get()])
        self.path_label.configure(text=self.dir_var.get())
        self._reload()

    def _browse(self):
        d = filedialog.askdirectory(initialdir=desktop_dir())
        if d:
            display = snapshot_display_name(d)
            if display in self._display_to_path and self._display_to_path[display] != d:
                display = d  # уникнути колізії назв - показати повний шлях
            self._display_to_path[display] = d
            values = list(self.combo["values"])
            if display not in values:
                values.insert(0, display)
                self.combo["values"] = values
            self.display_var.set(display)
            self.dir_var.set(d)
            self.path_label.configure(text=d)
            self._reload()

    def _reload(self):
        snap_dir = self.dir_var.get()
        if not snap_dir or not os.path.isdir(snap_dir):
            self.info_label.configure(text="Обрана папка не знайдена.")
            return
        self.info_label.configure(text="Читаю вміст знімка...")
        self.update_idletasks()

        catalog, err = inspect_snapshot(self.exe, snap_dir)
        if self.checklist is not None:
            self.checklist.destroy()
            self.checklist = None

        if err or not catalog:
            self.info_label.configure(text=f"Не вдалося прочитати знімок: {err or 'порожня відповідь'}")
            self.start_btn.configure(state="disabled")
            return

        groups = build_restore_groups(catalog)
        if not groups:
            self.info_label.configure(text="У цьому знімку немає нічого, що можна автоматично встановити.")
            self.start_btn.configure(state="disabled")
            return

        self.info_label.configure(text="")
        self.start_btn.configure(state="normal")
        self.checklist = StepChecklist(self.checklist_holder, groups)
        self.checklist.pack(fill="both", expand=True)

    def _start(self):
        if self.checklist is None:
            return
        steps = self.checklist.selected()
        if not steps:
            messagebox.showwarning("Нічого не обрано", "Вибери хоча б один пункт для встановлення.")
            return
        snap_dir = self.dir_var.get()
        self.destroy()
        self.on_start([RESTORE_PS1, "-SnapshotDir", snap_dir, "-Steps", "|".join(steps)], len(steps))


class App(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title("SystemSnapshot")
        self.geometry("480x560")
        self.minsize(420, 460)
        self.exe = find_powershell()

        style = ttk.Style(self)
        try:
            style.theme_use("vista")
        except tk.TclError:
            pass
        style.configure("Desc.TLabel", foreground="#6b7280", font=("Segoe UI", 9))
        style.configure("Section.TLabel", font=("Segoe UI", 10, "bold"))

        header = ttk.Frame(self, padding=(16, 16, 16, 4))
        header.pack(fill="x")
        ttk.Label(header, text="SystemSnapshot", font=("Segoe UI", 16, "bold")).pack(anchor="w")
        ttk.Label(header, text="Знімок налаштувань Windows перед переустановкою.",
                  style="Desc.TLabel").pack(anchor="w")

        body = ttk.Frame(self, padding=(16, 4))
        body.pack(fill="both", expand=True)

        ttk.Label(body, text="Знімок", style="Section.TLabel").pack(anchor="w", pady=(4, 2))
        self._add_action(body, "Зробити знімок системи",
                          "Програми, репозиторії, розширення, налаштування і візуальне оформлення в одну папку.",
                          self.open_snapshot_dialog)
        self._add_action(body, "Встановити зі знімка",
                          "Поставити пакети й відновити налаштування з раніше зробленого знімка.",
                          self.open_restore_dialog)

        ttk.Separator(body).pack(fill="x", pady=8)

        ttk.Label(body, text="Обслуговування", style="Section.TLabel").pack(anchor="w", pady=(0, 2))
        self._add_action(body, "Встановити залежності",
                          "winget, PowerShell 7, ExecutionPolicy - одноразово на новій системі.",
                          self.open_setup_dialog)
        self._add_action(body, "Відкрити останній знімок",
                          "Показати папку з найновішим зробленим знімком.",
                          self.open_last_snapshot)
        self._add_action(body, "Відкрити папку SystemSnapshot",
                          "Папка з цими скриптами та всіма знімками.",
                          self.open_folder)
        self._add_action(body, "Показати README",
                          "Коротка інструкція та опис файлів.",
                          self.show_readme)
        self._add_action(body, "Створити ярлик на робочому столі",
                          "Ярлик запуску SystemSnapshot (Menu.cmd).",
                          self.create_shortcut_action)

        ttk.Separator(self).pack(fill="x", padx=16, pady=(4, 8))
        ttk.Button(self, text="Вихід", command=self.destroy).pack(pady=(0, 16))

        self.after(300, self.check_dependencies)
        self.after(300, self.ensure_desktop_shortcut)

    def _add_action(self, parent, title, desc, cmd):
        card = ttk.Frame(parent)
        card.pack(fill="x", pady=4)
        ttk.Button(card, text=title, command=cmd).pack(fill="x")
        ttk.Label(card, text=desc, style="Desc.TLabel", wraplength=420, justify="left").pack(
            anchor="w", padx=2, pady=(2, 0))

    def check_dependencies(self):
        """Тиха перевірка при відкритті меню - питає лише якщо чогось справді бракує."""
        if shutil.which("winget"):
            return
        if not messagebox.askyesno(
            "Немає winget",
            "Для категорії 'Програми' (знімок і встановлення) потрібен winget, а його "
            "не знайдено.\n\nПолагодити/встановити зараз? Решта категорій (розширення, "
            "налаштування, репозиторії, візуальне оформлення) працюють і без нього.",
        ):
            return
        LogWindow(self, "Встановлення залежностей", self.exe,
                  [SETUP_PS1, "-Steps", "unblock|execpolicy|winget"], 3)

    def ensure_desktop_shortcut(self):
        """Перший запуск (щойно з репозиторію) - тихо створює ярлик, якщо його ще немає."""
        if os.path.exists(desktop_shortcut_path()):
            return
        try:
            create_desktop_shortcut(self.exe)
        except Exception:
            pass  # тиха перевірка - не заважати спливаючими помилками при старті

    def create_shortcut_action(self):
        try:
            lnk = create_desktop_shortcut(self.exe)
        except Exception as e:
            messagebox.showerror("Помилка", f"Не вдалося створити ярлик: {e}")
            return
        messagebox.showinfo("Ярлик створено", f"Ярлик додано на робочий стіл:\n{lnk}")

    def open_snapshot_dialog(self):
        SnapshotDialog(self, lambda args, n: LogWindow(self, "Знімок системи", self.exe, args, n))

    def open_setup_dialog(self):
        SetupDialog(self, lambda args, n: LogWindow(self, "Встановлення залежностей", self.exe, args, n))

    def open_restore_dialog(self):
        RestoreDialog(self, self.exe, lambda args, n: LogWindow(self, "Встановлення зі знімка", self.exe, args, n))

    def open_last_snapshot(self):
        last = find_last_snapshot()
        if last:
            os.startfile(last)
        else:
            messagebox.showinfo("Останній знімок", "Знімків ще не знайдено (робочий стіл і ця папка).")

    def open_folder(self):
        os.startfile(APP_DIR)

    def show_readme(self):
        win = tk.Toplevel(self)
        win.title("README")
        win.geometry("700x560")
        txt = scrolledtext.ScrolledText(win, wrap="word", font=("Consolas", 10))
        txt.pack(fill="both", expand=True, padx=8, pady=8)
        try:
            with open(README, "r", encoding="utf-8") as f:
                txt.insert("1.0", f.read())
        except OSError as e:
            txt.insert("1.0", f"Не вдалося відкрити README.md: {e}")
        txt.configure(state="disabled")


def main():
    App().mainloop()


if __name__ == "__main__":
    main()
