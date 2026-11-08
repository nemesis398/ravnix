"""Argument parsing and the entry point.

Logging goes to stderr with no timestamp of its own, because systemd stamps
every line it picks up and two timestamps per line is what you get when a
daemon adds its own out of habit.

``main`` is a function returning an int rather than a bare module body, because
a launcher can import it:

    from sway_radial.__main__ import main
    raise SystemExit(main())
"""

from __future__ import annotations

import argparse
import logging
import sys
from pathlib import Path

from .daemon import DEFAULT_CONFIG, Daemon

__all__ = ["main"]


def _version() -> str:
    try:
        from importlib.metadata import version

        return version("sway-radial")
    except Exception:  # noqa: BLE001
        # The installed copy is on PYTHONPATH, not a distribution, so there is no
        # distribution to ask. Not being able to print a version is never a
        # reason to refuse to start.
        return "0.1.0"


def _parse_args(argv: list[str] | None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="sway-radial",
        description="Radial trackpad launcher for sway.",
    )
    parser.add_argument(
        "--config",
        type=Path,
        default=DEFAULT_CONFIG,
        metavar="PATH",
        help=f"menu file to load and watch (default: {DEFAULT_CONFIG})",
    )
    parser.add_argument(
        "-v",
        "--verbose",
        action="store_true",
        help="log at DEBUG, including every gesture event",
    )
    parser.add_argument("--version", action="version", version=f"sway-radial {_version()}")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = _parse_args(argv)
    logging.basicConfig(
        stream=sys.stderr,
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(levelname)s %(name)s: %(message)s",
    )
    return Daemon(config_path=args.config).run()


if __name__ == "__main__":
    raise SystemExit(main())
