"""Parse the fixture adapter's GraphQL selection without query spelling rules."""

from graphql import get_operation_ast, parse, value_from_ast_untyped
from graphql.language import FieldNode, OperationType

from .assets import decode


_LOGICAL_FIELDS = frozenset({"or", "and"})
_FILTER_FIELDS = frozenset({"id", "project", "state"})
_RELATION_FIELDS = frozenset({"name", "slugId", "id"})
_TEXT_OPERATORS = frozenset({"eq", "eqIgnoreCase"})


def select(raw):
    body = decode(raw) if isinstance(raw, (bytes, str)) else raw
    if not isinstance(body, dict) or not isinstance(body.get("query"), str):
        raise ValueError("Missing GraphQL document")

    variables = body.get("variables", {})
    if not isinstance(variables, dict):
        raise ValueError("Invalid GraphQL variables")

    operation = get_operation_ast(parse(body["query"]), body.get("operationName"))
    if operation is None or operation.operation != OperationType.QUERY:
        raise ValueError("Fixture requires one selected query")

    values = dict(variables)
    for definition in operation.variable_definitions or ():
        name = definition.variable.name.value
        if name not in values and definition.default_value is not None:
            values[name] = value_from_ast_untyped(definition.default_value)

    fields = operation.selection_set.selections
    if len(fields) != 1 or not isinstance(fields[0], FieldNode):
        raise ValueError("Fixture supports one issues field")
    field = fields[0]
    if field.name.value != "issues":
        raise ValueError("Unknown fixture field")

    arguments = {}
    for argument in field.arguments:
        name = argument.name.value
        if name in arguments:
            raise ValueError("Duplicate field argument")
        arguments[name] = value_from_ast_untyped(argument.value, values)

    if set(arguments) - {"filter", "first", "after", "orderBy", "includeArchived"}:
        raise ValueError("Unsupported fixture argument")
    if arguments.get("orderBy", "createdAt") not in {"createdAt", "updatedAt"}:
        raise ValueError("Unsupported fixture ordering")
    if type(arguments.get("includeArchived", False)) is not bool:
        raise ValueError("Invalid archived selection")
    count = arguments.get("first")
    if type(count) is not int or count <= 0 or arguments.get("after") is not None:
        raise ValueError("Invalid one-page selection")
    if not isinstance(arguments.get("filter"), dict):
        raise ValueError("Missing issues filter")
    _check_filter(arguments["filter"])
    return {"filter": arguments["filter"], "first": count, "after": None,
            "orderBy": arguments.get("orderBy", "createdAt"),
            "includeArchived": arguments.get("includeArchived", False),
            "response_key": field.alias.value if field.alias else field.name.value}


def _check_filter(query):
    if not isinstance(query, dict):
        raise ValueError("Invalid fixture filter")
    for name, value in query.items():
        if name in _LOGICAL_FIELDS:
            if not isinstance(value, list) or not value:
                raise ValueError("Invalid logical filter")
            for part in value:
                _check_filter(part)
            continue
        if name not in _FILTER_FIELDS:
            raise ValueError("Unknown fixture filter")
        if name == "id":
            _check_comparison(value)
            continue
        if not isinstance(value, dict):
            raise ValueError("Invalid fixture relation filter")
        for field, conditions in value.items():
            if field not in _RELATION_FIELDS:
                raise ValueError("Unknown fixture relation field")
            _check_comparison(conditions)


def _check_comparison(conditions):
    if not isinstance(conditions, dict) or not conditions:
        raise ValueError("Invalid fixture comparison")
    for operator, expected in conditions.items():
        if operator in _TEXT_OPERATORS:
            if not isinstance(expected, str):
                raise ValueError("Invalid fixture text comparison")
            continue
        if operator == "in":
            if not isinstance(expected, list) or any(not isinstance(v, str) for v in expected):
                raise ValueError("Invalid membership comparison")
            continue
        raise ValueError("Unknown fixture operator")


def matches(issue, query):
    """Reject malformed predicates before reading issue values."""
    _check_filter(query)
    return _matches(issue, query)


def _matches(issue, query):
    # All branches are validated before predicate evaluation can short-circuit.
    for name, value in query.items():
        if name == "or":
            if not any(_matches(issue, part) for part in value):
                return False
            continue
        if name == "and":
            if not all(_matches(issue, part) for part in value):
                return False
            continue
        actual = issue.get(name)
        if name == "id":
            if not _compare(actual, value):
                return False
            continue
        if not isinstance(actual, dict) or not _matches_field(actual, value):
            return False
    return True


def _matches_field(actual, query):
    return all(_compare(actual.get(name), conditions) for name, conditions in query.items())


def _compare(actual, conditions):
    for operator, expected in conditions.items():
        if operator == "eq" and actual != expected:
            return False
        if operator == "eqIgnoreCase":
            if not isinstance(actual, str) or actual.casefold() != expected.casefold():
                return False
        if operator == "in" and actual not in expected:
            return False
    return True
