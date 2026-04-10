"""
Utility functions for the Dusky Control Center.

Thread-safe utility library for GTK4 control center on Arch Linux (Hyprland).
Persisted settings use atomic replace semantics. Public helpers are thread-safe,
except `preflight_check()`, which is intended for startup use on the main thread.
"""
from __future__ import annotations

import logging
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import threading
from collections.abc import Callable
from pathlib import Path, PurePosixPath
from typing import TYPE_CHECKING, Final, TypeVar, overload

import yaml

if TYPE_CHECKING:
    from gi.repository import Adw

__all__ = [
    "CACHE_DIR",
    "LABEL_NA",
    "SETTINGS_DIR",
    "execute_command",
    "get_cache_dir",
    "get_system_value",
    "load_config",
    "load_setting",
    "preflight_check",
    "save_setting",
    "toast",
]

log: logging.Logger = logging.getLogger(__name__)

_T = TypeVar("_T")

# =============================================================================
# CONSTANTS & PATHS
# =============================================================================
LABEL_NA: Final[str] = "N/A"
_LEADING_ENV_ASSIGNMENT_PATTERN: Final[re.Pattern[str]] = re.compile(
    r"[A-Za-z_][A-Za-z0-9_]*=.*"
)


def _get_xdg_path(env_var: str, default_suffix: str) -> Path:
    """Resolve an XDG base directory path with fallback to home directory."""
    value = os.environ.get(env_var, "").strip()
    if value:
        candidate = Path(value)
        if candidate.is_absolute():
            return candidate
    return Path.home() / default_suffix


_XDG_CACHE_HOME: Final[Path] = _get_xdg_path("XDG_CACHE_HOME", ".cache")
_XDG_CONFIG_HOME: Final[Path] = _get_xdg_path("XDG_CONFIG_HOME", ".config")

CACHE_DIR: Final[Path] = _XDG_CACHE_HOME / "dawncc"
SETTINGS_DIR: Final[Path] = _XDG_CONFIG_HOME / "dawn" / "settings"


# =============================================================================
# THREAD-SAFE STATE CONTAINERS
# =============================================================================
class _ResolvedDirectoryCache:
    """
    Thread-safe lazy directory resolver with caching.
    Uses double-checked locking pattern safe for CPython (GIL).
    """

    __slots__ = ("_base_dir", "_lock", "_resolved")

    def __init__(self, base_dir: Path) -> None:
        self._base_dir: Final[Path] = base_dir
        self._lock: Final[threading.Lock] = threading.Lock()
        self._resolved: Path | None = None

    def get(self) -> Path:
        """Get the resolved directory path, creating it if necessary."""
        resolved = self._resolved
        if resolved is not None:
            return resolved

        with self._lock:
            if self._resolved is not None:
                return self._resolved
            try:
                self._base_dir.mkdir(parents=True, exist_ok=True)
                self._resolved = self._base_dir.resolve(strict=True)
            except OSError as e:
                log.error("Failed to resolve directory %s: %s", self._base_dir, e)
                return self._base_dir
            return self._resolved


class _ComputeOnceCache:
    """
    Thread-safe compute-once cache with coalesced concurrent requests.
    Prevents "thundering herd" by ensuring only one thread computes a key.
    """

    __slots__ = ("_cache", "_in_flight", "_lock")

    def __init__(self) -> None:
        self._lock: Final[threading.Lock] = threading.Lock()
        self._cache: dict[str, object] = {}
        self._in_flight: dict[str, threading.Condition] = {}

    def get_or_compute(self, key: str, compute_fn: Callable[[], _T]) -> _T:
        """Get value from cache, or compute it if missing, handling concurrency."""
        with self._lock:
            while key in self._in_flight:
                cond = self._in_flight[key]
                cond.wait()
                if key in self._cache:
                    return self._cache[key]  # type: ignore[return-value]

            if key in self._cache:
                return self._cache[key]  # type: ignore[return-value]

            cond = threading.Condition(self._lock)
            self._in_flight[key] = cond

        try:
            value = compute_fn()
        except BaseException:
            with self._lock:
                del self._in_flight[key]
                cond.notify_all()
            raise

        with self._lock:
            self._cache[key] = value
            del self._in_flight[key]
            cond.notify_all()

        return value


_settings_dir_cache: Final = _ResolvedDirectoryCache(SETTINGS_DIR)
_cache_dir_cache: Final = _ResolvedDirectoryCache(CACHE_DIR)
_system_info_cache: Final = _ComputeOnceCache()


