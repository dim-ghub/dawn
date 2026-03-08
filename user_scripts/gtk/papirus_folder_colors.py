#!/usr/bin/env python3

import argparse
import re
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Final, Never

type RGB = tuple[int, int, int]

DEFAULT_CSS_FILE: Final[Path] = Path(
    "~/.config/matugen/generated/gtk-4.css"
).expanduser()

HEX_RE: Final = re.compile(r"#?(?P<value>[0-9A-Fa-f]{6})\Z")
CSS_COMMENT_RE: Final = re.compile(r"/\*.*?\*/", re.DOTALL)
ACCENT_COLOR_RE: Final = re.compile(
    r"^\s*@define-color\s+accent_color\s+(#[0-9A-Fa-f]{6})\s*;\s*$",
    re.MULTILINE,
)

PAPIRUS_THEME: Final[str] = "Papirus-Dark"
GSETTINGS_SCHEMA: Final[str] = "org.gnome.desktop.interface"
GSETTINGS_KEY: Final[str] = "icon-theme"

PAPIRUS_COLORS: Final[dict[str, str]] = {
    "adwaita": "93c0ea",
    "black": "4f4f4f",
    "blue": "5294e2",
    "bluegrey": "607d8b",
    "breeze": "57b8ec",
    "brown": "ae8e6c",
    "carmine": "a30002",
    "cyan": "00bcd4",
    "darkcyan": "45abb7",
    "deeporange": "eb6637",
    "green": "87b158",
    "grey": "8e8e8f",
    "indigo": "5c6bc0",
    "magenta": "ca71df",
    "nordic": "81a1c1",
    "orange": "ee923a",
    "palebrown": "d1bfae",
    "paleorange": "eeca8f",
    "pink": "f06292",
    "red": "e25252",
    "teal": "16a085",
    "violet": "7e57c2",
    "white": "e4e4e4",
    "yaru": "676767",
    "yellow": "f9bd30",
}


def fail(message: str, exit_code: int = 1) -> Never:
    print(message, file=sys.stderr)
    raise SystemExit(exit_code)


def normalize_hex(value: str) -> str:
    match = HEX_RE.fullmatch(value.strip())
    if match is None:
        raise ValueError(f"Invalid 6-digit hex color: {value!r}")
    return f"#{match.group('value').lower()}"


def hex_to_rgb(value: str) -> RGB:
    hex_value = normalize_hex(value)[1:]
    return (
        int(hex_value[0:2], 16),
        int(hex_value[2:4], 16),
        int(hex_value[4:6], 16),
    )


PAPIRUS_RGBS: Final[dict[str, RGB]] = {
    name: hex_to_rgb(hex_value) for name, hex_value in PAPIRUS_COLORS.items()
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Apply the closest Papirus-Dark folder color to a GTK accent color.",
        epilog=(
            "Examples:\n"
            "  papirus_folder_colors.py\n"
            "  papirus_folder_colors.py 0e973f\n"
            "  papirus_folder_colors.py '#0e973f'\n"
            "  papirus_folder_colors.py ~/.config/matugen/generated/gtk-4.css\n\n"
            "Note: an unquoted # starts a shell comment, so '#0e973f' must be quoted."
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "target",
        nargs="?",
        default=str(DEFAULT_CSS_FILE),
        help="A 6-digit hex color or a GTK CSS file path.",
    )
    return parser.parse_args()


def extract_accent_hex_from_css(path: Path) -> str:
    if not path.is_file():
        fail(f"Error: file not found: {path}")

    try:
        content = path.read_text(encoding="utf-8")
    except UnicodeDecodeError as exc:
        fail(f"Error: file is not valid UTF-8: {path} ({exc})")
    except OSError as exc:
        fail(f"Error: could not read file: {path} ({exc})")

    content = CSS_COMMENT_RE.sub("", content)
    matches = ACCENT_COLOR_RE.findall(content)

    if not matches:
        fail(
            "Error: could not find an active line like "
            "'@define-color accent_color #xxxxxx;' in the CSS file."
        )

    return matches[-1].lower()


def resolve_target_to_hex(target: str) -> str:
    path = Path(target).expanduser()

    if path.is_file():
        return extract_accent_hex_from_css(path)

    try:
        return normalize_hex(target)
    except ValueError:
        if target == str(DEFAULT_CSS_FILE):
            fail(
                f"Error: default CSS file was not found: {DEFAULT_CSS_FILE}\n"
                "Pass a hex color like '0e973f' or a valid CSS file path."
            )
        fail(
            f"Error: {target!r} is neither an existing file nor a valid 6-digit hex color."
        )


def perceptual_distance(left: RGB, right: RGB) -> int:
    dr = left[0] - right[0]
    dg = left[1] - right[1]
    db = left[2] - right[2]

    # Integer-weighted luma distance. Same ordering as 0.30 / 0.59 / 0.11, no float noise.
    return 30 * dr * dr + 59 * dg * dg + 11 * db * db


def find_closest_papirus_color(target_hex: str) -> str:
    target_rgb = hex_to_rgb(target_hex)
    return min(
        PAPIRUS_RGBS,
        key=lambda name: perceptual_distance(PAPIRUS_RGBS[name], target_rgb),
    )


def apply_papirus_color(color_name: str) -> None:
    try:
        result = subprocess.run(
            ["papirus-folders", "-C", color_name, "--theme", PAPIRUS_THEME],
            check=True,
            capture_output=True,
            text=True,
        )
    except FileNotFoundError:
        fail("Error: 'papirus-folders' was not found in PATH.")
    except subprocess.CalledProcessError as exc:
        detail = exc.stderr.strip() or exc.stdout.strip() or str(exc)
        fail(f"Error: papirus-folders failed: {detail}")

    if result.returncode != 0:
        fail("Error: papirus-folders failed for an unknown reason.")


def run_gsettings(*args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["gsettings", *args],
        check=False,
        capture_output=True,
        text=True,
    )


def refresh_icon_theme() -> None:
    # Best-effort only. Failure here should not undo a successful papirus-folders run.
    if shutil.which("gsettings") is None:
        return

    try:
        current = run_gsettings("get", GSETTINGS_SCHEMA, GSETTINGS_KEY)
    except OSError as exc:
        print(f"Warning: could not run gsettings: {exc}", file=sys.stderr)
        return

    if current.returncode != 0:
        return

    current_theme = current.stdout.strip().strip("'")
    if current_theme != PAPIRUS_THEME:
        return

    for theme in ("Adwaita", PAPIRUS_THEME):
        try:
            result = run_gsettings("set", GSETTINGS_SCHEMA, GSETTINGS_KEY, theme)
        except OSError as exc:
            print(f"Warning: could not refresh icon theme: {exc}", file=sys.stderr)
            return

        if result.returncode != 0:
            detail = result.stderr.strip() or result.stdout.strip() or f"exit code {result.returncode}"
            print(
                f"Warning: could not refresh icon theme while setting {theme}: {detail}",
                file=sys.stderr,
            )
            return


def main() -> int:
    args = parse_args()
    target_hex = resolve_target_to_hex(args.target)
    closest_color = find_closest_papirus_color(target_hex)

    print(f"Target accent: {target_hex}")
    print(f"Applying {PAPIRUS_THEME} folder color: {closest_color}")

    apply_papirus_color(closest_color)
    refresh_icon_theme()

    print("Folder theme successfully updated.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
