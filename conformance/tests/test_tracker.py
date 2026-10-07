import base64
import os
import http.client
import json
import socket
import ssl
import struct
from enum import Enum
from http import HTTPStatus
from pathlib import Path
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

from symphony_conformance import runner
from symphony_conformance.driver.process import Process
from symphony_conformance.assets import load, resource
from symphony_conformance.driver.journal import Journal, MAX_JOURNAL_BYTES
from symphony_conformance.driver.tracker import Tracker
from symphony_conformance.driver import tracker as driver
from symphony_conformance.judge import judge, _provider

CHILD_BUDGET = 6
EXPIRY_BUDGET = 10
FLOOD_REQUESTS = 64
DIAGNOSTIC_LIMIT = 16 * 1024
DIAGNOSTIC_TAIL = 2 * 1024
DIAGNOSTIC_PHASES = 8
DIAGNOSTIC_SCALAR = 128
QUERY_DEPTH = 2048
AGGREGATE_REQUESTS = 32
ISSUE_SELECTION = "id identifier title state { name }"
FILTER_QUERY = "query Pick($filter: IssueFilter!) { issues(first: 1, filter: $filter) { nodes { " + ISSUE_SELECTION + " } } }"
OCAML_ISSUES_QUERY = """query SymphonyIssues($filter: IssueFilter!, $after: String, $pageSize: Int!) {
  issues(filter: $filter, after: $after, first: $pageSize, orderBy: createdAt, includeArchived: false) {
    nodes {
      id identifier title description priority branchName url createdAt updatedAt
      state { name } assignee { id } project { id slugId }
      labels(first: $pageSize) { nodes { id name } pageInfo { hasNextPage endCursor } }
      inverseRelations(first: $pageSize) {
        nodes { id type issue { id identifier state { name } } relatedIssue { id } }
        pageInfo { hasNextPage endCursor }
      }
    }
    pageInfo { hasNextPage endCursor }
  }
}"""


class Input(Enum):
    HEADERS = "headers"
    BODY = "body"


class Action(Enum):
    CLOSE = "close"
    EXPIRE = "expire"


class State(Enum):
    ACTIVE = "active"
    TERMINAL = "terminal"


