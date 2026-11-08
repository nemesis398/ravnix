#!/usr/bin/env python3
"""Prints the value that tests/desktop/sway.nix puts into it as a token.

The token stands where a data file of the desktop module puts a user's value
into Python (`BASE_URL = <token>`). The check builds this file with a value
full of quotes, backslashes and line breaks and compares what comes out with
the value, byte for byte.
"""
import sys

VALUE = @value@

sys.stdout.write(VALUE)