def get_cache_dir() -> Path:
    """Get the application cache directory."""
    return _cache_dir_cache.get()


# =============================================================================
# CONFIGURATION LOADER
# =============================================================================
def load_config(config_path: Path) -> dict[str, object]:
    """Load and parse YAML configuration safely."""
    try:
        content = config_path.read_text(encoding="utf-8")
    except (FileNotFoundError, OSError) as e:
        log.warning("Config file unreadable: %s (%s)", config_path, e)
        return {}

    try:
        data = yaml.safe_load(content)
    except yaml.YAMLError as e:
        log.error("YAML syntax error in %s: %s", config_path, e)
        return {}

    return data if isinstance(data, dict) else {}


# =============================================================================
# UWSM-COMPLIANT COMMAND RUNNER
# =============================================================================
def execute_command(cmd_string: str, title: str, run_in_terminal: bool) -> bool:
    """
    Execute a command via UWSM (Universal Wayland Session Manager).
    Returns True only if the launch request was handed off successfully.
    """
    normalized_cmd = _normalize_command(cmd_string)
    if not normalized_cmd:
        return False

    safe_title = _sanitize_title(title)
    full_cmd = _build_command_list(normalized_cmd, safe_title, run_in_terminal)

    if full_cmd is None:
        log.error("Failed to parse command: %r", cmd_string)
        return False

    if run_in_terminal:
        if shutil.which("kitty") is None:
            log.error("Terminal launcher 'kitty' was not found in PATH")
            return False
    elif full_cmd[2:4] != ["sh", "-c"]:
        executable = full_cmd[2]
        if shutil.which(executable) is None:
            log.error("Executable not found: %r", executable)
            return False

    from gi.repository import GLib

    try:
        GLib.spawn_async(
            full_cmd,
            flags=GLib.SpawnFlags.SEARCH_PATH,
        )
        return True
    except GLib.Error as e:
        log.error(
            "Executable failed or not found: %r. Ensure 'uwsm-app' is installed. (GLib Error: %s)",
            full_cmd[0] if full_cmd else "unknown",
            e.message,
        )
        return False
    except Exception as e:
        log.error("Unexpected error executing %r: %s", cmd_string, e)
        return False


def _normalize_command(cmd_string: str) -> str:
    """Trim surrounding whitespace and safely expand $HOME/~ to absolute paths."""
    cmd = cmd_string.strip()
    home_dir = str(Path.home())

    cmd = cmd.replace("$HOME", home_dir)

    if cmd.startswith("~/"):
        cmd = home_dir + cmd[1:]

    cmd = cmd.replace(" ~/", f" {home_dir}/")

    return cmd


def _sanitize_title(title: str | None) -> str:
    """Sanitize window title string."""
    base = (title or "").strip() or "Dusky Terminal"
    sanitized = "".join(
        c if c.isprintable() and c not in "\n\r\t\x00" else " " for c in base
    )
    return " ".join(sanitized.split()) or "Dusky Terminal"


def _requires_shell(command: str, parsed_args: list[str]) -> bool:
    """Return True only when shell semantics are actually required."""
    if _LEADING_ENV_ASSIGNMENT_PATTERN.fullmatch(parsed_args[0]) is not None:
        return True

    in_single = False
    in_double = False
    escaped = False
    token_start = True

    for index, ch in enumerate(command):
        if escaped:
            escaped = False
            token_start = False
            continue

        if in_single:
            if ch == "'":
                in_single = False
            continue

        if in_double:
            if ch == "\\":
                escaped = True
            elif ch == '"':
                in_double = False
            elif ch in "$`":
                return True
            continue

        if ch.isspace():
            token_start = True
            continue
        if ch == "\\":
            escaped = True
            token_start = False
            continue
        if ch == "'":
            in_single = True
            token_start = False
            continue
        if ch == '"':
            in_double = True
            token_start = False
            continue
        if ch in "|&;()<>`":
            return True
        if ch == "$":
            return True
        if ch == "~" and token_start:
            next_ch = command[index + 1] if index + 1 < len(command) else ""
            if not next_ch or next_ch.isspace() or next_ch == "/":
                return True

        token_start = False

    return False