class TrackerTest(unittest.TestCase):
    def test_terminal_projection(self):
        corpus = load("corpus/lifecycle.json")
        selections = [
            "nodes { id }",
            "nodes { id identifier state { name } }",
            "nodes { id title state { name } }",
            "nodes { id identifier title state { id } }",
            "nodes @skip(if: true) { " + ISSUE_SELECTION + " }",
            "nodes { id identifier title state @skip(if: true) { name } }",
            "nodes { id identifier title state { name @include(if: false) } }",
            "nodes { id: __typename identifier title state { name } }",
            "nodes { id identifier title state: project { name: slugId } }",
            "nodes { ... on Issue { id identifier state { name } } }",
            "nodes { " + ISSUE_SELECTION + " unknown }",
            "nodes { id identifier title state { name unknown } }",
            "nodes { " + ISSUE_SELECTION + " project }",
            "nodes { " + ISSUE_SELECTION + " description { name } }",
            "nodes { " + ISSUE_SELECTION + " unknown @skip(if: true) }",
        ]
        bodies = [{"query": "query Pick($filter: IssueFilter!) { issues(first: 1, filter: $filter) { " + selection + " } }",
                   "variables": {"filter": {"id": {"in": [corpus["issue_id"]]}}}}
                  for selection in selections]
        bodies.extend([
            {"query": "query Pick($filter: IssueFilter!) { issues(first: 1, filter: $filter) @skip(if: true) { nodes { " + ISSUE_SELECTION + " } } }",
             "variables": bodies[0]["variables"]},
            {"query": "query Pick($filter: IssueFilter!) { issues(first: 1, filter: $filter) { nodes { ...Selected } } } fragment Selected on Issue { id identifier state { name } }",
             "variables": bodies[0]["variables"]},
            {"query": "query Pick($filter: IssueFilter!, $visible: Boolean!) { issues(first: 1, filter: $filter) { nodes { id identifier title state @include(if: $visible) { name } } } }",
             "variables": {**bodies[0]["variables"], "visible": False}},
        ])
        self.query_requests(bodies, HTTPStatus.BAD_REQUEST, State.TERMINAL)

    def test_effective_projection(self):
        corpus = load("corpus/lifecycle.json")
        expected = {"id": corpus["issue_id"], "identifier": corpus["issue_identifier"],
                    "title": corpus["issue_title"], "state": {"name": corpus["terminal_state"]}}
        selections = [
            ("nodes { " + ISSUE_SELECTION + " }", "", expected),
            ("nodes { ...Selected }", "fragment Selected on Issue { " + ISSUE_SELECTION + " }", expected),
            ("nodes { ... on Issue { " + ISSUE_SELECTION + " } }", "", expected),
            ("nodes @include(if: true) { " + ISSUE_SELECTION + " }", "", expected),
            ("nodes { id identifier title state @skip(if: false) { name } }", "", expected),
            ("nodes { id identifier title state @include(if: $visible) { name } }", "", expected),
            ("nodes { id id identifier title state { name } state { name } }", "", expected),
            ("nodes: nodes { id: id identifier title state: state { name: name } }", "", expected),
            ("nodes { " + ISSUE_SELECTION + " renamed: description }", "", {**expected, "renamed": None}),
            ("nodes { " + ISSUE_SELECTION + " workspace: project { slugId } }", "",
             {**expected, "workspace": {"slugId": corpus["project"]}}),
        ]
        bodies = [{"query": "query Pick($filter: IssueFilter!" + (", $visible: Boolean = true" if "$visible" in selection else "")
                             + ") { issues(first: 1, filter: $filter) { " + selection + " } } " + fragment,
                   "variables": {"filter": {"id": {"in": [corpus["issue_id"]]}}}}
                  for selection, fragment, _ in selections]
        bodies.extend([
            {"query": "query Pick($filter: IssueFilter!) { ...Selected } fragment Selected on Query { issues(first: 1, filter: $filter) { nodes { " + ISSUE_SELECTION + " } } }",
             "variables": bodies[0]["variables"]},
            {"query": "query Pick($filter: IssueFilter!) { ... on Query { issues(first: 1, filter: $filter) { nodes { " + ISSUE_SELECTION + " } } } }",
             "variables": bodies[0]["variables"]},
        ])
        # Valid GraphQL modifiers may expose required paths; syntax alone is not a defect.
        payloads = self.query_requests(bodies, HTTPStatus.OK, State.TERMINAL)
        nodes = [value for _, _, value in selections] + [expected, expected]
        for body, payload, node in zip(bodies, payloads, nodes, strict=True):
            with self.subTest(query=body["query"]):
                self.assertEqual(payload, {"data": {"issues": {"nodes": [node]}}})

    def test_supported_projection(self):
        from symphony_conformance.control import CANDIDATES_QUERY, IDS_QUERY

        corpus = load("corpus/lifecycle.json")
        bodies = [
            {"query": CANDIDATES_QUERY, "variables": {
                "scope": {"project": {"slugId": {"eq": corpus["project"]}}}, "pageWindow": 2}},
            {"query": IDS_QUERY, "variables": {"opaqueKeys": [corpus["issue_id"]], "pageWindow": 2}},
            {"query": OCAML_ISSUES_QUERY, "variables": {
                "filter": {"id": {"in": [corpus["issue_id"]]}}, "after": None, "pageSize": 2}},
        ]
        payloads = self.query_requests(bodies, HTTPStatus.OK, State.TERMINAL)
        for payload, key in zip(payloads, ("chosen", "chosen", "issues"), strict=True):
            nodes = payload["data"][key]["nodes"]
            self.assertEqual(len(nodes), 1)
            self.assertEqual(nodes[0]["id"], corpus["issue_id"])
            self.assertEqual(nodes[0]["state"]["name"], corpus["terminal_state"])

    def test_required_aliases(self):
        corpus = load("corpus/lifecycle.json")
        selections = [
            ("items: nodes { key: id code: identifier caption: title current: state { value: name } }",
             {"items": [{"key": corpus["issue_id"], "code": corpus["issue_identifier"],
                          "caption": corpus["issue_title"],
                          "current": {"value": corpus["terminal_state"]}}]}),
            ("nodes { id identifier title current: state { name } }",
             {"nodes": [{"id": corpus["issue_id"], "identifier": corpus["issue_identifier"],
                          "title": corpus["issue_title"],
                          "current": {"name": corpus["terminal_state"]}}]}),
            ("nodes { id identifier title state { value: name } }",
             {"nodes": [{"id": corpus["issue_id"], "identifier": corpus["issue_identifier"],
                          "title": corpus["issue_title"],
                          "state": {"value": corpus["terminal_state"]}}]}),
            ("nodes { id identifier: title title: identifier state { name } }",
             {"nodes": [{"id": corpus["issue_id"], "identifier": corpus["issue_title"],
                          "title": corpus["issue_identifier"],
                          "state": {"name": corpus["terminal_state"]}}]}),
        ]
        bodies = [{"query": "query Pick($filter: IssueFilter!) { chosen: issues(first: 1, filter: $filter) { "
                             + selection + " } }",
                   "variables": {"filter": {"id": {"in": [corpus["issue_id"]]}}}}
                  for selection, _ in selections]
        payloads = self.query_requests(bodies, HTTPStatus.OK, State.TERMINAL)
        self.assertEqual(payloads, [{"data": {"chosen": expected}} for _, expected in selections])

    def test_split_aliases(self):
        selections = [
            "one: nodes { id identifier } two: nodes { title state { name } }",
            "one: nodes { id identifier title state { id } } two: nodes { state { name } }",
            "items: nodes { key: id code: identifier caption: title current: state { value: name @skip(if: true) } }",
            "items: nodes { key: __typename code: identifier caption: title current: state { value: name } }",
            "items: nodes { key: id code: identifier caption: title current: project { value: slugId } }",
        ]
        bodies = [{"query": "{ issues(first: 1, filter: {}) { " + selection + " } }"}
                  for selection in selections]
        bodies.append({"query": "{ one: issues(first: 1, filter: {}) { nodes { id identifier } } "
                                "two: issues(first: 1, filter: {id: {in: []}}) { nodes { title state { name } } } }"})
        self.query_requests(bodies, HTTPStatus.BAD_REQUEST)

    def test_alias_replay(self):
        script = """
import json
import os
from pathlib import Path
import sys
import urllib.request
from symphony_conformance.assets import decode
from symphony_conformance.control import Control, SELECTION, TRACKER_BODY_LIMIT, TRACKER_SECRET_NAME

class AliasedControl(Control):
    def _query(self, query, operation, variables):
        query = query.replace("nodes {", "items: nodes {").replace(
            SELECTION, "key: id code: identifier caption: title current: state { value: name }")
        raw = json.dumps({"query": query, "operationName": operation, "variables": variables}).encode()
        request = urllib.request.Request(self._plan["endpoint"], data=raw, method="POST",
            headers={"Authorization": os.environ[TRACKER_SECRET_NAME], "Content-Type": "application/json"})
        with self._opener.open(request, timeout=2) as response:
            payload = decode(response.read(TRACKER_BODY_LIMIT + 1))
        return [{"id": node["key"], "identifier": node["code"], "title": node["caption"],
                 "state": {"name": node["current"]["value"]}}
                for node in payload["data"]["chosen"]["items"]]

path = Path(sys.argv[1])
AliasedControl(decode(path.read_bytes()), path).run()
"""
        rows, report = self._run_candidate(script)
        self.assertEqual(report["harness"], {"status": "pass", "errors": []})
        self.assertEqual(report["case"]["status"], "pass")
        responses = [row for row in rows if row["kind"] == "provider.response"]
        self.assertTrue(responses)
        for row in responses:
            payload = json.loads(base64.b64decode(row["data"]["body"], validate=True))
            projection = payload["data"]["chosen"]
            self.assertIn("items", projection)
            self.assertNotIn("nodes", projection)

    def test_aggregate_body_budget(self):
        script = """
import http.client
import json
import os
from pathlib import Path
import ssl
import sys
from http import HTTPStatus
from symphony_conformance.assets import decode
from symphony_conformance.control import Control, SELECTION, TRACKER_SECRET_NAME
from symphony_conformance.driver.tracker import MAX_BODY

path = Path(sys.argv[1])
plan = decode(path.read_bytes())
Control(plan, path).run()
body = {"query": "{ issues(first: 1, filter: {}) { nodes { " + SELECTION + " } } }", "padding": ""}
body["padding"] = "x" * (MAX_BODY - len(json.dumps(body).encode()))
raw = json.dumps(body).encode()
assert len(raw) == MAX_BODY
context = ssl.create_default_context(cafile=plan["ca"])
counts = {"attempted": int(sys.argv[2]), "accepted": 0, "rejected": 0, "closed": 0}
for _ in range(counts["attempted"]):
    client = http.client.HTTPSConnection(plan["endpoint"].split("/")[2], timeout=2, context=context)
    try:
        client.request("POST", "/graphql", raw, {"Authorization": os.environ[TRACKER_SECRET_NAME]})
        response = client.getresponse()
        response.read()
        if response.status == HTTPStatus.OK:
            counts["accepted"] += 1
        elif response.status == HTTPStatus.BAD_REQUEST:
            counts["rejected"] += 1
        else:
            raise RuntimeError("Unexpected fixture status: " + str(response.status))
    except (BrokenPipeError, ConnectionResetError, ssl.SSLEOFError, http.client.RemoteDisconnected):
        # Header admission can close TLS before an eager body write completes.
        counts["closed"] += 1
    finally:
        client.close()
print(json.dumps({"event": "fixture_provider_budget", **counts}), flush=True)
"""
        rows, report = self._run_candidate(script, str(AGGREGATE_REQUESTS))
        self.assertEqual(report["harness"], {"status": "pass", "errors": []})
        self.assertEqual(report["case"]["status"], "fail")
        limits = [row for row in rows if row["kind"] == "provider.evidence_limit"]
        summaries = [row for row in rows if row["kind"] == "provider.evidence_summary"]
        self.assertEqual(len(limits), 1)
        self.assertEqual(len(summaries), 1)
        omitted = summaries[0]["data"]["rejected_requests"]
        self.assertIs(type(omitted), int)
        self.assertGreater(omitted, 0)
        from symphony_conformance.driver.tracker import MAX_BODY
        bodies = [base64.b64decode(row["data"]["body"], validate=True)
                  for row in rows if row["kind"] == "provider.request"]
        retained = [body for body in bodies if len(body) == MAX_BODY]
        self.assertEqual(len(retained) + omitted, AGGREGATE_REQUESTS)
        self.assertTrue(retained)
        probes = [row["data"] for row in rows if row["kind"] == "candidate.observation"
                  and row["data"].get("event") == "fixture_provider_budget"]
        self.assertEqual(len(probes), 1)
        probe = probes[0]
        self.assertEqual(set(probe), {"event", "attempted", "accepted", "rejected", "closed"})
        self.assertTrue(all(type(probe[name]) is int and probe[name] >= 0
                            for name in ("attempted", "accepted", "rejected", "closed")))
        self.assertEqual(probe["attempted"], AGGREGATE_REQUESTS)
        self.assertEqual(probe["accepted"] + probe["rejected"] + probe["closed"], AGGREGATE_REQUESTS)
        self.assertEqual(probe["accepted"], len(retained))
        self.assertEqual(probe["rejected"] + probe["closed"], omitted)
        expected = {"query": "{ issues(first: 1, filter: {}) { nodes { " + ISSUE_SELECTION + " } } }",
                    "padding": ""}
        expected["padding"] = "x" * (MAX_BODY - len(json.dumps(expected).encode()))
        self.assertEqual(retained, [json.dumps(expected).encode()] * len(retained))
        failures = [item for item in report["case"]["assertions"] if item["status"] == "fail"]
        self.assertTrue(any(limits[0]["seq"] in item["evidence_seq"] for item in failures), failures)

    def _run_candidate(self, script, *arguments):
        processes = []

        class OwnedProcess(Process):
            def __init__(self, *args, **kwargs):
                super().__init__(*args, **kwargs)
                processes.append(self)

        with tempfile.TemporaryDirectory() as directory:
            bundle = Path(directory) / "evidence"

            def launch(_profile, _candidate, _workflow, _ca, plan):
                optimized = ["-" + "O" * sys.flags.optimize] if sys.flags.optimize else []
                return [sys.executable, *optimized, "-c", script, str(plan), *arguments]

            with patch.object(runner.profiles, "launch", side_effect=launch), \
                    patch.object(runner, "Process", OwnedProcess):
                runner.run(bundle, "scripted")
            manifest = json.loads((bundle / "manifest.json").read_text())
            receipt = json.loads((bundle / "process.json").read_text())
            rows = [json.loads(line) for line in (bundle / "events.jsonl").read_text().splitlines()]
            snapshot = processes[0].snapshot()
            self.assertTrue(manifest["completed"])
            self.assertEqual(manifest["harness_errors"], [])
            self.assertLessEqual((bundle / "events.jsonl").stat().st_size, MAX_JOURNAL_BYTES)
            self.assertTrue(snapshot["closed"])
            self.assertTrue(snapshot["reaped"])
            self.assertEqual(snapshot["eof"], ("stderr", "stdout"))
            self.assertTrue(receipt["closed"])
            self.assertTrue(receipt["reaped"])
            self.assertEqual(receipt["returncode"], 0,
                             (bundle / "stderr.bin").read_bytes()[-DIAGNOSTIC_TAIL:].decode("utf-8", "replace"))
            self.assertEqual(snapshot["failures"], ())
            for pid in (snapshot["pid"], snapshot["guard_pid"]):
                with self.assertRaises(ProcessLookupError):
                    os.kill(pid, 0)
            closures = [row for row in rows if row["kind"] == "provider.closed"]
            self.assertEqual(len(closures), 1)
            self.assertEqual(closures[0]["data"], {"status": "ok", "errors": []})
            return rows, judge(bundle)

    def test_linear_type_names(self):
        corpus = load("corpus/lifecycle.json")
        expected = {"id": corpus["issue_id"], "identifier": corpus["issue_identifier"],
                    "title": corpus["issue_title"], "state": {"name": corpus["terminal_state"]}}
        operands = [
            ("IssueIDComparator!", "id: $operand", {"in": [corpus["issue_id"]]}, [expected]),
            ("IDComparator!", "state: {id: $operand}", {"in": []}, []),
            ("EntityIdentifierIDComparator!", "project: {id: $operand}", {"in": []}, []),
            ("StringComparator!", "state: {name: $operand}",
             {"eqIgnoreCase": corpus["terminal_state"].lower()}, [expected]),
            ("NullableProjectFilter!", "project: $operand",
             {"slugId": {"eq": corpus["project"]}}, [expected]),
            ("WorkflowStateFilter!", "state: $operand",
             {"name": {"in": [corpus["terminal_state"]]}}, [expected]),
        ]
        bodies = [{"query": "query Pick($operand: " + name + ") { issues(first: 1, filter: {"
                             + predicate + "}) { nodes { " + ISSUE_SELECTION + " } } }",
                   "variables": {"operand": value}} for name, predicate, value, _ in operands]
        bodies.extend([
            {"query": "query Pick($order: PaginationOrderBy!) { issues(first: 1, filter: {}, orderBy: $order) { nodes { " + ISSUE_SELECTION + " } } }",
             "variables": {"order": "updatedAt"}},
            {"query": "query Pick($order: PaginationOrderBy = createdAt) { issues(first: 1, filter: {}, orderBy: $order) { nodes { " + ISSUE_SELECTION + " } } }"},
        ])
        # Named operands must use Linear's types, even within the closed subset.
        payloads = self.query_requests(bodies, HTTPStatus.OK, State.TERMINAL)
        nodes = [value for _, _, _, value in operands] + [[expected], [expected]]
        for body, payload, result in zip(bodies, payloads, nodes, strict=True):
            with self.subTest(query=body["query"]):
                self.assertEqual(payload, {"data": {"issues": {"nodes": result}}})
        self.filter_requests([
            {"id": {"eqIgnoreCase": corpus["issue_id"]}},
            {"project": {"id": {"eqIgnoreCase": "missing-project"}}},
            {"state": {"id": {"eqIgnoreCase": "missing-state"}}},
            {"state": {"slugId": {"eq": "missing-state"}}},
        ], HTTPStatus.BAD_REQUEST)

    def test_linear_fragment_names(self):
        corpus = load("corpus/lifecycle.json")
        body = {"query": """query Pick($filter: IssueFilter!) {
            issues(first: 1, filter: $filter) { ...Issues }
        }
        fragment Issues on IssueConnection { nodes { ...Selected } }
        fragment Selected on Issue {
            id identifier title state { ...State } assignee { ...Assigned }
            project { ...ProjectFields } labels { ...Labels }
            inverseRelations { ...Relations }
        }
        fragment State on WorkflowState { name }
        fragment Assigned on User { id }
        fragment ProjectFields on Project { slugId }
        fragment Labels on IssueLabelConnection { nodes { ...LabelFields } }
        fragment LabelFields on IssueLabel { id name }
        fragment Relations on IssueRelationConnection { nodes { ...RelationFields } }
        fragment RelationFields on IssueRelation { id type }
        """, "variables": {"filter": {"id": {"in": [corpus["issue_id"]]}}}}
        payloads = self.query_requests([body], HTTPStatus.OK, State.TERMINAL)
        expected = {"id": corpus["issue_id"], "identifier": corpus["issue_identifier"],
                    "title": corpus["issue_title"], "state": {"name": corpus["terminal_state"]},
                    "assignee": None, "project": {"slugId": corpus["project"]},
                    "labels": {"nodes": []}, "inverseRelations": {"nodes": []}}
        self.assertEqual(payloads, [{"data": {"issues": {"nodes": [expected]}}}])

    def test_bad_logical_values(self):
        filters = [
            {"or": [None]}, {"and": [[]]}, {"or": [5]}, {"and": ["bad"]},
            {"and": [False]}, {"or": [{"and": [None]}]},
            {"and": [{"or": [["bad"]]}]},
        ]
        self.filter_requests(filters, HTTPStatus.BAD_REQUEST)

    def test_deep_query(self):
        from symphony_conformance.driver.tracker import MAX_BODY

        query = "{ issues(first: 1, filter: {}) { nodes { " + "state { " * QUERY_DEPTH
        body = {"query": query + "name" + " }" * QUERY_DEPTH + " } } }"}
        self.assertLess(len(json.dumps(body).encode()), MAX_BODY)
        self.query_requests([body], HTTPStatus.BAD_REQUEST)

    def test_hidden_filter_errors(self):
        corpus = load("corpus/lifecycle.json")
        hit = {"id": {"eq": corpus["issue_id"]}}
        missing_id = corpus["issue_id"] + "-missing"
        miss = {"id": {"eq": missing_id}}
        invalid = [
            {"id": {"guess": "bad"}}, {"or": [None]},
            {"project": {"name": None}}, {"state": {"name": {"eq": None}}},
            {"project": {"guess": {"eq": "bad"}}},
        ]
        filters = [{"or": [hit, value]} for value in invalid]
        filters.extend({"and": [miss, value]} for value in invalid)
        filters.extend([
            {"id": {"eq": missing_id, "guess": "bad"}},
            {"id": {"eq": missing_id, "in": [None]}},
            {"id": {"eq": missing_id, "eqIgnoreCase": None}},
            {"id": {"eq": missing_id}, "guess": {}},
            {"state": {"name": {"eq": "missing-state"}, "guess": {"eq": "bad"}}},
        ])
        self.filter_requests(filters, HTTPStatus.BAD_REQUEST)

    def test_bad_comparison_values(self):
        filters = [{"id": {operator: value}} for operator, value in (
            ("eq", None), ("eq", 5), ("eq", False), ("eq", []), ("eq", {}),
            ("eqIgnoreCase", None), ("eqIgnoreCase", 5),
            ("in", None), ("in", "bad"), ("in", ["valid", None]),
        )]
        filters.extend([{"id": {}}, {"project": {"name": {}}}])
        self.filter_requests(filters, HTTPStatus.BAD_REQUEST)

    def test_valid_logical_filters(self):
        corpus = load("corpus/lifecycle.json")
        hit = {"id": {"eq": corpus["issue_id"]}}
        miss = {"id": {"eq": corpus["issue_id"] + "-missing"}}
        payloads = self.filter_requests([
            {"or": [hit, miss]}, {"and": [miss, hit]},
            {"and": [hit, {}]}, {"id": {"in": []}},
            {}, {"project": {}}, {"state": {}},
        ], HTTPStatus.OK)
        self.assertEqual([[node["id"] for node in value["data"]["issues"]["nodes"]]
                          for value in payloads], [[corpus["issue_id"]], [], [corpus["issue_id"]], [],
                              [corpus["issue_id"]], [corpus["issue_id"]], [corpus["issue_id"]]])

    def filter_requests(self, filters, status):
        bodies = [{"query": FILTER_QUERY, "variables": {"filter": query}} for query in filters]
        return self.query_requests(bodies, status)

    def query_requests(self, bodies, status, state=State.ACTIVE):
        with tempfile.TemporaryDirectory() as directory:
            corpus = load("corpus/lifecycle.json")
            journal = Journal(Path(directory))
            tracker = Tracker(corpus, journal, str(resource("tls/server.pem")),
                              str(resource("tls/server.key")))
            authority = tracker.endpoint.split("/")[2]
            context = ssl.create_default_context(cafile=str(resource("tls/ca.pem")))
            payloads = []
            statuses = []
            wire_responses = []
            try:
                if state is State.TERMINAL:
                    tracker.terminal()
                for request in bodies:
                    with self.subTest(request=request):
                        client = http.client.HTTPSConnection(authority, timeout=2, context=context)
                        try:
                            body = json.dumps(request)
                            client.request("POST", "/graphql", body,
                                           {"Authorization": corpus["fake_secret"], "Content-Type": "application/json"})
                            response = client.getresponse()
                            raw_response = response.read()
                            wire_responses.append(raw_response)
                            payload = json.loads(raw_response)
                            payloads.append(payload)
                            statuses.append(response.status)
                            self.assertEqual(response.status, status)
                            if status == HTTPStatus.BAD_REQUEST:
                                self.assertTrue(payload.get("errors"))
                                self.assertNotIn("data", payload)
                        finally:
                            client.close()
                with self.subTest(stage="fixture-health"):
                    self.assertEqual(tracker.errors(), [])
            finally:
                tracker.close()
                journal.close()
            with self.subTest(stage="fixture-closure"):
                self.assertEqual(journal.rows("provider.closed")[0]["data"]["status"], "ok")
            requests = journal.rows("provider.request")
            responses = journal.rows("provider.response")
            self.assertEqual(len(requests), len(bodies))
            self.assertEqual(len(responses), len(bodies))
            self.assertEqual([base64.b64decode(row["data"]["body"], validate=True)
                              for row in requests], [json.dumps(body).encode() for body in bodies])
            self.assertEqual([row["data"]["status"] for row in responses], statuses)
            self.assertEqual([base64.b64decode(row["data"]["body"], validate=True)
                              for row in responses], wire_responses)
            return payloads

    def test_bounded_rejections(self):
        with tempfile.TemporaryDirectory() as directory:
            corpus = load("corpus/lifecycle.json")
            journal = Journal(Path(directory))
            tracker = Tracker(corpus, journal, str(resource("tls/server.pem")),
                              str(resource("tls/server.key")))
            authority = tracker.endpoint.split("/")[2]
            context = ssl.create_default_context(cafile=str(resource("tls/ca.pem")))
            body = json.dumps({"query": "?" + "x" * 8192})
            try:
                for _ in range(FLOOD_REQUESTS):
                    client = http.client.HTTPSConnection(authority, timeout=2, context=context)
                    client.request("POST", "/graphql", body,
                                   {"Authorization": corpus["fake_secret"]})
                    response = client.getresponse()
                    self.assertEqual(response.status, HTTPStatus.BAD_REQUEST)
                    response.read()
                    client.close()
                valid = json.dumps({"query": "{issues{nodes{id}}}"})
                cases = (("POST", "/wrong", corpus["fake_secret"]),
                         ("POST", "/graphql", "wrong-fake-credential"),
                         ("GET", "/graphql", corpus["fake_secret"]))
                for method, target, credential in cases:
                    client = http.client.HTTPSConnection(authority, timeout=2, context=context)
                    client.request(method, target, valid, {"Authorization": credential})
                    response = client.getresponse()
                    self.assertEqual(response.status, HTTPStatus.BAD_REQUEST)
                    response.read()
                    client.close()
                self.assertEqual(tracker.errors(), [])
            finally:
                tracker.close()
                journal.close()
            summaries = journal.rows("provider.evidence_summary")
            omitted = summaries[0]["data"]["omitted_requests"] if summaries else 0
            self.assertEqual(len(journal.rows("provider.request")) + omitted, FLOOD_REQUESTS + len(cases))
            self.assertEqual(journal.rows("provider.closed")[0]["data"]["status"], "ok")

    def test_bounded_recorder_errors(self):
        with tempfile.TemporaryDirectory() as directory:
            corpus = load("corpus/lifecycle.json")
            journal = Journal(Path(directory))
            tracker = Tracker(corpus, journal, str(resource("tls/server.pem")),
                              str(resource("tls/server.key")))
            authority = tracker.endpoint.split("/")[2]
            context = ssl.create_default_context(cafile=str(resource("tls/ca.pem")))
            emit = journal.emit

            def broken(kind, *args):
                if kind == "provider.request":
                    raise RuntimeError("recorder failed: " + "x" * 8192)
                return emit(kind, *args)

            try:
                with patch.object(journal, "emit", broken):
                    for _ in range(FLOOD_REQUESTS):
                        client = http.client.HTTPSConnection(authority, timeout=2, context=context)
                        client.request("POST", "/graphql", '{}',
                                       {"Authorization": corpus["fake_secret"]})
                        response = client.getresponse()
                        self.assertEqual(response.status, HTTPStatus.BAD_REQUEST)
                        response.read()
                        client.close()
                self.assertLess(len(json.dumps(tracker.errors())), DIAGNOSTIC_LIMIT)
                self.assertTrue(tracker.errors())
            finally:
                tracker.close()
                journal.close()
            self.assertEqual(journal.rows("provider.closed")[0]["data"]["status"], "error")

    def test_closed_tls_client(self):
        with tempfile.TemporaryDirectory() as directory:
            corpus = load("corpus/lifecycle.json")
            journal = Journal(Path(directory))
            tracker = Tracker(corpus, journal, str(resource("tls/server.pem")),
                              str(resource("tls/server.key")))
            context = ssl.create_default_context(cafile=str(resource("tls/ca.pem")))
            client = http.client.HTTPSConnection(tracker.endpoint.split("/")[2], timeout=2, context=context)
            held, release, finished = (threading.Event() for _ in range(3))
            original_select = driver.select
            original_request = tracker._request

            def select(raw):
                selection = original_select(raw)
                project = selection["project"]

                def blocked(connection):
                    held.set()
                    if not release.wait(CHILD_BUDGET):
                        raise TimeoutError("TLS regression projection was not released")
                    return project(connection)

                selection["project"] = blocked
                return selection

            def request(handler):
                try:
                    return original_request(handler)
                finally:
                    finished.set()

            raw = json.dumps({"query": "{ issues(first: 1, filter: {}) { nodes { "
                                      + ISSUE_SELECTION + " } } }"}).encode()
            try:
                with patch.object(driver, "select", select), patch.object(tracker, "_request", request):
                    client.request("POST", "/graphql", raw, {"Authorization": corpus["fake_secret"]})
                    self.assertTrue(held.wait(CHILD_BUDGET), "Tracker did not reach response projection")
                    admitted = journal.rows("provider.request")
                    self.assertEqual(len(admitted), 1)
                    self.assertEqual(base64.b64decode(admitted[0]["data"]["body"], validate=True), raw)
                    # Reset the actual TLS peer after admission and before response I/O.
                    client.sock.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
                    client.sock.shutdown(socket.SHUT_RDWR)
                    client.close()
                    release.set()
                    self.assertTrue(finished.wait(CHILD_BUDGET), "Tracker response handler did not finish")
                self.assertEqual(tracker.errors(), [])
            finally:
                release.set()
                client.close()
                tracker.close()
                journal.close()
            disconnects = journal.rows("provider.disconnect")
            self.assertEqual(len(disconnects), 1)
            self.assertEqual(disconnects[0]["data"]["request_id"], admitted[0]["data"]["request_id"])
            self.assertIn(disconnects[0]["data"]["error_type"],
                          {"BrokenPipeError", "ConnectionResetError", "SSLEOFError"})
            self.assertGreater(disconnects[0]["seq"], admitted[0]["seq"])
            self.assertEqual(journal.rows("provider.response"), [])
            self.assertEqual(journal.rows("provider.closed")[0]["data"], {"status": "ok", "errors": []})
            rows = journal.rows()
            requests, responses = _provider(rows)
            self.assertEqual(set(requests), {admitted[0]["data"]["request_id"]})
            self.assertEqual(responses, {})
            for mutation in ("orphan", "duplicate", "unknown_error", "before_request", "after_closure", "response"):
                with self.subTest(mutation=mutation):
                    changed = json.loads(json.dumps(rows))
                    disconnected = next(row for row in changed if row["kind"] == "provider.disconnect")
                    if mutation == "orphan":
                        disconnected["data"]["request_id"] += 1
                    elif mutation == "duplicate":
                        changed.append(json.loads(json.dumps(disconnected)))
                    elif mutation == "unknown_error":
                        disconnected["data"]["error_type"] = "TimeoutError"
                    elif mutation == "before_request":
                        disconnected["seq"] = admitted[0]["seq"]
                    elif mutation == "after_closure":
                        disconnected["seq"] = journal.rows("provider.closed")[0]["seq"] + 1
                    else:
                        payload = json.dumps({"data": {}}).encode()
                        changed.append({"seq": disconnected["seq"], "kind": "provider.response", "data": {
                            "request_id": disconnected["data"]["request_id"], "status": HTTPStatus.OK.value,
                            "headers": [["Content-Type", "application/json"], ["Content-Length", str(len(payload))],
                                        ["Connection", "close"]], "body": base64.b64encode(payload).decode("ascii")}})
                    with self.assertRaises(ValueError):
                        _provider(changed)

    def _child_note(self, error, phase, snapshot):
        try:
            value = snapshot()
            if not isinstance(value, dict):
                return

            def select(row, keys):
                return {key: row[key][:DIAGNOSTIC_SCALAR] if isinstance(row[key], str) else row[key]
                        for key in keys if key in row and type(row[key]) in (str, int, bool, type(None))}

            note = {"phase": phase, **select(value, ("pid", "guard_pid", "returncode", "closed", "reaped"))}
            note["eof"] = [name for name in ("stderr", "stdout") if name in value.get("eof", ())]
            note["failures"] = [select(row, ("stage", "class"))
                                for row in value.get("failures", ())[-DIAGNOSTIC_PHASES:]]
            note["lifecycle"] = [select(row, ("kind", "operation", "stage", "status", "forced"))
                                 for row in value.get("lifecycle", ())[-DIAGNOSTIC_PHASES:]]
            for stream in ("stdout", "stderr"):
                raw = value.get(stream, b"")
                if type(raw) is bytes:
                    note[stream + "_tail"] = raw[-DIAGNOSTIC_TAIL:].decode("utf-8", errors="replace")
            BaseException.add_note(error, "Fixture child: " + json.dumps(note, ensure_ascii=False)[:DIAGNOSTIC_LIMIT])
        except BaseException:
            # Diagnostics must preserve the original join or cleanup failure.
            pass

    def child(self, body, budget=CHILD_BUDGET):
        flags = ["-" + "O" * min(sys.flags.optimize, 2)] if sys.flags.optimize else []
        with tempfile.TemporaryDirectory() as directory:
            try:
                with Process([sys.executable, *flags, "-c", body], cwd=Path(directory),
                             env=dict(os.environ), output_limit=65536,
                             deadline=time.monotonic() + budget) as child:
                    try:
                        status = child.join(budget - 1)
                    except BaseException as error:
                        self._child_note(error, "pre-cleanup", child.snapshot)
                        raise
                    self.assertEqual(status, 0, child.snapshot()["stderr"].decode("utf-8", errors="replace"))
                    self.assertEqual(child.snapshot()["stderr"], b"")
            except BaseException as error:
                self._child_note(error, "post-cleanup", lambda: getattr(error, "_process_snapshot", None))
                raise

    def test_idle_tls_admission(self):
        self.child('''
import socket
from pathlib import Path
from symphony_conformance.assets import load, resource
from symphony_conformance.driver.journal import Journal
from symphony_conformance.driver.tracker import Tracker
journal = Journal(Path.cwd())
tracker = Tracker(load('corpus/lifecycle.json'), journal, str(resource('tls/server.pem')), str(resource('tls/server.key')))
client = socket.create_connection(('127.0.0.1', int(tracker.endpoint.split(':')[2].split('/')[0])), timeout=1)
client.sendall(b'\\x16')
tracker.close()
client.close()
journal.close()
''')

    def test_drip_close(self):
        self.drip_close(Input.BODY)

    def test_header_close(self):
        self.drip_close(Input.HEADERS)

    def test_body_expiry(self):
        self.drip_close(Input.BODY, Action.EXPIRE)

    def test_header_expiry(self):
        self.drip_close(Input.HEADERS, Action.EXPIRE)

    def drip_close(self, stage, action=Action.CLOSE):
        self.child('''
import http.client
import json
import socket
import ssl
import threading
import time
from http import HTTPStatus
from pathlib import Path

started = time.monotonic()
def _note(stage):
    print('Tracker drip: ' + stage + ' elapsed=' + format(time.monotonic() - started, '.3f'), flush=True)

_note('imports.begin')
from symphony_conformance.assets import load, resource
from symphony_conformance.driver.journal import Journal
from symphony_conformance.driver import tracker as driver
_note('imports.end')

CLOSE_BUDGET = 1
JOIN_BUDGET = 2
DRIP_INTERVAL = 0.05
stage = STAGE_VALUE
action = ACTION_VALUE
corpus = load('corpus/lifecycle.json')
journal = Journal(Path.cwd())
_note('tracker.begin')
tracker = driver.Tracker(corpus, journal, str(resource('tls/server.pem')), str(resource('tls/server.key')))
_note('tracker.end')
admitted = threading.Event()
admitted_at = [None]
stop = threading.Event()
if stage == 'body':
    original = tracker._request
    def request(handler):
        admitted_at[0] = time.monotonic()
        admitted.set()
        original(handler)
    tracker._request = request
else:
    original = tracker._server.get_request
    def request():
        connection = original()
        admitted_at[0] = time.monotonic()
        admitted.set()
        return connection
    tracker._server.get_request = request
port = int(tracker.endpoint.split(':')[2].split('/')[0])
context = ssl.create_default_context(cafile=str(resource('tls/ca.pem')))
_note('client.begin')
client = context.wrap_socket(socket.create_connection(('127.0.0.1', port), timeout=1), server_hostname='127.0.0.1')
_note('client.end')
if stage == 'body':
    client.sendall(('POST /graphql HTTP/1.1\\r\\nHost: 127.0.0.1\\r\\nAuthorization: '
                    + corpus['fake_secret'] + '\\r\\nContent-Length: ' + str(driver.MAX_BODY)
                    + '\\r\\nConnection: close\\r\\n\\r\\n{').encode())
else:
    client.sendall(b'POST /graphql HTTP/1.1\\r\\nHost: 127.0.0.1\\r\\nX-Drip: ')

def drip():
    while not stop.wait(DRIP_INTERVAL):
        try:
            client.sendall(b' ')
        except OSError:
            return

failures = []

def close():
    try:
        _note('close.begin')
        tracker.close()
        _note('close.end')
    except BaseException as error:
        failures.append(type(error).__name__)

writer = threading.Thread(target=drip, daemon=True)
closer = threading.Thread(target=close, daemon=True)
try:
    _note('admission.begin')
    if not admitted.wait(CLOSE_BUDGET):
        raise RuntimeError('HTTP connection was not admitted')
    _note('admission.end')
    if action == 'close':
        writer.start()
        closer.start()
        closer.join(CLOSE_BUDGET)
        if closer.is_alive():
            raise RuntimeError('Tracker.close did not stop an admitted drip connection within its budget')
    else:
        end = admitted_at[0] + driver.SOCKET_TIMEOUT + CLOSE_BUDGET
        client.settimeout(DRIP_INTERVAL)
        expired = None
        while time.monotonic() < end:
            try:
                # One owner alternates TLS writes and reads; each read paces the drip.
                client.sendall(b' ')
                data = client.recv(4096)
                if data:
                    raise RuntimeError('Tracker answered an incomplete request: ' + repr(data))
                expired = 'EOF'
            except socket.timeout:
                continue
            except (ConnectionResetError, ConnectionAbortedError, BrokenPipeError,
                    ssl.SSLEOFError, ssl.SSLZeroReturnError) as error:
                expired = repr(error)
            break
        elapsed = time.monotonic() - admitted_at[0]
        if expired is None:
            raise RuntimeError('Tracker drip traffic renewed the total connection deadline after '
                               + str(elapsed) + ' s')
        _note('expiry.observed')
        # Admission follows TLS negotiation; allow its existing bounded budget.
        if elapsed < driver.SOCKET_TIMEOUT - CLOSE_BUDGET:
            raise RuntimeError('Tracker disconnected before its deadline after '
                               + str(elapsed) + ' s: ' + expired)
        fresh = http.client.HTTPSConnection('127.0.0.1', port, context=context, timeout=CLOSE_BUDGET)
        try:
            _note('probe.begin')
            fresh.request('POST', '/graphql', json.dumps({'query': '{issues(first:1,filter:{}){nodes{id identifier title state{name}}}}'}),
                          {'Authorization': corpus['fake_secret']})
            response = fresh.getresponse()
            response.read()
            if response.status != HTTPStatus.OK:
                raise RuntimeError('Tracker did not admit a healthy request after expiry')
            _note('probe.end')
        except Exception as error:
            raise RuntimeError('Tracker healthy probe failed after expiry at '
                               + str(elapsed) + ' s: ' + expired) from error
        finally:
            fresh.close()
finally:
    # Release the old blocking handler even when the bounded assertion fails.
    stop.set()
    try:
        client.shutdown(socket.SHUT_RDWR)
    except OSError:
        pass
    client.close()
    if writer.ident is not None:
        writer.join(CLOSE_BUDGET)
    if closer.ident is not None:
        closer.join(JOIN_BUDGET)
    else:
        _note('close.begin')
        tracker.close()
        _note('close.end')
    _note('journal.begin')
    journal.close()
    _note('journal.end')

if closer.is_alive() or writer.is_alive():
    raise RuntimeError('Tracker regression cleanup did not join its threads')
if failures or tracker.errors():
    raise RuntimeError('Owner cancellation became a fixture failure: ' + str(failures + tracker.errors()))
if journal.rows('provider.closed')[0]['data']['status'] != 'ok':
    raise RuntimeError('Owner cancellation emitted an error closure receipt')
'''.replace('STAGE_VALUE', repr(stage.value)).replace('ACTION_VALUE', repr(action.value)),
                   CHILD_BUDGET if action is Action.CLOSE else EXPIRY_BUDGET)

    def test_failed_admission_recorder(self):
        self.child('''
import threading
from symphony_conformance.assets import load, resource
from symphony_conformance.driver.tracker import Tracker
class Recorder:
    def emit(self, *args):
        raise RuntimeError('recorder failure')
try:
    Tracker(load('corpus/lifecycle.json'), Recorder(), str(resource('tls/server.pem')), str(resource('tls/server.key')))
except RuntimeError:
    pass
else:
    raise RuntimeError('lost recorder failure')
if any(thread.name == 'fixture-tracker' for thread in threading.enumerate()):
    raise RuntimeError('tracker thread escaped constructor')
''')


if __name__ == "__main__":
    unittest.main()
