"""Newly authored, synthetic-only offline UAR-to-IGA illustration."""

import json
from pathlib import Path


class Blocked(ValueError):
    """Input cannot safely produce a candidate or preview."""


def _text(value):
    return isinstance(value, str) and bool(value.strip())


def validate_catalogue(catalogue, population):
    """Validate the entire catalogue before any reviewer selection."""
    mappings = {}
    for role in catalogue:
        key = (role.get("application_id"), role.get("entitlement_id"))
        if not all(_text(part) for part in key):
            raise Blocked("Missing catalogue identifier")
        if key in mappings:
            raise Blocked("Duplicate or conflicting catalogue mapping")
        if role.get("mapping_type") != "static":
            raise Blocked("Dynamic or unspecified mapping is not supported")
        if role.get("classification") not in {"Elevated", "Privileged"}:
            raise Blocked("Missing or unsupported classification")
        mappings[key] = role
    for row in population:
        if (row.get("application_id"), row.get("entitlement_id")) not in mappings:
            raise Blocked("Missing role catalogue mapping")
    return mappings


KEY_FIELDS = ("application_id", "account_id", "entitlement_id", "tag", "cycle")


def _population_index(rows):
    result = {}
    for row in rows:
        key = tuple(row.get(field) for field in KEY_FIELDS)
        if not all(_text(part) for part in key):
            raise Blocked("Missing population identity or scope")
        if key in result:
            raise Blocked("Duplicate population identity within scope")
        result[key] = row
    return result


def route_candidates(catalogue, population):
    """Return a complete candidate list, or block without partial results."""
    mappings = validate_catalogue(catalogue, population)
    _population_index(population)
    candidates = []
    for row in population:
        if not _text(row.get("subject_id")):
            raise Blocked("Missing subject identity for self-review check")
        role = mappings[(row["application_id"], row["entitlement_id"])]
        if (role["classification"] == "Elevated"
                and row.get("manager_active") is True
                and _text(row.get("manager_id"))):
            reviewer = row["manager_id"]
            route = "manager"
        else:
            reviewer = role.get("owner_id") or role.get("delegate_id")
            route = "owner" if role.get("owner_id") else "delegate"
        if not _text(reviewer):
            raise Blocked("No named owner or delegate")
        if reviewer == row["subject_id"]:
            raise Blocked("Unresolved self-review; no automatic fallback")
        candidates.append({**{field: row[field] for field in KEY_FIELDS},
                           "reviewer_id": reviewer, "route": route})
    return candidates


def compare_populations(current, proposed):
    """Compare exact scoped account-entitlement membership and reviewer IDs."""
    before, after = _population_index(current), _population_index(proposed)
    for row in list(before.values()) + list(after.values()):
        if not _text(row.get("reviewer_id")):
            raise Blocked("Missing reviewer in comparison")
    removed = [before[key] for key in sorted(before.keys() - after.keys())]
    added = [after[key] for key in sorted(after.keys() - before.keys())]
    drift = [{**{field: after[key][field] for field in KEY_FIELDS},
              "current_reviewer_id": before[key]["reviewer_id"],
              "proposed_reviewer_id": after[key]["reviewer_id"]}
             for key in sorted(before.keys() & after.keys())
             if before[key]["reviewer_id"] != after[key]["reviewer_id"]]
    return {"current_count": len(before), "proposed_count": len(after),
            "removed": removed, "added": added, "reviewer_drift": drift,
            "matches": not (removed or added or drift)}


def notification_preview(decisions, *, action, tag, cycle, application_id):
    """Return selected decision data only; never send or remediate."""
    if action not in {"retain", "remove"}:
        raise Blocked("Unsupported notification action")
    if not all(_text(value) for value in (tag, cycle, application_id)):
        raise Blocked("Explicit tag, cycle and application scope required")
    selected = [row for row in decisions
                if row.get("action") == action and row.get("tag") == tag
                and row.get("cycle") == cycle
                and row.get("application_id") == application_id]
    _population_index(selected)
    for row in selected:
        if (not _text(row.get("reviewer_id"))
                or not _text(row.get("subject_id"))
                or row["reviewer_id"] == row["subject_id"]):
            raise Blocked("Missing identity or unresolved self-review in preview")
    return [{**{field: row[field] for field in KEY_FIELDS},
             "reviewer_id": row["reviewer_id"], "action": action}
            for row in selected]


def run_example(data):
    candidates = route_candidates(data["catalogue"], data["population"])
    return {"synthetic_only": True, "candidates": candidates,
            "comparison": compare_populations(data["current"], candidates),
            "notification_preview": notification_preview(
                data["decisions"], **data["preview_scope"])}


if __name__ == "__main__":
    example = Path(__file__).parent / "examples" / "input.json"
    print(json.dumps(run_example(json.loads(example.read_text())), indent=2))
