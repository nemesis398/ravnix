# ravnix-paperless-setup (packages/ravnix-paperless-setup) against a real
# Paperless-ngx: the NixOS module at nixpkgs' version, the one whose number
# the compose project's image takes (pkgs.paperless-ngx.version), with
# PostgreSQL, OCR in deu+eng, the household's filename format and a consume
# folder of its own (the tool's --consume-root; on the NAS it is the
# container's /usr/src/paperless/consume, the default), with one subfolder
# each for alice, bob and the household. The token is the VM's own
# superuser's; the passwords are made up for the test.
#
#   - bad arguments stop the tool with 2 before it calls anything; a wrong
#     token and a dead address stop it with 1, naming the call;
#   - owners without an account: the group, the household user, the
#     fallback workflow and the household's workflow are made, the tool
#     names the missing owners and exits 1; a fallback owner that is no
#     superuser, or no one, stops it with 1 before any change;
#   - the run with every account makes one workflow per owner after the
#     fallback, and the token is on no command line and in no environment
#     of a program it starts; a second run changes nothing and says so; a
#     group, a user and a workflow changed by hand are put back, and a
#     workflow of the tool's for an owner no longer listed is named and
#     left alone;
#   - consume-root: every path filter starts with the consume root, the
#     container's when none is given, and a run with another root rewrites
#     them all;
#   - owner-from-path: a PDF in alice/ is alice's, has OCR text and leaves
#     the folder;
#   - isolation: bob gets 404 on it, on its download, and finds nothing of
#     it in the search, where alice finds it;
#   - tasks-isolation: bob sees no task; with view_paperlesstask he would
#     see alice's (which is why the group does not grant it);
#   - fallback-owner: a PDF in carol/, who has no account, is the fallback
#     owner's, with no grant, and alice and bob neither open nor find it;
#   - nested-path: a PDF in alice/consume/bob/ is alice's, not bob's (a
#     filter not anchored on the root would match both);
#   - web-ui: a member reads and saves their own UI settings;
#   - household: a PDF in haushalt/ is the household's, and both can view
#     and change it;
#   - upload-owner: bob's upload over the API is bob's;
#   - slow-write: a 10-page PDF written in chunks over 20 s is one document
#     of 10 pages, consumed once;
#   - umlaut-title: title `Prüfung Ärztin/Juli` and correspondent
#     `Müller & Söhne` put the archive and original files under
#     alice/YEAR/Müller & Söhne/ in a name with no path separator and no
#     character SMB refuses;
#   - duplicate-two-owners: the same PDF in alice/ and bob/ is two
#     documents, each its dropper's, flagged as duplicates for the admin and
#     invisible to the other;
#   - failure-keeps-file: a corrupt PDF ends in Paperless's failed tasks
#     and stays in the folder, so it is never silently gone;
#   - the household user cannot sign in.
#
# Run it under the shared lock, since other agents share the RAM:
#   flock .superpowers/sdd/2026-11-07-ravnix/vm.lock nix build .#checks.x86_64-linux.services-paperless
{
  self,
  pkgs,
  lib,
  system,
  ...
}:
let
  setup = self.packages.${system}.ravnix-paperless-setup;
  consume = "/srv/paperless/consume";
  adminPassword = "admin-password-of-this-vm-only";

  # The test's PDFs, pages of text as images, so that Paperless runs OCR
  # and writes an archive version. Each holds words of its own for the
  # search; twice.pdf goes into two folders, and corrupt.pdf is no PDF but
  # its header.
  fixtures =
    pkgs.runCommand "paperless-fixtures"
      {
        nativeBuildInputs = [ pkgs.imagemagick ];
        font = "${pkgs.dejavu_fonts}/share/fonts/truetype/DejaVuSans.ttf";
      }
      ''
        mkdir "$out"
        page() {
          printf '%s\n' "(" -size 1240x600 xc:white -annotate +60+200 "$1" -annotate +60+400 "$2" ")"
        }
        pdf() {
          local name=$1
          shift
          mapfile -t pages < <(while (($#)); do page "$1" "$2"; shift 2; done)
          magick -units PixelsPerInch -density 150 -font "$font" -pointsize 56 -fill black \
            "''${pages[@]}" "$out/$name.pdf"
        }
        pdf alice "Bergwerk Rechnung" "Kontoauszug Januar"
        pdf apotheke "Apotheke Quittung" "Arzneimittel Februar"
        pdf haushalt "Gartenhaus Vertrag" "Versicherung Sommer"
        pdf upload "Leuchtturm Bescheid" "Steuer April"
        pdf carol "Windrad Protokoll" "Gemeinde Oktober"
        pdf nested "Leuchtfeuer Planung" "Bergsee Mai"
        pdf twice "Wasserfall Angebot" "Handwerker Herbst"
        args=()
        for i in 1 2 3 4 5 6 7 8 9 10; do args+=("Sternwarte Seite $i" "Teleskop Nummer $i"); done
        pdf slow "''${args[@]}"
        { printf '%%PDF-1.4\n'; head -c 4096 /dev/zero | tr '\0' x; } >"$out/corrupt.pdf"
      '';

  # The group's permissions: the design's six models, and the UI settings,
  # which the web UI needs (the user's own settings only).
  familyPermissions =
    lib.concatMap
      (
        m:
        map (a: "${a}_${m}") [
          "view"
          "add"
          "change"
        ]
      )
      [
        "document"
        "tag"
        "correspondent"
        "documenttype"
        "storagepath"
        "savedview"
        "uisettings"
      ];
in
pkgs.testers.runNixOSTest {
  name = "services-paperless";

  nodes.machine = {
    # OCR of ten pages beside PostgreSQL; the module's own test OOMs at 2 GiB
    # now and then.
    virtualisation.memorySize = 3072;
    virtualisation.cores = 2;

    services.paperless = {
      enable = true;
      consumptionDir = consume;
      passwordFile = pkgs.writeText "paperless-admin-password" adminPassword;
      database.createLocally = true;
      settings = {
        PAPERLESS_OCR_LANGUAGE = "deu+eng";
        PAPERLESS_FILENAME_FORMAT = "{{ owner_username }}/{{ created_year }}/{{ correspondent }}/{{ created }} {{ title }}";
        PAPERLESS_CONSUMER_RECURSIVE = "true";
        PAPERLESS_CONSUMER_SUBDIRS_AS_TAGS = "false";
      };
    };
    # The inboxes: on the NAS each is a person's Eingang, mounted here.
    systemd.tmpfiles.settings."20-paperless-inboxes" =
      lib.genAttrs
        (map (f: "${consume}/${f}") [
          "alice"
          "bob"
          "haushalt"
          # No account and no workflow of its own: the fallback owner's.
          "carol"
        ])
        (_: {
          d = {
            user = "paperless";
            group = "paperless";
            mode = "0755";
          };
        });

    environment.systemPackages = [
      setup
      pkgs.curl
      pkgs.jq
      pkgs.strace
    ];
  };

  testScript = ''
    import json
    import shlex
    import time

    URL = "http://127.0.0.1:28981"
    CONSUME = "${consume}"
    MEDIA = "/var/lib/paperless/media/documents"
    FIX = "${fixtures}"
    FAMILY_PERMISSIONS = sorted(${builtins.toJSON familyPermissions})
    # The tool as the NAS runs it, for the container's consume root (the
    # default); SETUP names the VM's own.
    SETUP_DEFAULT_ROOT = f"ravnix-paperless-setup --url {URL} --token-file /root/token --household haushalt --family-group family --fallback-owner admin"
    SETUP = f"{SETUP_DEFAULT_ROOT} --consume-root {CONSUME}"
    CONTAINER_CONSUME = "/usr/src/paperless/consume"

    def q(*args):
        return " ".join(shlex.quote(str(a)) for a in args)

    def call(token, method, path, body=None, form=None):
        args = ["curl", "-sS", "--max-time", "120", "-o", "/tmp/answer", "-w", "%{http_code}",
                "-X", method, "-H", "Accept: application/json; version=10"]
        if token is not None:
            args += ["-H", f"Authorization: Token {token}"]
        if body is not None:
            args += ["-H", "Content-Type: application/json", "--data-binary", json.dumps(body)]
        for key, value in (form or {}).items():
            if value.startswith("@"):
                args += ["-F", f"{key}={value}"]
            else:
                args += ["--form-string", f"{key}={value}"]
        args.append(URL + path)
        code = int(machine.succeed(q(*args)))
        text = machine.succeed("cat /tmp/answer")
        try:
            data = json.loads(text) if text.strip() else None
        except ValueError:
            data = text
        return code, data

    def api(token, method, path, body=None, form=None, expect=200):
        code, data = call(token, method, path, body, form)
        assert code == expect, f"{method} {path}: expected HTTP {expect}, got {code}: {data}"
        return data

    def results(data):
        return data["results"] if isinstance(data, dict) and "results" in data else data

    def token_for(user, password):
        return api(None, "POST", "/api/token/", form={"username": user, "password": password})["token"]

    def users():
        return {u["username"]: u for u in results(api(admin, "GET", "/api/users/?page_size=100000"))}

    def groups():
        return {g["name"]: g for g in results(api(admin, "GET", "/api/groups/?page_size=100000"))}

    def workflows():
        return {w["name"]: w for w in results(api(admin, "GET", "/api/workflows/?page_size=100000"))}

    def docs(token):
        return results(api(token, "GET", "/api/documents/?page_size=100000&ordering=id"))

    def tasks_of(name):
        tasks = results(api(admin, "GET", "/api/tasks/?page_size=100000"))
        return [t for t in tasks if (t.get("input_data") or {}).get("filename") == name]

    def wait_for(what, check, timeout=600):
        deadline = time.monotonic() + timeout
        while True:
            found = check()
            if found:
                return found
            assert time.monotonic() < deadline, f"timed out waiting for {what}"
            time.sleep(3)

    def consumed(name, count=1):
        """The documents made from a file of that name, once there are count of them."""
        def check():
            failed = [t for t in tasks_of(name) if t["status"] == "failure"]
            assert not failed, f"{name} failed: {failed}"
            found = [d for d in docs(admin) if d["original_file_name"] == name]
            return found if len(found) >= count else None
        return wait_for(f"{name} to be consumed", check)

    def setup_run(owners="alice,bob,haushalt", extra=""):
        status, out = machine.execute(f"{SETUP} --owners {owners} {extra} 2>&1")
        print(out)
        return status, out

    def state():
        return {"groups": groups(), "users": users(), "workflows": workflows()}

    def readable(text):
        return text.casefold()

    machine.wait_for_unit("paperless-web.service")
    machine.wait_for_unit("paperless-consumer.service")
    machine.wait_for_unit("paperless-task-queue.service")
    machine.wait_until_succeeds(f"curl -fsS -o /dev/null {URL}/accounts/login/", timeout=300)
    admin = token_for("admin", "${adminPassword}")
    machine.succeed(f"install -m 600 /dev/null /root/token && printf %s {admin} > /root/token")

    with subtest("bad arguments stop the tool with 2, before it calls anything"):
        machine.succeed(": > /root/empty-token && printf 'a b\\n' > /root/spaced-token")
        full = f"--url {URL} --token-file /root/token --household haushalt --family-group family --fallback-owner admin --owners alice"
        bad = [
            "",
            f"--url {URL} --token-file /root/token --household haushalt --family-group family",
            full.replace("--owners alice", "--owners '''"),
            full.replace("--owners alice", "--owners alice,,bob"),
            full.replace("--owners alice", "--owners 'al ice'"),
            full.replace("--owners alice", "--owners alice,alice"),
            full.replace("--owners alice", "--owners 'a*'"),
            full.replace("--owners alice", "--owners alice,"),
            full.replace("--household haushalt", "--household 'haus/halt'"),
            full.replace("--family-group family", "--family-group '''"),
            full.replace("/root/token", "/root/no-such-token"),
            full.replace("/root/token", "/root/empty-token"),
            full.replace("/root/token", "/root/spaced-token"),
            full.replace(URL, "ftp://127.0.0.1"),
            full.replace(" --fallback-owner admin", ""),
            full.replace("--fallback-owner admin", "--fallback-owner 'ad min'"),
            full + " --what",
            full + " --owners bob",
            full + " --consume-root srv/paperless/consume",
            full + " --consume-root '''",
            full + " --consume-root /",
            full + " --consume-root '/srv/con*sume'",
            full + " --consume-root '/srv/paper less/consume'",
            full + " --consume-root /srv/../consume",
            full + f" --consume-root {CONSUME} --consume-root {CONSUME}",
            "--url",
        ]
        for args in bad:
            status, out = machine.execute(f"ravnix-paperless-setup {args} 2>&1")
            assert status == 2, f"{args!r}: expected 2, got {status}: {out}"
            assert "usage" in out or "ravnix-paperless-setup:" in out, out
        assert "family" not in groups(), "a refused run made the group"

    with subtest("a wrong token and a dead address stop it with 1, naming the call"):
        machine.succeed("printf 0123456789abcdef0123456789abcdef01234567 > /root/wrong-token")
        status, out = machine.execute(
            f"ravnix-paperless-setup --url {URL} --token-file /root/wrong-token --household haushalt --family-group family --fallback-owner admin --owners alice 2>&1"
        )
        print(out)
        assert status == 1 and "/api/" in out and "HTTP 40" in out, out
        status, out = machine.execute(
            "ravnix-paperless-setup --url http://127.0.0.1:9 --token-file /root/token --household haushalt --family-group family --fallback-owner admin --owners alice 2>&1"
        )
        print(out)
        assert status == 1 and "/api/" in out, out
        assert "0123456789abcdef" not in out, out

    with subtest("owners without an account: the rest is made, the tool names them and exits 1"):
        status, out = setup_run()
        assert status == 1, out
        assert "alice" in out and "bob" in out, out
        family = groups()["family"]
        assert sorted(family["permissions"]) == FAMILY_PERMISSIONS, family
        haushalt = users()["haushalt"]
        assert not haushalt["is_active"] and not haushalt["is_staff"] and not haushalt["is_superuser"], haushalt
        names = set(workflows())
        assert names == {"ravnix: fallback owner", "ravnix: household haushalt"}, names

    gid = groups()["family"]["id"]
    for name in ["alice", "bob"]:
        api(admin, "POST", "/api/users/", expect=201,
            body={"username": name, "password": f"{name}-password-of-this-vm", "groups": [gid]})
    alice = token_for("alice", "alice-password-of-this-vm")
    bob = token_for("bob", "bob-password-of-this-vm")
    ids = {name: u["id"] for name, u in users().items()}

    with subtest("a fallback owner that is no superuser, or no one, is refused before any change"):
        before = state()
        for fallback in ["alice", "nobody"]:
            status, out = machine.execute(f"{SETUP.replace('--fallback-owner admin', '--fallback-owner ' + fallback)} --owners alice,bob 2>&1")
            print(out)
            assert status == 1 and fallback in out and "/api/users/" in out, out
        assert state() == before, "a refused run changed something"

    with subtest("with every account it makes one workflow per owner, the token on no command line"):
        status, out = machine.execute(
            f"strace -f -qq -v -s 65536 -e trace=execve -o /tmp/trace {SETUP} --owners alice,bob,haushalt 2>&1"
        )
        print(out)
        assert status == 0, out
        trace = machine.succeed("cat /tmp/trace")
        assert "curl" in trace, "strace saw no curl"
        assert admin not in trace, "the token is on a command line or in an environment"
        flows = workflows()
        assert set(flows) == {"ravnix: fallback owner", "ravnix: owner alice", "ravnix: owner bob", "ravnix: household haushalt"}, set(flows)
        fallback = flows["ravnix: fallback owner"]
        assert fallback["enabled"] and fallback["order"] == 0, fallback
        [trigger] = fallback["triggers"]
        assert trigger["type"] == 1 and trigger["filter_path"] == f"{CONSUME}/*", trigger
        assert [str(s) for s in trigger["sources"]] == ["1"], trigger
        [action] = fallback["actions"]
        assert action["type"] == 1 and action["assign_owner"] == ids["admin"], action
        assert action["assign_view_groups"] == [] and action["assign_change_groups"] == [], action
        assert action["assign_view_users"] == [] and action["assign_change_users"] == [], action
        for owner in ["alice", "bob", "haushalt"]:
            flow = flows[f"ravnix: household {owner}" if owner == "haushalt" else f"ravnix: owner {owner}"]
            # After the fallback, so its owner wins.
            assert flow["enabled"] and flow["order"] == 1, flow
            [trigger] = flow["triggers"]
            assert trigger["type"] == 1, trigger
            assert trigger["filter_path"] == f"{CONSUME}/{owner}/*", trigger
            assert [str(s) for s in trigger["sources"]] == ["1"], trigger
            [action] = flow["actions"]
            assert action["type"] == 1 and action["assign_owner"] == ids[owner], action
            granted = [gid] if owner == "haushalt" else []
            assert action["assign_view_groups"] == granted and action["assign_change_groups"] == granted, action
            assert action["assign_view_users"] == [] and action["assign_change_users"] == [], action

    with subtest("idempotent: a second run changes nothing and says so"):
        before = state()
        status, out = setup_run()
        assert status == 0, out
        assert "nothing to change" in out, out
        assert state() == before, "the second run changed something"

    with subtest("what was changed by hand is put back; an unlisted owner's workflow is left"):
        api(admin, "PATCH", f"/api/groups/{gid}/", body={"permissions": FAMILY_PERMISSIONS + ["delete_document"]})
        api(admin, "PATCH", f"/api/users/{ids['haushalt']}/", body={"is_active": True})
        flow = workflows()["ravnix: owner alice"]
        # Another owner's folder, in the tool's earlier unanchored form.
        trigger = dict(flow["triggers"][0], filter_path="*/consume/bob/*")
        api(admin, "PATCH", f"/api/workflows/{flow['id']}/", body={"triggers": [trigger]})
        fallback = workflows()["ravnix: fallback owner"]
        api(admin, "PATCH", f"/api/workflows/{fallback['id']}/", body={"order": 5})
        stale = api(admin, "POST", "/api/workflows/", expect=201, body={
            "name": "ravnix: owner carol",
            "triggers": [{"type": 1, "sources": [1], "filter_path": "*/consume/carol/*"}],
            "actions": [{"type": 1, "assign_owner": ids["admin"]}],
        })
        status, out = setup_run()
        assert status == 0, out
        assert "family" in out and "haushalt" in out and "ravnix: owner alice" in out, out
        assert "ravnix: owner carol" in out, out
        assert sorted(groups()["family"]["permissions"]) == FAMILY_PERMISSIONS
        assert not users()["haushalt"]["is_active"]
        flows = workflows()
        assert flows["ravnix: owner alice"]["triggers"][0]["filter_path"] == f"{CONSUME}/alice/*", flows
        assert flows["ravnix: fallback owner"]["order"] == 0, flows
        assert "ravnix: owner carol" in flows, "the tool removed a workflow"
        api(admin, "DELETE", f"/api/workflows/{stale['id']}/", expect=204)
        status, out = setup_run()
        assert status == 0 and "nothing to change" in out, out

    def filters():
        return {name: [t["filter_path"] for t in flow["triggers"]] for name, flow in workflows().items()}

    def anchored(root):
        return {
            "ravnix: fallback owner": [f"{root}/*"],
            "ravnix: owner alice": [f"{root}/alice/*"],
            "ravnix: owner bob": [f"{root}/bob/*"],
            "ravnix: household haushalt": [f"{root}/haushalt/*"],
        }

    with subtest("consume-root: the filters start with the root, the container's by default"):
        status, out = machine.execute(f"{SETUP_DEFAULT_ROOT} --owners alice,bob,haushalt 2>&1")
        print(out)
        assert status == 0 and "done: 4 changes" in out, out
        assert filters() == anchored(CONTAINER_CONSUME), filters()
        # The VM's own root again: every filter is rewritten, then nothing.
        status, out = setup_run()
        assert status == 0 and "done: 4 changes" in out, out
        assert filters() == anchored(CONSUME), filters()
        status, out = setup_run()
        assert status == 0 and "nothing to change" in out, out

    with subtest("owner-from-path: a PDF in alice/ is alice's, has OCR text, leaves the folder"):
        machine.succeed(q("cp", f"{FIX}/alice.pdf", f"{CONSUME}/alice/alice.pdf"))
        [doc] = consumed("alice.pdf")
        assert doc["owner"] == ids["alice"], doc
        assert "bergwerk" in readable(doc["content"]), doc["content"]
        machine.wait_until_fails(q("test", "-e", f"{CONSUME}/alice/alice.pdf"), timeout=120)
        alice_doc = doc["id"]

    with subtest("isolation: bob cannot open alice's document or find it"):
        api(alice, "GET", f"/api/documents/{alice_doc}/")
        api(bob, "GET", f"/api/documents/{alice_doc}/", expect=404)
        # The download answers 403 where the document answers 404: refused either way.
        code, _ = call(bob, "GET", f"/api/documents/{alice_doc}/download/")
        assert code in (403, 404), f"bob's download of alice's document: HTTP {code}"
        assert alice_doc not in [d["id"] for d in docs(bob)]
        wait_for("the search to find alice's document for alice",
                 lambda: alice_doc in [d["id"] for d in results(api(alice, "GET", "/api/documents/?query=Bergwerk"))])
        found = api(bob, "GET", "/api/documents/?query=Bergwerk")
        assert found["count"] == 0 and found["results"] == [], found

    with subtest("tasks-isolation: what bob would see of alice's consumption in /api/tasks/"):
        # Without view_paperlesstask, which the group does not grant, bob sees no task.
        api(bob, "GET", "/api/tasks/", expect=403)
        # With it, Paperless 3.3.4 shows a non-staff user every task without an
        # owner, and a task from the consume folder has none: so bob would see
        # alice's. This pins why the group does not grant it; a Paperless that
        # changes this fails here, and the grant can be weighed again.
        api(admin, "PATCH", f"/api/users/{ids['bob']}/", body={"user_permissions": ["view_paperlesstask"]})
        seen = results(api(bob, "GET", "/api/tasks/?page_size=100000"))
        api(admin, "PATCH", f"/api/users/{ids['bob']}/", body={"user_permissions": []})
        leaked = [t for t in seen
                  if (t.get("input_data") or {}).get("filename") == "alice.pdf" or alice_doc in (t.get("related_document_ids") or [])]
        print(f"with view_paperlesstask bob would see {len(leaked)} of alice's tasks: {leaked}")
        assert leaked, "bob sees none of alice's tasks with view_paperlesstask: the group may grant it now"
        assert not users()["bob"]["user_permissions"]

    with subtest("fallback-owner: a PDF in carol/, who has no account, is the fallback owner's"):
        machine.succeed(q("cp", f"{FIX}/carol.pdf", f"{CONSUME}/carol/carol.pdf"))
        [doc] = consumed("carol.pdf")
        assert doc["owner"] == ids["admin"], doc
        perms = api(admin, "GET", f"/api/documents/{doc['id']}/?full_perms=true")["permissions"]
        assert perms == {"view": {"users": [], "groups": []}, "change": {"users": [], "groups": []}}, perms
        wait_for("the search to find carol's document for the admin",
                 lambda: doc["id"] in [d["id"] for d in results(api(admin, "GET", "/api/documents/?query=Windrad"))])
        for token in [alice, bob]:
            api(token, "GET", f"/api/documents/{doc['id']}/", expect=404)
            assert doc["id"] not in [d["id"] for d in docs(token)]
            found = api(token, "GET", "/api/documents/?query=Windrad")
            assert found["count"] == 0 and found["results"] == [], found

    with subtest("nested-path: a PDF in alice/consume/bob/ is alice's, not bob's"):
        machine.succeed(q("install", "-d", "-o", "paperless", "-g", "paperless", f"{CONSUME}/alice/consume/bob"))
        machine.succeed(q("cp", f"{FIX}/nested.pdf", f"{CONSUME}/alice/consume/bob/nested.pdf"))
        [doc] = consumed("nested.pdf")
        assert doc["owner"] == ids["alice"], doc
        machine.wait_until_fails(q("test", "-e", f"{CONSUME}/alice/consume/bob/nested.pdf"), timeout=120)
        api(alice, "GET", f"/api/documents/{doc['id']}/")
        api(bob, "GET", f"/api/documents/{doc['id']}/", expect=404)
        assert doc["id"] not in [d["id"] for d in docs(bob)]

    with subtest("web-ui: a member of the group reads and saves the UI settings"):
        api(alice, "GET", "/api/ui_settings/")
        api(alice, "POST", "/api/ui_settings/", body={"settings": {"dark_mode": {"enabled": "true"}}})
        settings = api(alice, "GET", "/api/ui_settings/")["settings"]
        assert settings.get("dark_mode", {}).get("enabled") == "true", settings
        # One user's settings are not another's.
        assert api(bob, "GET", "/api/ui_settings/")["settings"].get("dark_mode", {}).get("enabled") != "true"

    with subtest("household: a PDF in haushalt/ is visible and editable for both"):
        machine.succeed(q("cp", f"{FIX}/haushalt.pdf", f"{CONSUME}/haushalt/haushalt.pdf"))
        [doc] = consumed("haushalt.pdf")
        assert doc["owner"] == ids["haushalt"], doc
        for token, who in [(alice, "alice"), (bob, "bob")]:
            api(token, "GET", f"/api/documents/{doc['id']}/")
            api(token, "PATCH", f"/api/documents/{doc['id']}/", body={"title": f"Gartenhaus, von {who}"})
        perms = api(admin, "GET", f"/api/documents/{doc['id']}/?full_perms=true")["permissions"]
        assert perms["view"]["groups"] == [gid] and perms["change"]["groups"] == [gid], perms
        assert perms["view"]["users"] == [] and perms["change"]["users"] == [], perms

    with subtest("upload-owner: an API upload by bob is bob's"):
        task = api(bob, "POST", "/api/documents/post_document/", form={"document": f"@{FIX}/upload.pdf"})
        def done():
            mine = [t for t in results(api(admin, "GET", "/api/tasks/?page_size=100000")) if t["task_id"] == task]
            return mine if mine and mine[0]["status"] in ("success", "failure") else None
        [t] = wait_for("bob's upload", done)
        assert t["status"] == "success", t
        [doc_id] = t["related_document_ids"]
        assert api(admin, "GET", f"/api/documents/{doc_id}/")["owner"] == ids["bob"]
        api(alice, "GET", f"/api/documents/{doc_id}/", expect=404)

    with subtest("slow-write: a 10-page PDF written in chunks over 20 s is one document"):
        machine.succeed(
            f"src={FIX}/slow.pdf; dst={CONSUME}/alice/slow.pdf; "
            "size=$(stat -c %s $src); chunk=$(( (size + 9) / 10 )); "
            "for i in 0 1 2 3 4 5 6 7 8 9; do "
            "dd if=$src of=$dst bs=$chunk skip=$i seek=$i count=1 conv=notrunc status=none; sleep 2; "
            "done; cmp $src $dst"
        )
        [doc] = consumed("slow.pdf")
        machine.wait_until_fails(q("test", "-e", f"{CONSUME}/alice/slow.pdf"), timeout=300)
        # Long enough for a second pickup of the same file to show.
        time.sleep(15)
        found = [d for d in docs(admin) if d["original_file_name"] == "slow.pdf"]
        assert len(found) == 1, found
        full = api(admin, "GET", f"/api/documents/{doc['id']}/")
        assert full["page_count"] == 10, full["page_count"]
        assert "sternwarte" in readable(full["content"]), full["content"]
        assert full["owner"] == ids["alice"], full
        runs = tasks_of("slow.pdf")
        assert [t["status"] for t in runs] == ["success"], runs

    with subtest("umlaut-title: the archive file sits under alice/YEAR/Müller & Söhne/"):
        machine.succeed(q("cp", f"{FIX}/apotheke.pdf", f"{CONSUME}/alice/apotheke.pdf"))
        [doc] = consumed("apotheke.pdf")
        assert doc["owner"] == ids["alice"], doc
        corr = api(alice, "POST", "/api/correspondents/", expect=201, body={"name": "Müller & Söhne"})
        api(alice, "PATCH", f"/api/documents/{doc['id']}/", body={"title": "Prüfung Ärztin/Juli", "correspondent": corr["id"]})
        doc = api(alice, "GET", f"/api/documents/{doc['id']}/")
        created = doc["created"][:10]
        for kind in ["archive", "originals"]:
            where = f"{MEDIA}/{kind}/alice/{created[:4]}/Müller & Söhne"
            machine.wait_until_succeeds(q("test", "-d", where), timeout=60)
            entries = machine.succeed(q("find", where, "-mindepth", "1", "-printf", "%y %f\\n")).splitlines()
            print(kind, entries)
            assert len(entries) == 1 and entries[0].startswith("f "), entries
            name = entries[0][2:]
            assert name.startswith(f"{created} Prüfung Ärztin") and "Juli" in name and name.endswith(".pdf"), name
            assert not any(c in name for c in '\\/:*?"<>|'), f"{name} holds a character SMB refuses"

    with subtest("duplicate-two-owners: the same PDF in alice/ and bob/ is two documents"):
        machine.succeed(q("cp", f"{FIX}/twice.pdf", f"{CONSUME}/alice/twice.pdf") + " && " +
                        q("cp", f"{FIX}/twice.pdf", f"{CONSUME}/bob/twice.pdf"))
        found = consumed("twice.pdf", count=2)
        assert len(found) == 2, found
        by_owner = {d["owner"]: d["id"] for d in found}
        assert set(by_owner) == {ids["alice"], ids["bob"]}, found
        a, b = by_owner[ids["alice"]], by_owner[ids["bob"]]
        api(alice, "GET", f"/api/documents/{b}/", expect=404)
        api(bob, "GET", f"/api/documents/{a}/", expect=404)
        assert b not in [d["id"] for d in api(alice, "GET", f"/api/documents/{a}/")["duplicate_documents"]]
        assert a not in [d["id"] for d in api(bob, "GET", f"/api/documents/{b}/")["duplicate_documents"]]
        flagged = [d["id"] for d in api(admin, "GET", f"/api/documents/{a}/")["duplicate_documents"]]
        assert b in flagged, f"not flagged as a duplicate: {flagged}"
        assert [t["status"] for t in tasks_of("twice.pdf")] == ["success", "success"], tasks_of("twice.pdf")

    with subtest("failure-keeps-file: a corrupt PDF is never silently gone"):
        machine.succeed(q("cp", f"{FIX}/corrupt.pdf", f"{CONSUME}/alice/corrupt.pdf"))
        def finished():
            runs = [t for t in tasks_of("corrupt.pdf") if t["status"] in ("success", "failure")]
            return runs or None
        runs = wait_for("the corrupt PDF's task", finished)
        print(runs)
        assert [t["status"] for t in runs] == ["failure"], runs
        assert not [d for d in docs(admin) if d["original_file_name"] == "corrupt.pdf"]
        # Paperless deletes the original only after a document is stored.
        kept = machine.execute(q("test", "-e", f"{CONSUME}/alice/corrupt.pdf"))[0] == 0
        assert kept, "the corrupt PDF failed and is gone from the folder"

    with subtest("the household user cannot sign in"):
        for password in ["", "haushalt", "${adminPassword}"]:
            code, data = call(None, "POST", "/api/token/", form={"username": "haushalt", "password": password})
            assert code == 400, f"{password!r}: HTTP {code}: {data}"
        print(machine.succeed(
            "paperless-manage shell -c " + q(
                "from django.contrib.auth.models import User; u = User.objects.get(username='haushalt'); "
                "assert not u.is_active and u.password == str() and not u.check_password(str()), (u.is_active, u.password); "
                "print('haushalt: inactive, no password')"
            )
        ))
  '';
}