def _build_command_list(
    normalized_cmd: str, safe_title: str, run_in_terminal: bool
) -> list[str] | None:
    """Construct the argv list for process spawning."""
    if run_in_terminal:
        return [
            "uwsm-app",
            "--",
            "kitty",
            "--class",
            "dawn-term",
            "--title",
            safe_title,
            "--hold",
            "sh",
            "-c",
            normalized_cmd,
        ]

    try:
        parsed_args = shlex.split(normalized_cmd, posix=True)
    except ValueError:
        return ["uwsm-app", "--", "sh", "-c", normalized_cmd]

    if not parsed_args:
        return None

    if _requires_shell(normalized_cmd, parsed_args):
        return ["uwsm-app", "--", "sh", "-c", normalized_cmd]

    return ["uwsm-app", "--", *parsed_args]


# =============================================================================
# PRE-FLIGHT DEPENDENCY CHECK
# =============================================================================
def preflight_check() -> None:
    """
    Check for critical dependencies (GTK, UWSM).

    Intended for startup use on the main thread. On failure, this function exits
    the current thread of execution via SystemExit.
    """
    missing_deps: list[str] = []

    try:
        import gi

        gi.require_version("Gtk", "4.0")
        gi.require_version("Adw", "1")
    except (ImportError, ValueError):
        missing_deps.append("python-gobject (GTK4/Libadwaita)")

    if shutil.which("uwsm-app") is None:
        missing_deps.append("uwsm (Universal Wayland Session Manager)")

    if missing_deps:
        msg = (
            "FATAL: Dusky Control Center missing dependencies:\n"
            + "\n".join(f"  - {dep}" for dep in missing_deps)
        )
        log.critical(msg)
        print(msg, file=sys.stderr)
        sys.exit(1)

    try:
        SETTINGS_DIR.mkdir(parents=True, exist_ok=True)
        test_file = SETTINGS_DIR / ".write_test"
        test_file.touch()
        test_file.unlink()
    except OSError as e:
        log.warning("Settings directory %s is not writable: %s", SETTINGS_DIR, e)


# =============================================================================
# SYSTEM VALUE RETRIEVAL
# =============================================================================
def get_system_value(key: str) -> str:
    """Get a system info value (bypasses cache for dynamic stats like memory)."""
    if key in {"memory_used"}:
        return _compute_system_value(key)
    return _system_info_cache.get_or_compute(key, lambda: _compute_system_value(key))


def _compute_system_value(key: str) -> str:
    """Actual logic to fetch system info."""
    match key:
        case "memory_total":
            return _get_memory_total()
        case "memory_used":
            return _get_memory_used()
        case "cpu_model":
            return _get_cpu_model()
        case "gpu_model":
            return _get_gpu_model()
        case "kernel_version":
            return os.uname().release
        case _:
            return LABEL_NA


def _get_memory_total() -> str:
    try:
        content = Path("/proc/meminfo").read_text(encoding="utf-8")
        for line in content.splitlines():
            if line.startswith("MemTotal:"):
                parts = line.split()
                if len(parts) >= 2:
                    kb = int(parts[1])
                    gb = round(kb / 1_048_576, 1)
                    return f"{gb} GB"
    except (OSError, ValueError, IndexError):
        pass
    return LABEL_NA


def _get_memory_used() -> str:
    try:
        content = Path("/proc/meminfo").read_text(encoding="utf-8")
        mem_total = 0
        mem_available = 0
        for line in content.splitlines():
            if line.startswith("MemTotal:"):
                mem_total = int(line.split()[1])
            elif line.startswith("MemAvailable:"):
                mem_available = int(line.split()[1])
        if mem_total and mem_available:
            used_kb = mem_total - mem_available
            used_gb = round(used_kb / 1_048_576, 1)
            return f"{used_gb} GB"
    except (OSError, ValueError, IndexError):
        pass
    return LABEL_NA


def _get_cpu_model() -> str:
    try:
        content = Path("/proc/cpuinfo").read_text(encoding="utf-8")
        for line in content.splitlines():
            if line.strip().lower().startswith("model name"):
                _, _, value = line.partition(":")
                return value.strip().split(" @")[0]
    except OSError:
        pass
    return LABEL_NA


def _get_gpu_model() -> str:
    """Detect GPU using lspci (human-readable or machine format)."""
    try:
        res = subprocess.run(
            ["lspci", "-mm"],
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
        )
        if res.returncode == 0:
            for line in res.stdout.splitlines():
                try:
                    fields = shlex.split(line, posix=True)
                except ValueError:
                    continue
                if len(fields) >= 4 and fields[1] in {
                    "VGA compatible controller",
                    "3D controller",
                }:
                    return f"{fields[2]} {fields[3]}".strip()

        res = subprocess.run(
            ["lspci"],
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
        )
        if res.returncode == 0:
            for line in res.stdout.splitlines():
                if "VGA compatible controller" in line or "3D controller" in line:
                    parts = line.split(":", 2)
                    if len(parts) > 2:
                        return parts[2].strip()
    except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
        pass
    return LABEL_NA


