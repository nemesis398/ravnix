#!/usr/bin/env bash
# A stand-in for notify-send: FAKE_DIR/notify.log gets one line per call.
printf '%s\n' "$*" >>"${FAKE_DIR:?}/notify.log"
