#!/usr/bin/env bash
# A stand-in for curl, for the tests of `nord` and `vpn-home`. FAKE_DIR holds
# its state; it answers by the URL it is given:
#   recommend.json   /servers/recommendations   (curl fails without it)
#   credentials.json /users/services/credentials
#   insights.json    /helpers/ips/insights
#   home-reply.json  any other URL, the home gateway's
#   curl-fails       makes every call fail as curl -f does on an HTTP error
#   curl.log         one line per call; curl.stdin the config read from "-K -"
set -u
d="${FAKE_DIR:?}"
printf '%s\n' "$*" >>"$d/curl.log"
url=""
for a in "$@"; do
	case "$a" in http://* | https://*) url="$a" ;; esac
done
prev=""
for a in "$@"; do
	if [ "$prev" = -K ] && [ "$a" = - ]; then
		cat >>"$d/curl.stdin"
	fi
	prev="$a"
done
if [ -f "$d/curl-fails" ]; then
	echo "curl: (22) The requested URL returned error: 500" >&2
	exit 22
fi
reply=""
case "$url" in
*/servers/recommendations) reply=recommend.json ;;
*/users/services/credentials) reply=credentials.json ;;
*/helpers/ips/insights) reply=insights.json ;;
*) reply=home-reply.json ;;
esac
if [ -f "$d/$reply" ]; then
	cat "$d/$reply"
	exit 0
fi
echo "curl: (22) The requested URL returned error: 404" >&2
exit 22
