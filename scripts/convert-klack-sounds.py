#!/usr/bin/env python3
"""Convert Klack.app sound packs into bucklespring-compatible WAV directories.

Klack (https://klack.app) is a proprietary macOS keyboard-sound app that ships
six sound packs under `/Applications/Klack.app/Contents/Resources/<Pack>/`. Its
files are named `{decimal_scancode}-down.wav` / `{decimal_scancode}-up.wav` in
stereo 48 kHz. Bucklespring expects `{hex_scancode}-{0|1}.wav` in mono 44.1 kHz.

This script transcodes a locally installed Klack pack into bucklespring's
format. It does not redistribute Klack audio — users must own and install Klack
themselves. The output is always overlaid on top of bucklespring's Model-M
baseline (the `wav/` directory) so every key makes a sound — F-keys, keypad,
and mouse click fall through to the Model-M samples since Klack doesn't cover
them. The output directory is then used via bucklespring's existing `-p PATH`
flag (see main.c:131).

Usage:
    scripts/convert-klack-sounds.py --pack Cardboard
    scripts/convert-klack-sounds.py --all

Dependencies: Python 3 standard library plus `afconvert` (bundled with macOS).
"""
from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path


KLACK_HOMEPAGE = "https://klack.app"

# The six sound packs Klack ships. All share the same stem set; only the
# audio content differs.
KLACK_PACKS: tuple[str, ...] = (
    "Cardboard",
    "Cream",
    "Crystal Purple",
    "Japanese Black",
    "Milky Yellow",
    "Oreo",
)

# Single-byte PC set-1 scancodes as decimal stems. Klack uses stems 1..58
# except 55 (Print Screen). This covers ESC through CapsLock.
DECIMAL_STEMS: frozenset[int] = frozenset(set(range(1, 55)) | {56, 57, 58})

# 16-bit big-endian extended scancodes (arrow keys).
#   57416 = 0xE048 Arrow Up,    57419 = 0xE04B Arrow Left
#   57421 = 0xE04D Arrow Right, 57424 = 0xE050 Arrow Down
# Bucklespring's scan-mac.c already collapses arrows onto the same single-byte
# set-1 code as the corresponding keypad key, so we map to the low byte.
EXTENDED_ARROWS: dict[int, int] = {
    57416: 0x48,
    57419: 0x4B,
    57421: 0x4D,
    57424: 0x50,
}

# Extended modifiers stored with reversed nibble order (0x0E-prefix rather
# than the standard 0xE0).
#   3640 = 0x0E38 RAlt, 3675 = 0x0E5B LWin, 3676 = 0x0E5C RWin
# scan-mac.c collapses both Alt keys to 0x38 and both Cmd keys to 0x5b.
EXTENDED_MODS: dict[int, int] = {
    3640: 0x38,
    3675: 0x5B,
    3676: 0x5B,
}

# When multiple stems resolve to the same hex code, these are the chosen
# winners. Non-winners are skipped (and logged in verbose mode).
#   0x38: prefer single-byte stem 56 (LAlt) over extended 3640 (RAlt)
#   0x5b: prefer 3675 (LWin) over 3676 (RWin)
PRIORITY: dict[int, int] = {0x38: 56, 0x5B: 3675}


@dataclass(frozen=True)
class ConversionResult:
    pack: str
    written: int
    skipped_collisions: int
    skipped_uptodate: int
    merged: int


def resolve_hex_code(stem: int) -> int | None:
    """Return the bucklespring hex scancode for a Klack stem, or None."""
    if stem in DECIMAL_STEMS:
        return stem  # decimal value is already the byte
    if stem in EXTENDED_ARROWS:
        return EXTENDED_ARROWS[stem]
    if stem in EXTENDED_MODS:
        return EXTENDED_MODS[stem]
    return None


def parse_filename(path: Path) -> tuple[int, str] | None:
    """Parse `{stem}-{down|up}.wav` → (stem, '1' or '0'). None if unparseable."""
    if path.suffix != ".wav":
        return None
    stem_and_dir = path.stem  # e.g. "28-down"
    if stem_and_dir.endswith("-down"):
        return int(stem_and_dir[:-5]), "1"
    if stem_and_dir.endswith("-up"):
        return int(stem_and_dir[:-3]), "0"
    return None


