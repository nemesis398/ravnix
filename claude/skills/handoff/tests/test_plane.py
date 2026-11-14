# tests/test_plane.py
import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import plane  # noqa: E402


class TestUnwrapRaisesRatherThanReturningNothing(unittest.TestCase):
    """The four shapes that escaped an earlier copy of this function.

    Each one reached a caller as an empty board rather than as an error, and
    the session then had no work and no warning that there was any.
    """

    def test_a_non_object_reply_raises(self):
        with self.assertRaises(plane.PlaneError):
            plane.unwrap(["not", "an", "object"])

    def test_a_non_object_result_raises(self):
        with self.assertRaises(plane.PlaneError):
            plane.unwrap({"jsonrpc": "2.0", "id": 1, "result": "a string"})

    def test_a_non_object_error_raises(self):
        with self.assertRaises(plane.PlaneError):
            plane.unwrap({"jsonrpc": "2.0", "id": 1, "error": "boom"})

    def test_a_null_text_field_raises(self):
        with self.assertRaises(plane.PlaneError):
            plane.unwrap({"result": {"content": [{"type": "text", "text": None}]}})

    def test_a_content_block_with_no_text_field_raises(self):
        with self.assertRaises(plane.PlaneError):
            plane.unwrap({"result": {"content": [{"type": "text"}]}})

    def test_an_iserror_result_raises_with_the_tool_message(self):
        reply = {"result": {"isError": True, "content": [
            {"type": "text", "text": "Error calling tool 'project': HTTP 404"}]}}
        with self.assertRaises(plane.PlaneError) as caught:
            plane.unwrap(reply)
        self.assertIn("404", str(caught.exception))


class TestUnwrapReturnsThePayload(unittest.TestCase):
    def test_structured_content_wins(self):
        reply = {"result": {"structuredContent": {"result": {"total_count": 7}},
                            "content": [{"type": "text", "text": "{}"}]}}
        self.assertEqual(plane.unwrap(reply), {"total_count": 7})

    def test_json_text_is_parsed(self):
        reply = {"result": {"content": [{"type": "text", "text": '{"id": "abc"}'}]}}
        self.assertEqual(plane.unwrap(reply), {"id": "abc"})

    def test_prose_comes_back_raw_rather_than_raising(self):
        """The one deliberate exception: a tool answering in prose is reachable."""
        reply = {"result": {"content": [{"type": "text", "text": "no items found"}]}}
        self.assertEqual(plane.unwrap(reply), {"raw": "no items found"})


class TestCallAgainstAFakeTransport(unittest.TestCase):
    def setUp(self):
        self._real = plane.urllib.request.urlopen
        self.addCleanup(setattr, plane.urllib.request, "urlopen", self._real)
        import os
        os.environ.setdefault("PLANE_API_TOKEN", "test-token")
        os.environ.setdefault("PLANE_MCP_URL", "http://127.0.0.1:1/mcp")

    def fake(self, body: str):
        class Response:
            def __enter__(self_inner): return self_inner
            def __exit__(self_inner, *a): return False
            def read(self_inner): return body.encode()
        plane.urllib.request.urlopen = lambda *a, **k: Response()

    def test_an_sse_framed_reply_is_parsed(self):
        self.fake('event: message\ndata: {"result": {"structuredContent": '
                  '{"result": {"total_count": 3}}}}\n\n')
        self.assertEqual(plane.call("personal", "workitem", {"action": "list"}),
                         {"total_count": 3})

    def test_an_unframed_json_reply_is_parsed(self):
        self.fake('{"result": {"content": [{"type": "text", "text": "{\\"ok\\": 1}"}]}}')
        self.assertEqual(plane.call("personal", "workitem", {"action": "list"}),
                         {"ok": 1})

    def test_an_unreachable_gateway_raises_and_does_not_return_empty(self):
        def boom(*a, **k):
            raise OSError("Network is unreachable")
        plane.urllib.request.urlopen = boom
        with self.assertRaises(plane.PlaneError) as caught:
            plane.call("personal", "workitem", {"action": "list"})
        self.assertIn("unreachable", str(caught.exception))

    def test_a_missing_token_raises_before_any_request(self):
        import os
        saved = os.environ.pop("PLANE_API_TOKEN", None)
        self.addCleanup(lambda: os.environ.__setitem__("PLANE_API_TOKEN", saved)
                        if saved else None)
        plane.urllib.request.urlopen = lambda *a, **k: self.fail("should not reach HTTP")
        with self.assertRaises(plane.PlaneError):
            plane.call("personal", "workitem", {"action": "list"})


