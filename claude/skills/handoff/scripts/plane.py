#!/usr/bin/env python3
# scripts/plane.py
"""The only place in this skill that knows how to talk to Plane.

Two facts shape everything here. The MCP gateway answers a single ordinary
HTTP POST with no handshake and no session id, returning SSE-framed JSON-RPC,
so a shell script can speak it and a hook does not need an MCP client. And a
PQL filter is accepted and silently ignored, so nothing here sends one and
every filter is applied client side.
"""
from __future__ import annotations

import json
import os
import urllib.error
import urllib.request
from datetime import datetime, timezone

import skill_values as sv

GATEWAY_KEY = "plane.mcpUrl"


def gateway() -> str | None:
    """PLANE_MCP_URL, else the skill value `plane.mcpUrl`, else None."""
    return os.environ.get("PLANE_MCP_URL") or sv.get(GATEWAY_KEY)

# An item is open when its state's group is one of these. The group, not the
# name, because state ids differ per project and the names are free: the project
# role adds "Epic Backlog" and "Epic In Progress" to every board, and a
# name match dropped those items without a word. The names stay as the fallback
# for a state the gateway returns without a group.
OPEN_GROUPS = {"backlog", "unstarted", "started"}
OPEN_STATES = {"backlog", "todo", "in progress"}

# What a handoff comment opens with, and the only thing that tells it from any
# other comment on the same item: an evidence comment, a correction, a note
# typed into the UI. An HTML comment, so Plane keeps it and never renders it.
# A project with its own Plane hooks may write the same marker, so the string
# must not drift.
HANDOFF_MARKER = "<!-- plane-handoff -->"

# A runaway board must not make every session start crawl. Five pages is 500
# items, well past anything here: the largest board held 72 on 2026-08-23. Hitting this bound sets truncated rather than passing in silence.
MAX_PAGES = 5

# The budget for one call, and a session-start board read is two of them.
#
# This is a concurrency constant, not a network one. A TCP connect to the
# gateway measured 0.5ms to 3.9ms across 75 samples, so nothing here is ever
# waiting for the wire; what it waits for is the gateway's own queue. Per-call
# worst case against N simultaneous session starts, measured 2026-08-25 with
# the budget held wide open so that nothing was censored by the cap:
#
#     N          1      2      4      8     12
#     worst   0.38s  0.45s  0.65s  1.33s  2.12s
#
# Two things in that row set the value. The curve is shifted rather than
# bimodal, the median moving in step with the worst case, so under load every
# caller slows together and no one request is stalling. And it crosses 2.0s at
# twelve, which is not a contrived number on a machine that had four sessions
# live at once. At the measured 0.18s per additional session, 5.0s carries
# about twenty-eight of them.
#
# One retry was the other candidate and it loses on that same shape. Redrawing
# from a distribution that has shifted misses for the reason the first attempt
# missed, and bills the first attempt's whole budget for the privilege:
# measured head to head at twelve, the retry arm reached 4.38s where the wider
# budget wanted 2.2s for the same answer. It also adds a request to the one
# component already saturated, and this gateway rate-limits, answering 429 and
# then 401, which reads exactly like a dead token.
#
# It costs nothing offline, which is the case 2.0s was chosen for. Two of the
# three offline shapes fail on the instant whatever this says: no route off the
# LAN is 7ms, a refused connection is 5ms. Only a gateway host that is down at
# layer 2 pays the budget, and only until the kernel caches the failure, after
# which it is 0.39s.
TIMEOUT = 5.0


class PlaneError(Exception):
    """Plane could not be read. Never swallowed into an empty result."""


def _first_text(result: dict) -> str | None:
    for block in result.get("content") or []:
        if isinstance(block, dict) and isinstance(block.get("text"), str):
            return block["text"]
    return None


def unwrap(reply) -> dict:
    """One JSON-RPC reply to the tool's own payload, or raise.

    A board this cannot read must raise. Returning an empty dict would reach a
    defensive caller as "no work", and a session would then invent some.
    """
    if not isinstance(reply, dict):
        raise PlaneError(f"reply is {type(reply).__name__}, not an object")
    err = reply.get("error")
    if err is not None:
        message = err.get("message") if isinstance(err, dict) else str(err)
        raise PlaneError(f"gateway error: {message}")
    result = reply.get("result")
    if not isinstance(result, dict):
        raise PlaneError(f"result is {type(result).__name__}, not an object")
    if result.get("isError"):
        raise PlaneError(_first_text(result) or "tool reported an error")
    structured = result.get("structuredContent")
    if isinstance(structured, dict):
        if "result" in structured and structured["result"] is None:
            # An explicit null with isError false is a write that returned
            # nothing, which is what a successful delete looks like. It is not
            # the same as a board that could not be read: that shape never
            # reaches here, because it arrives as an error or as an exception
            # out of call(). Measured against a real delete 2026-08-23.
            return {}
        inner = structured.get("result", structured)
        if isinstance(inner, dict):
            return inner
    text = _first_text(result)
    if text is None:
        raise PlaneError("no text content in result")
    try:
        parsed = json.loads(text)
    except ValueError:
        # The gateway reports a rejected call as ORDINARY PROSE with
        # isError false, so an unknown or misspelled argument comes back
        # looking exactly like a successful reply. Returning it as {"raw": ...}
        # let a migration print "created" for items that were never created.
        # Measured 2026-08-23: action 'create' does not take: state_id.
        if text.lstrip().lower().startswith("error"):
            raise PlaneError(text.strip()[:400])
        return {"raw": text}
    return parsed if isinstance(parsed, dict) else {"raw": text}