def transcode(src: Path, dst: Path) -> None:
    """Stereo 48 kHz → mono 44.1 kHz 16-bit LE WAV via macOS afconvert."""
    dst.parent.mkdir(parents=True, exist_ok=True)
    result = subprocess.run(
        [
            "afconvert",
            "-f", "WAVE",
            "-d", "LEI16@44100",
            "-c", "1",
            str(src),
            str(dst),
        ],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise RuntimeError(
            f"afconvert failed for {src} → {dst}:\n{result.stderr}"
        )


def up_to_date(src: Path, dst: Path) -> bool:
    return dst.exists() and dst.stat().st_mtime >= src.stat().st_mtime


def convert_pack(
    pack: str,
    klack_resources: Path,
    out_root: Path,
    baseline: Path,
    force: bool,
    verbose: bool,
) -> ConversionResult:
    pack_src = klack_resources / pack
    if not pack_src.is_dir():
        raise FileNotFoundError(f"Klack pack not found: {pack_src}")

    pack_out = out_root / pack
    pack_out.mkdir(parents=True, exist_ok=True)

    # Seed the output with the Model-M baseline so F-keys, keypad, and mouse
    # click (keys Klack doesn't cover) still make sound. Klack's transcoded
    # files will overwrite the slots they cover in the loop below.
    if not baseline.is_dir():
        raise FileNotFoundError(
            f"Model-M baseline not found: {baseline}\n"
            f"       Expected bucklespring's `wav/` directory alongside `scripts/`."
        )
    merged = 0
    for wav in sorted(baseline.glob("*.wav")):
        target = pack_out / wav.name
        if force or not up_to_date(wav, target):
            shutil.copy2(wav, target)
            merged += 1
            if verbose:
                print(f"  seed {wav.name}")

    written = 0
    skipped_collisions = 0
    skipped_uptodate = 0

    for src in sorted(pack_src.glob("*.wav")):
        parsed = parse_filename(src)
        if parsed is None:
            if verbose:
                print(f"  skip unparseable {src.name}")
            continue
        stem, press = parsed

        hex_code = resolve_hex_code(stem)
        if hex_code is None:
            if verbose:
                print(f"  skip unknown stem {stem} ({src.name})")
            continue

        winner = PRIORITY.get(hex_code)
        if winner is not None and stem != winner:
            skipped_collisions += 1
            if verbose:
                print(
                    f"  skip stem {stem} — 0x{hex_code:02x} already owned by "
                    f"stem {winner}"
                )
            continue

        target = pack_out / f"{hex_code:02x}-{press}.wav"
        if not force and up_to_date(src, target):
            skipped_uptodate += 1
            if verbose:
                print(f"  up-to-date {target.name}")
            continue

        transcode(src, target)
        written += 1
        if verbose:
            print(f"  wrote {target.name}  <- {src.name}")

    return ConversionResult(
        pack=pack,
        written=written,
        skipped_collisions=skipped_collisions,
        skipped_uptodate=skipped_uptodate,
        merged=merged,
    )


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Convert Klack.app sound packs to bucklespring WAV format.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "Klack is proprietary software. This script operates on the user's\n"
            "own local Klack installation and does not redistribute its audio.\n"
            f"Klack homepage: {KLACK_HOMEPAGE}"
        ),
    )
    group = parser.add_mutually_exclusive_group()
    group.add_argument(
        "--pack",
        default="Cardboard",
        help="pack name to convert (default: Cardboard)",
    )
    group.add_argument(
        "--all",
        action="store_true",
        help=f"convert all packs: {', '.join(KLACK_PACKS)}",
    )
    parser.add_argument(
        "--out",
        type=Path,
        default=Path("./wav-klack"),
        help="output root directory (default: ./wav-klack)",
    )
    parser.add_argument(
        "--klack-app",
        type=Path,
        default=Path("/Applications/Klack.app"),
        help="path to Klack.app (default: /Applications/Klack.app)",
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="re-transcode even if output is up-to-date",
    )
    parser.add_argument(
        "-v", "--verbose",
        action="store_true",
        help="print per-file progress",
    )
    args = parser.parse_args()

    klack_resources = args.klack_app / "Contents" / "Resources"
    if not klack_resources.is_dir():
        print(
            f"error: Klack not found at {args.klack_app}\n"
            f"       install it from {KLACK_HOMEPAGE} (paid, Mac App Store)",
            file=sys.stderr,
        )
        return 1

    if shutil.which("afconvert") is None:
        print(
            "error: `afconvert` not found on PATH (expected at /usr/bin/afconvert).\n"
            "       This script requires macOS.",
            file=sys.stderr,
        )
        return 2

    # Bucklespring's Model-M baseline lives next to `scripts/`, so resolve it
    # relative to this file regardless of the user's cwd.
    baseline = Path(__file__).resolve().parent.parent / "wav"

    packs = list(KLACK_PACKS) if args.all else [args.pack]

    for pack in packs:
        if pack not in KLACK_PACKS:
            print(
                f"error: unknown pack {pack!r}. Known packs: {', '.join(KLACK_PACKS)}",
                file=sys.stderr,
            )
            return 1

    print(f"Klack source:     {klack_resources}")
    print(f"Model-M baseline: {baseline}")
    print(f"Output root:      {args.out.resolve()}")

    results: list[ConversionResult] = []
    for pack in packs:
        print(f"\n[{pack}]")
        try:
            result = convert_pack(
                pack=pack,
                klack_resources=klack_resources,
                out_root=args.out,
                baseline=baseline,
                force=args.force,
                verbose=args.verbose,
            )
        except (FileNotFoundError, RuntimeError) as e:
            print(f"error: {e}", file=sys.stderr)
            return 2
        results.append(result)
        print(
            f"  wrote {result.written}, "
            f"up-to-date {result.skipped_uptodate}, "
            f"collision-skipped {result.skipped_collisions}, "
            f"seeded {result.merged}"
        )

    # Sanity: the merged pack must have at least as many files as the baseline
    # (every Klack scancode is a subset of Model-M's, so the count is stable).
    baseline_count = len(list(baseline.glob("*.wav")))
    for r in results:
        produced = len(list((args.out / r.pack).glob("*.wav")))
        if produced < baseline_count:
            print(
                f"error: pack {r.pack!r} produced only {produced} files "
                f"(expected ≥ {baseline_count}). Something went wrong.",
                file=sys.stderr,
            )
            return 3

    print(f"\nDone. Run: ./buckle -p {args.out}/{packs[0]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
