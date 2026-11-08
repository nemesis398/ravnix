#!/usr/bin/env bash
# claude-artifacts: start Claude Code with the Artifact tool switched on.
#
# Why: the Artifact tool's definition is about 15k tokens, a quarter of every
# session's fixed baseline, and it rides along into every subagent. It was
# used once in 30 days. So the graphical session exports
# CLAUDE_CODE_DISABLE_ARTIFACT=1 from environment.d (80-claude-code.conf), and
# this launcher removes that variable for one session.
#
# The switch cannot live in the `env` block of ~/.claude/settings.json: Claude
# Code applies that block to itself, and neither --settings nor the shell can
# undo it, which the first version of this script found out the hard way.
# `enableArtifact: false` in user settings is no better, because an "off"
# there wins over every other source.
#
# The --settings part lists the three artifact skills again, which user
# settings hide from the model while the tool is off. Every argument passes
# through to claude unchanged.
#
# Check the switch with /context in an interactive session. `claude -p` never
# offers the Artifact tool, whichever way the variable is set, so a headless
# on/off probe gives two identical runs and proves nothing (2.1.302).
#
# The secrets: on Fedora every shell held the MCP tokens, so this launcher
# inherited them. Here only the `claude` function of the interactive shell adds
# them (modules/common/bash/secrets.bash), and a command is not that function,
# so with-secret-env reads the same table (ravnix.shell.secretEnv) and starts
# claude with the tokens, exporting them only after the last read. Without a
# table, an unlocked vault or an rbw, claude starts without them and a note
# says why.
exec with-secret-env -- env -u CLAUDE_CODE_DISABLE_ARTIFACT claude --settings '{"skillOverrides":{"artifact-design":"on","artifact-capabilities":"on","artifact-diagramming":"on"}}' "$@"
