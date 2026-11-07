# claude-code-verify

Proves that a Claude Code binary is the one Anthropic released. For every
version, `downloads.claude.ai` publishes a manifest with the size and the
sha256 of the binary of each platform; the tool checks a file against it.

```sh
claude-code-verify [--platform P] [--releases URL | --manifest FILE] BINARY VERSION
```

It fetches `URL/VERSION/manifest.json` (by default
`https://downloads.claude.ai/claude-code-releases`), checks that the
manifest is for `VERSION`, compares the file's size and then its sha256 with
the entry for the platform (by default the one it runs on, `linux-x64` on
x86_64), and prints one line.

| Exit | Means |
| --- | --- |
| 0 | verified |
| 1 | not verified: the size or the sha256 differs, the manifest is for another version, has no entry for the platform, or is not a manifest (a portal page, broken JSON, an answer above 1 MiB), or the server has no manifest of that version (404, 410) |
| 2 | bad usage, or a file that cannot be read |
| 3 | the manifest is unreachable: no connection, a timeout, a TLS error, a server error, a rate limit |

The manifest comes through curl, whose store path the build puts into the
binary (`-define:CURL=...`), because Odin's core library has no HTTPS
client. curl follows redirects to https only, gives up after 10 seconds
without a connection and 30 in all, and refuses an answer above 1 MiB.
`--manifest FILE` reads a manifest from a file instead, which is what the
tests and the bench do. `--releases URL` points at another server, such as
the fake release endpoint of a test.

## What it checks in ravnix

The file to verify is the download, not the program in the package.
`claude-code-nix` patches the downloaded binary with autoPatchelfHook, which
rewrites its ELF interpreter, so `.claude-unwrapped` in the package is 4 KiB
larger than what Anthropic released and never matches the manifest. The
download is the package's fixed-output input, which ravnix exposes as
`packages.x86_64-linux.claude-code.download` (`lib/claude-code.nix`); Nix's
derivation graph is what ties the patched program to those bytes.

The gate checks the version in ravnix's own `flake.lock`. A private flake
that makes ravnix's `claude-code` input follow its own installs the version
of its own lock, which this gate never sees, and runs the same command on
its own `packages.x86_64-linux.claude-code.download` (Task 6.1's update
timer).

`scripts/check.sh` runs the check in the full gate, before every push,
outside the build sandbox because it needs the network:

```sh
claude-code-verify "$(nix build --print-out-paths .#claude-code.download)" \
  "$(nix eval --raw .#claude-code.version)"
```

The gate records each version and download it verified
(`scripts/README.md`). An unreachable manifest (exit 3) passes the gate for a
download verified before and fails it for any other: the gate is the only
check ravnix has, and a push that bumps Claude Code while the manifest
cannot be reached would otherwise go out unverified, so that push waits until
`downloads.claude.ai` answers. A mismatch (exit 1) always fails. Task 6.1's
update timer tells exit 3 (try again at the next run) from exit 1 (do not
roll this binary).

## Tests and bench

`claude-code-verify-tests` covers a matching file, one flipped byte, an
empty and a longer file, a missing file and a directory, a manifest without
the platform (and with only a platform whose name starts the same), for
another version, without a size, with sizes and checksums of every wrong
shape, malformed and truncated JSON, two values, trailing bytes, a NUL, a
captive portal's page, a duplicate key, nesting 200 000 deep, eight threads
verifying at once, and curl answering 200, 404, 410, 403, 429 and 5xx,
failing to resolve, connect, finish or shake hands, printing no status,
being killed, missing and not executable, and the real curl against a port
where nothing listens.

`claude-code-verify-bench` verifies `bench/binary`, 85 KiB of text, against
`bench/manifest.json`: the manifest's parse and the hash, without the
network.

## Known gaps

Findings that are not fixed, so nobody mistakes them for covered.

- The manifest's signature is not checked. Anthropic publishes a detached
  OpenPGP signature beside it, `manifest.json.sig`; the tool trusts the
  manifest through TLS to `downloads.claude.ai` instead. Checking it needs
  Anthropic's signing key pinned in ravnix and an OpenPGP verifier.
- The bench counts the software SHA-256. Odin's `core:crypto` picks its
  SHA-256 code at run time by the CPU's SHA extensions (tools/README.md, "The
  same count on every host"); valgrind's synthetic CPU on this laptop offers
  none, so the bench measures the plain code, about 64 instructions a byte.
  On a host whose valgrind CPU offers them, the count drops far below the
  baseline, which passes, but the baseline taken there would not hold here.
- `core:encoding/json` turns an integer beyond the range of i64 into another
  integer without an error. The tool therefore reads numbers as f64 and
  takes a size only below 2^53; a binary of 8 PiB is refused as a bad
  manifest.
- Its runtime closure holds the whole Odin toolchain, about 2.5 GB: the
  source paths of Odin's core library are in the binary's panic and
  assertion messages, and Nix counts them as references. The template's
  package has the same; the fix belongs in `lib/odin.nix`.
- curl's standard error is read only after its standard output has ended.
  curl prints one line there with `--silent --show-error`, far below what a
  pipe holds; a curl that wrote more than 64 KiB to it would block.
- `nesting_within` counts brackets outside strings and trusts that the JSON
  is otherwise well formed; it only has to keep the parser's recursion
  bounded, and the parser refuses everything else.
