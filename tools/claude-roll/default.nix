# claude-roll: rolls the Claude Code sessions in herdr's panes onto the
# Claude Code that is installed now, and records each pane's launch flags
# for that as Claude Code's SessionStart hook (README.md). It runs herdr and
# ravnix-notify from PATH, or the paths --herdr and --ravnix-notify give.
{ buildOdinTool, ... }:
buildOdinTool {
  name = "claude-roll";
  src = ./.;
  tests = ./tests;
  bench = ./bench;
  # The bench reads screens as herdr prints them and says what claude-roll
  # makes of each: the screen check, without herdr or a pane. long.txt is a
  # full viewport of transcript above the box.
  benchArgs = [
    "classify"
    "idle.txt"
    "draft.txt"
    "working.txt"
    "permission.txt"
    "resume.txt"
    "long.txt"
  ];
}