# =============================================================================
# SETTINGS PERSISTENCE (Atomic File I/O)
# =============================================================================
def _validate_settings_path(key: str) -> Path | None:
    """
    Validate the path to prevent directory traversal while natively resolving symlinks.
    This ensures atomic writes target the dotfile repo instead of clobbering the symlink.
    """
    if not key or not isinstance(key, str) or "\0" in key:
        return None

    pure = PurePosixPath(key)
    if pure.is_absolute() or any(part in {"", ".."} for part in pure.parts):
        log.warning("Invalid settings path key (traversal attempt detected): %r", key)
        return None

    base = _settings_dir_cache.get()
    target = base / key

    try:
        # Resolve strictly to follow symlinks to their ultimate destination
        if target.exists():
            return target.resolve(strict=True)
        # If it doesn't exist yet, resolve the parent
        return target.parent.resolve(strict=True) / target.name
    except OSError:
        return target


def save_setting(key: str, value: bool | int | float | str) -> bool:
    """Atomic write to disk (Temp File -> Fsync -> Rename)."""
    target = _validate_settings_path(key)
    if target is None:
        return False

    content = str(value)
    temp_fd: int | None = None
    temp_path: Path | None = None

    try:
        target.parent.mkdir(parents=True, exist_ok=True)
        # We create the temp file in the resolved parent directory so that
        # when we rename it over the target, we don't break the symlink 
        # sitting in ~/.config. It safely overwrites the file in the git repo.
        temp_fd, temp_path_str = tempfile.mkstemp(
            dir=target.parent, prefix=f".{target.name}.", suffix=".tmp"
        )
        temp_path = Path(temp_path_str)

        with os.fdopen(temp_fd, "w", encoding="utf-8") as f:
            temp_fd = None  # Transferred to file object
            f.write(content)
            f.flush()
            os.fsync(f.fileno())

        temp_path.rename(target)
        temp_path = None  # Prevent deletion of success file

        # Sync parent directory
        dir_fd = os.open(target.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(dir_fd)
        finally:
            os.close(dir_fd)
        
        return True

    except OSError as e:
        log.error("Save failed for %s: %s", key, e)
        return False
    finally:
        if temp_fd is not None:
            os.close(temp_fd)
        if temp_path is not None:
            temp_path.unlink(missing_ok=True)


@overload
def load_setting(key: str, default: bool) -> bool: ...

@overload
def load_setting(key: str, default: int) -> int: ...

@overload
def load_setting(key: str, default: float) -> float: ...

@overload
def load_setting(key: str, default: str) -> str: ...

@overload
def load_setting(key: str, default: None = None) -> str | None: ...

def load_setting(
    key: str,
    default: bool | int | float | str | None = None,
) -> bool | int | float | str | None:
    """Load setting with automatic type coercion based on default value."""
    target = _validate_settings_path(key)
    if target is None:
        return default

    try:
        raw = target.read_text(encoding="utf-8").strip()
    except (FileNotFoundError, OSError):
        return default

    try:
        match default:
            case bool():
                return _parse_bool(raw)
            case int():
                return int(raw)
            case float():
                return float(raw)
            case _:
                return raw
    except ValueError:
        return default


def _parse_bool(value: str) -> bool:
    """Robust boolean parsing."""
    lowered = value.strip().lower()
    if lowered in {"true", "yes", "on", "1"}:
        return True
    if lowered in {"false", "no", "off", "0"}:
        return False
    raise ValueError(f"Invalid boolean value: {value!r}")


# =============================================================================
# UI HELPERS
# =============================================================================
def toast(
    toast_overlay: Adw.ToastOverlay | None, message: str, timeout: int = 2
) -> None:
    """Schedule a toast notification on the main thread."""
    if toast_overlay is None:
        return

    from gi.repository import Adw as AdwLib, GLib

    def _show() -> bool:
        try:
            t = AdwLib.Toast.new(message)
            t.set_timeout(timeout)
            toast_overlay.add_toast(t)
        except Exception:
            pass
        return False

    GLib.idle_add(_show)