class TestGateway(unittest.TestCase):
    """Where the gateway is: PLANE_MCP_URL, else the skill value
    `plane.mcpUrl`. With neither, a call raises naming the key and sends
    nothing, rather than reaching for an address built into the skill."""

    def setUp(self):
        import os
        import tempfile
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.values = Path(tmp.name) / "values.json"
        saved = {k: os.environ.get(k) for k in ("PLANE_MCP_URL", "RAVNIX_SKILL_VALUES",
                                                 "PLANE_API_TOKEN")}

        def restore():
            for k, v in saved.items():
                if v is None:
                    os.environ.pop(k, None)
                else:
                    os.environ[k] = v
        self.addCleanup(restore)
        os.environ.pop("PLANE_MCP_URL", None)
        os.environ["RAVNIX_SKILL_VALUES"] = str(self.values)
        os.environ["PLANE_API_TOKEN"] = "test-token"
        self._real = plane.urllib.request.urlopen
        self.addCleanup(setattr, plane.urllib.request, "urlopen", self._real)
        self.seen = []

        def capture(request, **_):
            self.seen.append(request.full_url)
            raise OSError("stop here")
        plane.urllib.request.urlopen = capture

    def test_the_skill_value_names_the_gateway(self):
        self.values.write_text(json.dumps({"plane": {"mcpUrl": "http://plane.example/mcp"}}))
        self.assertEqual(plane.gateway(), "http://plane.example/mcp")
        with self.assertRaises(plane.PlaneError):
            plane.call("home", "workitem", {})
        self.assertEqual(self.seen, ["http://plane.example/mcp"])

    def test_the_variable_wins_over_the_value(self):
        import os
        self.values.write_text(json.dumps({"plane": {"mcpUrl": "http://plane.example/mcp"}}))
        os.environ["PLANE_MCP_URL"] = "http://override.example/mcp"
        self.assertEqual(plane.gateway(), "http://override.example/mcp")

    def test_without_either_a_call_names_the_key_and_sends_nothing(self):
        self.values.write_text("{}")
        self.assertIsNone(plane.gateway())
        with self.assertRaises(plane.PlaneError) as caught:
            plane.call("home", "workitem", {})
        self.assertIn("set `plane.mcpUrl` in your ravnix skill values", str(caught.exception))
        self.assertEqual(self.seen, [])

    def test_no_address_is_built_in(self):
        source = (Path(plane.__file__)).read_text(encoding="utf-8")
        self.assertNotRegex(source, r"https?://\d")


class TestOpenItemsFiltersClientSide(unittest.TestCase):
    """No PQL anywhere: a filter is accepted and silently ignored, so an
    automation built on one works on the wrong set and reports success."""

    def setUp(self):
        self._real_call = plane.call
        self.addCleanup(setattr, plane, "call", self._real_call)
        self.sent = []

    def test_done_and_cancelled_are_dropped(self):
        def fake_call(slug, tool, arguments, timeout=2.0):
            self.sent.append(arguments)
            if tool == "state":
                return {"results": [{"id": "s1", "name": "Todo"},
                                    {"id": "s2", "name": "Done"},
                                    {"id": "s3", "name": "In Progress"}]}
            return {"results": [{"id": "a", "name": "open", "state": "s1"},
                                {"id": "b", "name": "shut", "state": "s2"},
                                {"id": "c", "name": "live", "state": "s3"}]}
        plane.call = fake_call
        got = plane.open_items("personal", "p1")
        self.assertEqual([i["id"] for i in got], ["a", "c"])
        self.assertTrue(all("pql" not in a for a in self.sent))

    def test_a_state_is_open_by_its_group_not_its_name(self):
        # The project role adds "Epic Backlog" and "Epic In Progress" to every
        # personal board. Neither name is one of the three open names, so a
        # name match dropped every project parent off the board in silence.
        def fake_call(slug, tool, arguments, timeout=2.0):
            if tool == "state":
                return {"results": [
                    {"id": "e1", "name": "Epic Backlog", "group": "backlog"},
                    {"id": "e2", "name": "Epic In Progress", "group": "started"},
                    {"id": "s2", "name": "Done", "group": "completed"},
                    {"id": "s4", "name": "Cancelled", "group": "cancelled"}]}
            return {"results": [{"id": "a", "state": "e1"},
                                {"id": "b", "state": "e2"},
                                {"id": "c", "state": "s2"},
                                {"id": "d", "state": "s4"}]}
        plane.call = fake_call
        got = plane.open_items("personal", "p1")
        self.assertEqual([i["id"] for i in got], ["a", "b"])
        self.assertEqual(got[1]["state_name"], "Epic In Progress")


