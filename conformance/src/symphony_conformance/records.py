"""Keep captured facts separate from requirement answers."""

ANSWER_FIELDS = frozenset(("requirement_id", "verdict", "passed"))


def check_data(value):
    if not isinstance(value, dict):
        raise ValueError("invalid observation payload")
    if ANSWER_FIELDS.intersection(value):
        raise ValueError("observations cannot supply requirement answers")
