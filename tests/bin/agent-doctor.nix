# agent-doctor (packages/agent-doctor): what its checks report on a fixture
# corpus. The script has no tests in Fedora; these are new. It is Python with
# the standard library only, and needs nothing on the PATH.
{
  self,
  pkgs,
  system,
  ...
}:
pkgs.runCommand "bin-agent-doctor"
  {
    nativeBuildInputs = [
      pkgs.bash
      pkgs.coreutils
    ];
    AGENT_DOCTOR_UNDER_TEST = "${self.packages.${system}.agent-doctor}/bin/agent-doctor";
  }
  ''
    export HOME="$TMPDIR/home"
    mkdir -p "$HOME"
    bash ${../../packages/agent-doctor/tests/agent-doctor.test.sh}
    touch "$out"
  ''