class TestUnwrapDistinguishesEmptyWritesFromFailures(unittest.TestCase):
    """Two shapes measured against the live gateway on 2026-08-23, both of
    which the first version of unwrap got wrong in opposite directions."""

    def test_an_explicit_null_result_is_a_successful_empty_write(self):
        # What a successful delete returns. Raising here made every delete
        # look like a failure and aborted a migration mid-loop.
        reply = {"result": {"content": [], "structuredContent": {"result": None},
                            "isError": False}}
        self.assertEqual(plane.unwrap(reply), {})

    def test_a_prose_error_raises_instead_of_reading_as_success(self):
        # The gateway rejects an unknown argument in prose with isError false,
        # so this used to come back as {"raw": "Error: ..."} and a caller saw
        # success. A migration printed "created" for items never created.
        reply = {"result": {"content": [{"type": "text", "text":
            "Error: action 'create' does not take: state_id. It takes: name, state."}]}}
        with self.assertRaises(plane.PlaneError) as caught:
            plane.unwrap(reply)
        self.assertIn("state_id", str(caught.exception))

    def test_ordinary_prose_still_comes_back_raw(self):
        """The deliberate exception must survive: only prose that announces
        itself as an error is promoted to one."""
        reply = {"result": {"content": [{"type": "text", "text": "no items found"}]}}
        self.assertEqual(plane.unwrap(reply), {"raw": "no items found"})


class TestOpenItemsWalksEveryPage(unittest.TestCase):
    """The gateway caps per_page at 100, measured against the live API on
    2026-08-23: a request for 200 comes back "Input should be less than or
    equal to 100". So a project past 100 items is readable only by following
    the cursor, and the first version of this function never looked at
    next_page_results. It returned the open ones among the first 100 items and
    said nothing, which on a project with a long closed history can be an empty
    board while the work is sitting there.
    """

    def setUp(self):
        self._real_call = plane.call
        self.addCleanup(setattr, plane, "call", self._real_call)
        self.sent = []

    def _fake(self, pages, total=140):
        """pages is a list of (results, next_page_results, next_cursor).

        The last entry repeats forever, so a test can hand out an endless
        supply without writing one.
        """
        seen = {"n": 0}

        def fake_call(slug, tool, arguments, timeout=2.0):
            self.sent.append((tool, arguments))
            if tool == "state":
                return {"results": [{"id": "s1", "name": "Todo"},
                                    {"id": "s2", "name": "Done"}]}
            results, more, cursor = pages[min(seen["n"], len(pages) - 1)]
            seen["n"] += 1
            return {"results": results, "total_count": total,
                    "next_page_results": more, "next_cursor": cursor}
        return fake_call

    def _workitem_calls(self):
        return [args for tool, args in self.sent if tool == "workitem"]

    def test_the_second_page_is_fetched_and_its_open_items_are_included(self):
        plane.call = self._fake([
            ([{"id": "a", "state": "s1"}, {"id": "shut", "state": "s2"}],
             True, "100:0:0"),
            ([{"id": "b", "state": "s1"}], False, ""),
        ])
        got = plane.open_items("personal", "p1")
        self.assertEqual([i["id"] for i in got], ["a", "b"])

    def test_the_cursor_from_the_first_page_is_sent_with_the_second(self):
        plane.call = self._fake([
            ([{"id": "a", "state": "s1"}], True, "100:1:0"),
            ([{"id": "b", "state": "s1"}], False, ""),
        ])
        plane.open_items("personal", "p1")
        calls = self._workitem_calls()
        self.assertEqual(len(calls), 2)
        self.assertNotIn("cursor", calls[0])
        self.assertEqual(calls[1].get("cursor"), "100:1:0")

    def test_a_single_page_is_not_marked_truncated(self):
        plane.call = self._fake([([{"id": "a", "state": "s1"}], False, "")])
        got = plane.open_items("personal", "p1")
        self.assertFalse(got.truncated)

    def test_the_page_bound_stops_the_walk_and_marks_the_result_truncated(self):
        # A runaway board must not make every session start crawl, but a cap
        # that says nothing is the bug this class exists to remove.
        plane.call = self._fake([([{"id": "a", "state": "s1"}], True, "c")])
        got = plane.open_items("personal", "p1", max_pages=3)
        self.assertEqual(len(self._workitem_calls()), 3)
        self.assertTrue(got.truncated)

    def test_more_pages_with_no_cursor_to_follow_is_also_truncated(self):
        # The gateway claims there is more and hands back nothing to advance
        # with. Stopping is right; stopping quietly is not.
        plane.call = self._fake([([{"id": "a", "state": "s1"}], True, "")])
        got = plane.open_items("personal", "p1")
        self.assertEqual(len(self._workitem_calls()), 1)
        self.assertTrue(got.truncated)

    def test_the_total_is_carried_so_a_caller_can_say_what_it_is_not_showing(self):
        plane.call = self._fake([([{"id": "a", "state": "s1"}], False, "")],
                                total=140)
        self.assertEqual(plane.open_items("personal", "p1").total, 140)

    def test_the_state_list_is_read_once_however_many_pages_there_are(self):
        plane.call = self._fake([
            ([{"id": "a", "state": "s1"}], True, "c1"),
            ([{"id": "b", "state": "s1"}], True, "c2"),
            ([{"id": "c", "state": "s1"}], False, ""),
        ])
        plane.open_items("personal", "p1")
        # Both halves matter: three pages were walked, and the state list was
        # not refetched for each of them.
        self.assertEqual(len(self._workitem_calls()), 3)
        self.assertEqual(len([t for t, _ in self.sent if t == "state"]), 1)


