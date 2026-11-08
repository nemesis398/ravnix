#!/usr/bin/env bash
# A stand-in for notify-send: FAKE_DIR/notify.log gets one line per call. With
# FAKE_DIR/notify-fails it fails, as it does with no notification daemon.
printf '%s\n' "$*" >>"${FAKE_DIR:?}/notify.log"
[ ! -f "${FAKE_DIR}/notify-fails" ]
