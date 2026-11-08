# The app_id (the StartupWMClass) of a window that Helium opens with
# `helium --app=URL`, derived from the URL, so a launcher and a compositor rule
# can name it without opening the window first.
#
# Chromium builds it as "chrome-", the application name, "-" and the name of
# the profile's directory, and the application name is the URL's host, "_", and
# its path, with every character a file name cannot hold turned into "_":
#
#   https://claude.ai/new     chrome-claude.ai__new-Default
#   https://cooking.example/  chrome-cooking.example__-Default
#
# `--class` does not change it for an --app window. Both values above were
# measured with `swaymsg -t get_tree` on the Fedora desktop; the rest follows
# from the rule (tests/desktop/webapps.nix has the cases). The port, the
# login in front of the host, the query and the fragment are no part of it,
# a URL without a path has the path "/", and the host is lower case, as a
# URL's is. The profile is the default one, "Default", which is the one the
# web apps share with the browser.
#
# A string that is no http or https URL with a host is an error.
{ lib }:
url:
let
  parts = builtins.match "https?://([^/?#]*)([^?#]*)([?#].*)?" url;
  authority = if parts == null then "" else builtins.elemAt parts 0;
  path' = if parts == null then "" else builtins.elemAt parts 1;

  # After the login, before the port. An IPv6 address keeps its brackets.
  hostPort = lib.last (lib.splitString "@" authority);
  hostMatch = builtins.match "([[][^]]*[]]|[^:]*)(:[0-9]*)?" hostPort;
  host = lib.toLower (if hostMatch == null then "" else builtins.elemAt hostMatch 0);

  path = if path' == "" then "/" else path';
  illegal = [
    "/"
    "\\"
    ":"
    "*"
    "?"
    "\""
    "<"
    ">"
    "|"
  ];
  name = "${host}_${builtins.replaceStrings illegal (map (_: "_") illegal) path}";
in
if parts == null || host == "" then
  throw "webapp-app-id: ${builtins.toJSON url} is not an http or https URL with a host"
else
  "chrome-${name}-Default"