class TestOpenElsewhereSurvivesOneBadProject(unittest.TestCase):
    """The sweep runs only as a fallback, when the directory's own project came
    back empty. It must never be able to take the board down with it: a session
    that saw its own project fine deserves that board even if a sibling is
    unreadable."""

    def setUp(self):
        self._real_call = plane.call
        self.addCleanup(setattr, plane, "call", self._real_call)
        self._real_open = plane.open_items
        self.addCleanup(setattr, plane, "open_items", self._real_open)
        self.asked = []

    def test_only_projects_with_open_items_come_back_and_they_carry_counts(self):
        def fake(slug, project_id, timeout=2.0):
            self.asked.append(project_id)
            return {"u-tools": [{"id": "a"}, {"id": "b"}], "u-lab": []}[project_id]
        plane.open_items = fake
        got = plane.open_elsewhere("personal", [{"identifier": "TOOLS", "id": "u-tools"},
                                                {"identifier": "LAB", "id": "u-lab"}])
        self.assertEqual(got, [{"identifier": "TOOLS", "count": 2}])

    def test_a_project_that_raises_is_skipped_rather_than_ending_the_sweep(self):
        def fake(slug, project_id, timeout=2.0):
            if project_id == "u-tools":
                raise plane.PlaneError("gateway unreachable")
            return [{"id": "a"}]
        plane.open_items = fake
        got = plane.open_elsewhere("personal", [{"identifier": "TOOLS", "id": "u-tools"},
                                                {"identifier": "LAB", "id": "u-lab"}])
        self.assertEqual(got, [{"identifier": "LAB", "count": 1}])

    def test_an_empty_project_list_touches_the_network_at_all(self):
        plane.open_items = lambda *a, **k: self.fail("should not reach the gateway")
        self.assertEqual(plane.open_elsewhere("personal", []), [])


