"""Pure requirement reporting; successful assertions do not erase missing cases."""

from collections import Counter


SCHEMA_VERSION = 1
APPROVED_ROWS = 106
SUPPLEMENTAL_ROWS = 12
ASSERTION_VERDICTS = frozenset({"pass", "fail", "unobservable", "incomplete"})
FEATURE_STATES = frozenset({"present", "absent", "unknown"})
JOURNAL = "events.jsonl"


def _rows(catalog):
    approved = catalog.get("requirements")
    supplemental = catalog.get("supplemental_inventory")
    if not isinstance(approved, list) or len(approved) != APPROVED_ROWS:
        raise ValueError("catalog must retain all approved requirements")
    if not isinstance(supplemental, list) or len(supplemental) != SUPPLEMENTAL_ROWS:
        raise ValueError("catalog must retain all supplemental requirements")

    rows = approved + supplemental
    ids = [row.get("id") for row in rows if isinstance(row, dict)]
    if len(ids) != len(rows) or any(not isinstance(item, str) for item in ids):
        raise ValueError("invalid catalog requirement ID")
    if len(set(ids)) != len(ids):
        raise ValueError("duplicate catalog requirement ID")
    return approved, supplemental


def _assertions(case):
    entries = case.get("assertions", [])
    if not isinstance(entries, list):
        raise ValueError("invalid assertion inventory")

    indexed = {}
    for entry in entries:
        if not isinstance(entry, dict):
            raise ValueError("invalid assertion result")
        item = entry.get("id")
        if not isinstance(item, str) or item in indexed:
            raise ValueError("missing or duplicate assertion ID")
        if entry.get("status") not in ASSERTION_VERDICTS:
            raise ValueError("invalid assertion verdict")
        indexed[item] = entry
    return indexed


def _coverage(case, rows, assertions):
    coverage = case.get("coverage", {})
    if not isinstance(coverage, dict):
        raise ValueError("invalid coverage inventory")
    known = {row["id"] for row in rows}
    if set(coverage) - known:
        raise ValueError("unknown requirement in case coverage")

    for entry in coverage.values():
        if not isinstance(entry, dict) or type(entry.get("complete")) is not bool:
            raise ValueError("coverage needs an explicit completeness declaration")
        ids = entry.get("assertion_ids")
        if not isinstance(ids, list) or not ids or any(not isinstance(item, str) for item in ids):
            raise ValueError("invalid covered assertion inventory")
        if len(set(ids)) != len(ids):
            raise ValueError("invalid covered assertion inventory")
        if any(item not in assertions for item in ids):
            raise ValueError("coverage refers to a missing assertion")
        if entry.get("case_id") != case.get("id"):
            raise ValueError("coverage refers to a different case")
    return coverage


def _applicability(row, features):
    declared = row.get("applicability", {})
    if declared.get("kind") == "always":
        return "required"
    feature = declared.get("feature")
    if feature is None:
        return "unknown"
    state = features.get(feature, "unknown")
    if state not in FEATURE_STATES:
        raise ValueError("invalid feature declaration")
    return {"present": "required", "absent": "not_applicable", "unknown": "unknown"}[state]


def _result(row, coverage, assertions, features, harness):
    applicability = _applicability(row, features)
    base = {
        "requirement_id": row["id"],
        "validation_profile": row["validation_profile"],
        "normative_level": row["normative_level"],
        "applicability": applicability,
        "verdict": "incomplete",
        "reasons": [],
        "case_ids": [],
        "assertion_ids": [],
        "evidence_seq": [],
        "evidence_refs": [],
        "source": row["source"],
    }
    if applicability == "not_applicable":
        return {**base, "verdict": "not_applicable", "reasons": ["checked_feature_absence"]}
    if applicability == "unknown":
        return {**base, "reasons": ["applicability_unknown", "unimplemented"]}

    entry = coverage.get(row["id"])
    if entry is None:
        reasons = row.get("initial_result", {}).get("reasons", ["unimplemented"])
        return {**base, "reasons": list(reasons)}

    observed = [assertions[item] for item in entry["assertion_ids"]]
    states = {item["status"] for item in observed}
    base["assertion_ids"] = list(entry["assertion_ids"])
    base["evidence_seq"] = sorted({seq for item in observed for seq in item.get("evidence_seq", [])})
    base["evidence_refs"] = [{"file": JOURNAL, "seq": seq} for seq in base["evidence_seq"]]
    base["case_ids"] = [entry["case_id"]]
    if harness["status"] != "pass":
        return {**base, "verdict": "harness_error", "reasons": ["harness_health_failed"]}
    if "fail" in states:
        return {**base, "verdict": "fail", "reasons": ["fixed_assertion_failed"]}
    if "unobservable" in states:
        return {**base, "verdict": "unobservable", "reasons": ["required_observation_missing"]}
    if "incomplete" in states:
        return {**base, "reasons": ["required_stage_missing"]}
    if entry["complete"]:
        return {**base, "verdict": "pass"}
    return {**base, "reasons": ["partial_clause_coverage"]}


def build(catalog, case, harness, identities):
    """Preserve every obligation and keep harness health independent of assertions."""
    approved, supplemental = _rows(catalog)
    assertions = _assertions(case)
    coverage = _coverage(case, approved + supplemental, assertions)
    features = case.get("features", {})
    if not isinstance(features, dict):
        raise ValueError("invalid feature declarations")
    if harness.get("status") not in {"pass", "harness_error"}:
        raise ValueError("invalid harness health")
    if not isinstance(harness.get("errors"), list):
        raise ValueError("invalid harness error inventory")
    if harness["errors"] and harness["status"] == "pass":
        raise ValueError("harness errors cannot coexist with passing health")

    results = [_result(row, coverage, assertions, features, harness) for row in approved]
    extra = [_result(row, coverage, assertions, features, harness) for row in supplemental]
    core = [item for item in results if item["validation_profile"] == "core"]
    extension = [item for item in results if item["validation_profile"] == "extension"]
    core_counts = dict(Counter(item["verdict"] for item in core))
    complete = harness["status"] == "pass" and all(item["verdict"] == "pass" for item in core)
    return {
        "schema_version": SCHEMA_VERSION,
        "report_kind": "portable_conformance_result",
        "spec": catalog["spec"],
        "identities": dict(identities),
        "case": case,
        "harness": harness,
        "requirements": results,
        "supplemental_requirements": extra,
        "core_summary": {"complete": complete, "required_rows": len(core), "counts": core_counts},
        "extension_summary": {"counts": dict(Counter(item["verdict"] for item in extension))},
        "evidence_boundaries": list(catalog.get("evidence_boundaries", [])),
    }
