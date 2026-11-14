"""Fixture writers shared by the ai-memory tests."""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from notes import MEMORY_DIR, Note, parse_frontmatter  # noqa: E402

# A memory note that every lint rule accepts. Each test changes one key.
CLEAN_MEMORY = {
    "type": "memory",
    "status": "active",
    "domain": "[claude-code]",
    "updated": "2026-10-17",
    "description": '"A fact worth keeping."',
    "tags": "[reference]",
}


def front(**fields: str | None) -> str:
    """Frontmatter lines for a clean memory note.

    Each keyword replaces or adds one key, given as its raw YAML text, and
    None drops the key.
    """
    merged = {**CLEAN_MEMORY, **fields}
    return "".join(f"{k}: {v}\n" for k, v in merged.items() if v is not None)


def text(n: int) -> str:
    """`n` characters of words, so that no run of them looks like a token."""
    return ("fact " * n)[: n - 1] + "."


def write_note(folder: Path, name: str, front: str, body: str = "Fact.\n") -> Path:
    """Write `name` into `folder` as `---\\n{front}---\\n\\n{body}`."""
    folder.mkdir(parents=True, exist_ok=True)
    path = folder / name
    path.write_text(f"---\n{front}---\n\n{body}", encoding="utf-8")
    return path


def write_sized_note(folder: Path, name: str, front: str, size: int) -> Path:
    """Write a note whose file is exactly `size` bytes, padded in the body."""
    head = len(f"---\n{front}---\n\n".encode())
    path = write_note(folder, name, front, text(size - head - 1) + "\n")
    assert path.stat().st_size == size, path.stat().st_size
    return path


def memory(name: str, frontmatter: str, body: str = "Fact.\n") -> Note:
    """`name` in AI/memory as load_notes would read it, built without a file.

    The frontmatter goes through the real reader, so the note's meta is
    exactly what the hooks get from a file with this text.
    """
    content = f"---\n{frontmatter}---\n\n{body}"
    meta, rest = parse_frontmatter(content)
    rel = f"{MEMORY_DIR}/{name}"
    return Note(Path(rel), rel, Path(name).stem, meta, rest, len(content.encode()))


def filler(n: int) -> list[Note]:
    """`n` unrelated active notes, so that a test's N is realistic.

    Each note's number (`0000`, `0001`, ...) is a word of its own title only.
    The other words are in all of them, so they score next to nothing, and no
    test prompt uses them. Their domain is `filler`, which no test digests.
    """
    shared = front(domain="[filler]", updated="2026-01-01",
                   description='"An unrelated filler note."')
    return [memory(f"filler-{i:04d}.md", shared) for i in range(n)]