def _parse_sse(body: str) -> dict:
    for line in body.splitlines():
        if line.startswith("data: "):
            try:
                return json.loads(line[6:])
            except ValueError as exc:
                raise PlaneError(f"data frame is not JSON: {exc}") from exc
    try:
        return json.loads(body)
    except ValueError as exc:
        raise PlaneError("no data frame and body is not JSON") from exc


def call(slug: str, tool: str, arguments: dict, timeout: float = TIMEOUT) -> dict:
    url = gateway()
    if not url:
        raise PlaneError(str(sv.Missing(GATEWAY_KEY)))
    token = os.environ.get("PLANE_API_TOKEN")
    if not token:
        raise PlaneError("PLANE_API_TOKEN is not set")
    payload = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "tools/call",
                          "params": {"name": tool, "arguments": arguments}}).encode()
    request = urllib.request.Request(url, data=payload, method="POST")
    request.add_header("Authorization", f"Bearer {token}")
    request.add_header("x-workspace-slug", slug)
    request.add_header("Content-Type", "application/json")
    request.add_header("Accept", "application/json, text/event-stream")
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            body = response.read().decode("utf-8", "replace")
    except (urllib.error.URLError, OSError, ValueError) as exc:
        raise PlaneError(f"gateway unreachable: {exc}") from exc
    return unwrap(_parse_sse(body))


class OpenItems(list):
    """The open items, and what the walk could not reach.

    A plain list, so every caller that only wants the items keeps working. The
    two extras are for the one caller that renders: a truncated board must be
    able to say so, because "no open work items" and "the ones I could see"
    read identically and only one of them is true.
    """

    truncated = False
    total = None


def open_items(slug: str, project_id: str, timeout: float = TIMEOUT,
               max_pages: int = MAX_PAGES) -> OpenItems:
    """Every item not in Done or Cancelled. Filtered here, never with PQL.

    The gateway caps per_page at 100, so a project past that is only readable
    by following next_cursor. The filter runs after the fetch, so a single page
    is not "the first 100 open items": it is the open ones among the first 100
    items, and on a project with a long closed history that can be none of them.
    """
    listed = call(slug, "state", {"action": "list", "project_id": project_id},
                  timeout).get("results", [])
    states = {s["id"]: s.get("name", "") for s in listed}
    groups = {s["id"]: (s.get("group") or "").strip().lower() for s in listed}
    out = OpenItems()
    cursor = ""
    for page in range(max_pages):
        arguments = {"action": "list", "project_id": project_id, "per_page": 100}
        if cursor:
            arguments["cursor"] = cursor
        got = call(slug, "workitem", arguments, timeout)
        if out.total is None:
            out.total = got.get("total_count")
        for item in got.get("results", []):
            name = states.get(item.get("state"), "")
            group = groups.get(item.get("state"), "")
            if (group in OPEN_GROUPS if group
                    else name.strip().lower() in OPEN_STATES):
                out.append(dict(item, state_name=name))
        if not got.get("next_page_results"):
            return out
        cursor = got.get("next_cursor") or ""
        if not cursor:
            # More exists and nothing was handed back to advance with. Stopping
            # is right, stopping quietly is the bug.
            break
    out.truncated = True
    return out


def open_elsewhere(slug: str, projects: list[dict],
                   timeout: float = TIMEOUT) -> list[dict]:
    """Which sibling projects hold open work, and how much.

    There is no workspace-level list to ask instead: that call answers HTTP 404
    through the gateway, measured 2026-08-23. So this is one read per project,
    which is why the caller runs it only when the directory's own project came
    back empty.

    Never raises. It is a fallback, and a session that read its own board fine
    keeps that board even when a sibling is unreadable.
    """
    out = []
    for project in projects:
        try:
            items = open_items(slug, project["id"], timeout)
        except Exception:  # noqa: BLE001 - a fallback must not take the board down
            continue
        if items:
            out.append({"identifier": project.get("identifier", "?"),
                        "count": len(items)})
    return out


def _created(row: dict) -> datetime:
    """When a comment was written, as a real instant.

    Plane stamps with a local offset, and Europe/Berlin changes its offset
    twice a year. Sorting those as strings inverts across that boundary: on
    2026-10-25, 02:15+01:00 is later than 02:30+02:00 and sorts earlier. This
    function decides which handoff a resumed session reads, so the inversion
    is silent and picks the wrong one.

    An unreadable or missing stamp sorts oldest rather than raising, because a
    resumed session losing its handoff over one malformed row is worse than
    losing that row.
    """
    stamp = (row.get("created_at") or "").strip()
    try:
        when = datetime.fromisoformat(stamp.replace("Z", "+00:00"))
    except ValueError:
        return datetime.min.replace(tzinfo=timezone.utc)
    # Naive and aware cannot be compared, and one malformed page would
    # otherwise be a TypeError on the gateway's formatting rather than on ours.
    return when if when.tzinfo else when.replace(tzinfo=timezone.utc)


def is_handoff(comment_html: str | None) -> bool:
    """Whether a comment is a handoff: it opens with HANDOFF_MARKER."""
    return (comment_html or "").lstrip().startswith(HANDOFF_MARKER)


def newest_comment(slug: str, project_id: str, item_id: str,
                   timeout: float = TIMEOUT) -> str | None:
    """The newest handoff on an item, or the newest comment if none is marked.

    The fallback is for chains written before the marker existed. Once one
    handoff carries it, a later comment without it is never the handoff.
    """
    got = call(slug, "workitem_comment",
               {"action": "list", "project_id": project_id, "workitem_id": item_id},
               timeout)
    rows = got.get("results") or []
    rows = [row for row in rows if is_handoff(row.get("comment_html"))] or rows
    if not rows:
        return None
    rows.sort(key=_created)
    return rows[-1].get("comment_html")