class TestNewestCommentIsOrderedInRealTime(unittest.TestCase):
    """Plane stamps comments with a local offset, and Europe/Berlin changes its
    offset twice a year. A string comparison over ISO-8601 inverts across that
    boundary, and this function decides which handoff a resumed session reads.

    Found on 2026-08-23 in another stream's own handoff, migrated onto the
    board that afternoon, which lists it under Tried and failed. The copy here
    had the same shape and nobody had looked.
    """

    def setUp(self):
        self._real_call = plane.call
        self.addCleanup(setattr, plane, "call", self._real_call)

    def _rows(self, rows):
        plane.call = lambda *a, **k: {"results": rows}

    def test_the_later_comment_wins_across_a_clock_change(self):
        # 02:15+01:00 is 01:15 UTC and 02:30+02:00 is 00:30 UTC, so the +01:00
        # row is the newer one, and it sorts earlier as a plain string.
        self._rows([
            {"created_at": "2026-10-25T02:30:00.000000+02:00",
             "comment_html": "<p>before the clocks change</p>"},
            {"created_at": "2026-10-25T02:15:00.000000+01:00",
             "comment_html": "<p>after the clocks change</p>"}])
        self.assertEqual(plane.newest_comment("work", "p1", "i1"),
                         "<p>after the clocks change</p>")

    def test_an_unreadable_stamp_loses_rather_than_raising(self):
        self._rows([{"created_at": "not a timestamp", "comment_html": "<p>junk</p>"},
                    {"created_at": "2026-08-23T18:00:00.000000+02:00",
                     "comment_html": "<p>real</p>"}])
        self.assertEqual(plane.newest_comment("work", "p1", "i1"), "<p>real</p>")

    def test_a_stamp_without_an_offset_does_not_raise(self):
        # Naive and aware datetimes cannot be compared, so a mixed page used to
        # be a TypeError waiting on the gateway's formatting.
        self._rows([{"created_at": "2026-08-23T18:00:00", "comment_html": "<p>naive</p>"},
                    {"created_at": "2026-08-23T19:00:00.000000+02:00",
                     "comment_html": "<p>aware</p>"}])
        self.assertIn(plane.newest_comment("work", "p1", "i1"),
                      ("<p>naive</p>", "<p>aware</p>"))

    def test_no_comments_is_still_none(self):
        self._rows([])
        self.assertIsNone(plane.newest_comment("work", "p1", "i1"))


class TestNewestCommentIsTheNewestHandoff(unittest.TestCase):
    """A later comment that is not a handoff must not stand in for one.

    On 2026-10-17 a correction was posted to TOOLS-77 two minutes after its
    handoff, and a compaction would have resumed from the correction alone.
    """

    def setUp(self):
        self._real_call = plane.call
        self.addCleanup(setattr, plane, "call", self._real_call)

    def _rows(self, rows):
        plane.call = lambda *a, **k: {"results": rows}

    def test_the_marker_is_the_one_already_on_the_board(self):
        # a project's own handoff marker and every handoff it wrote since 2026-09
        # carry this exact string, so it cannot change on one side alone.
        self.assertEqual(plane.HANDOFF_MARKER, "<!-- plane-handoff -->")

    def test_a_later_unmarked_comment_does_not_displace_the_handoff(self):
        self._rows([
            {"created_at": "2026-10-17T10:28:31+02:00",
             "comment_html": plane.HANDOFF_MARKER + "<h3>State</h3>"},
            {"created_at": "2026-10-17T10:30:41+02:00",
             "comment_html": "<p><strong>Correction</strong></p>"}])
        self.assertEqual(plane.newest_comment("personal", "p1", "i1"),
                         plane.HANDOFF_MARKER + "<h3>State</h3>")

    def test_a_chain_with_no_marked_comment_still_resumes_from_the_newest(self):
        # Every handoff written before the marker existed.
        self._rows([
            {"created_at": "2026-10-16T09:00:00+02:00", "comment_html": "<h3>State</h3><p>old</p>"},
            {"created_at": "2026-10-17T09:00:00+02:00", "comment_html": "<h3>State</h3><p>new</p>"}])
        self.assertEqual(plane.newest_comment("personal", "p1", "i1"),
                         "<h3>State</h3><p>new</p>")


class TestOneBudgetReachesEveryCaller(unittest.TestCase):
    """The budget is a measured constant and is worth exactly as much as the
    number of callers that actually spend it.

    It lived as a bare 2.0 in four signatures here and in two more literals a
    module away, which is how a value chosen against a measurement becomes a
    value that half the callers ignore.
    """

    def test_every_transport_default_is_the_constant(self):
        import inspect
        for fn in (plane.call, plane.open_items, plane.open_elsewhere,
                   plane.newest_comment):
            with self.subTest(fn=fn.__name__):
                self.assertEqual(
                    inspect.signature(fn).parameters["timeout"].default,
                    plane.TIMEOUT, f"{fn.__name__} carries its own budget")

    def test_the_budget_clears_the_measured_worst_case_under_concurrency(self):
        # Per-call worst case measured 2026-08-25 was 2.12s against twelve
        # simultaneous session starts, rising about 0.18s per session. Anything
        # at or under that is a budget that false-alarms at a concurrency this
        # machine reaches, which is the whole defect this constant answers.
        self.assertGreater(plane.TIMEOUT, 2.12)
