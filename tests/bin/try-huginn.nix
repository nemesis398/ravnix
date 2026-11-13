# try-huginn (packages/try-huginn, scripts/try-huginn.sh): the packaged build,
# not the script's behaviour, which scripts/tests/try-huginn.test.sh covers
# with a fake guard and a fake qemu. Here: the store paths are in the
# package (firmware that exists, QEMU, the guard, flock), and the command
# refuses bad usage and a normal user before it reaches the guard. The build
# user is not root, so the packaged command stops at the root check, which
# comes before the guard: no real disk is read.
{
  self,
  pkgs,
  system,
  ...
}:
pkgs.runCommand "bin-try-huginn"
  {
    nativeBuildInputs = [
      pkgs.gnugrep
    ];
    TRY_HUGINN = "${self.packages.${system}.try-huginn}/bin/try-huginn";
  }
  ''
    fail() { echo "FAIL: $*"; exit 1; }

    status=0
    "$TRY_HUGINN" >out 2>err || status=$?
    [ "$status" = 3 ] || fail "no arguments: exit $status, not 3"
    grep -q 'usage:' err || fail "no usage line"

    status=0
    "$TRY_HUGINN" --model m --serial s >out 2>err || status=$?
    [ "$status" = 1 ] || fail "as a normal user: exit $status, not 1"
    grep -q 'needs root' err || fail "the refusal does not say root: $(cat err)"

    # What the package holds: firmware that exists, and the tools by store path.
    for f in $(grep -o '/nix/store/[^"]*OVMF_[A-Z]*\.fd' "$TRY_HUGINN" | sort -u); do
      [ -r "$f" ] || fail "firmware $f is not readable"
      echo "firmware $f"
    done
    [ "$(grep -o '/nix/store/[^"]*OVMF_[A-Z]*\.fd' "$TRY_HUGINN" | sort -u | wc -l)" = 2 ] ||
      fail "the script does not name exactly OVMF_CODE.fd and OVMF_VARS.fd"
    if grep -q '@ovmf' "$TRY_HUGINN"; then fail "a placeholder is left"; fi
    grep -q 'ravnix-disk-guard' "$TRY_HUGINN" || fail "no guard"
    grep -q 'qemu-kvm\|qemu-host-cpu-only' "$TRY_HUGINN" || fail "no store qemu on the PATH"
    grep -q 'util-linux' "$TRY_HUGINN" || fail "no flock on the PATH"
    # The lock: the install's fixed path, with no variable to move it.
    grep -qF 'lock="/run/lock/ravnix-huginn-disk.lock"' "$TRY_HUGINN" || fail "the lock path is not the install's"
    if grep -q 'RAVNIX_HUGINN_LOCK' "$TRY_HUGINN"; then fail "a variable can move the lock"; fi
    touch "$out"
  ''
