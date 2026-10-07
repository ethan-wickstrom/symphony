"""Parse the fixture adapter's GraphQL selection without query spelling rules."""

from graphql import get_operation_ast, parse, value_from_ast_untyped
from graphql.language import FieldNode, OperationType

from .assets import decode


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
    return {"filter": arguments["filter"], "first": count, "after": None,
            "orderBy": arguments.get("orderBy", "createdAt"),
            "includeArchived": arguments.get("includeArchived", False),
            "response_key": field.alias.value if field.alias else field.name.value}


def matches(issue, query):
    """Evaluate only the declared Linear fixture operators; reject unknown ones."""
    for name, value in query.items():
        if name == "or":
            if not isinstance(value, list) or not value:
                raise ValueError("Invalid OR filter")
            if not any(matches(issue, part) for part in value):
                return False
            continue
        if name == "and":
            if not isinstance(value, list) or not value:
                raise ValueError("Invalid AND filter")
            if not all(matches(issue, part) for part in value):
                return False
            continue
        if name not in {"id", "project", "state"} or not isinstance(value, dict):
            raise ValueError("Unknown fixture filter")

        actual = issue.get(name)
        if name in {"project", "state"}:
            if not isinstance(actual, dict) or not matches_field(actual, value):
                return False
        elif not compare(actual, value):
            return False
    return True


def matches_field(actual, query):
    for name, conditions in query.items():
        if name not in {"name", "slugId", "id"} or not compare(actual.get(name), conditions):
            return False
    return True


def compare(actual, conditions):
    if not isinstance(conditions, dict) or not conditions:
        raise ValueError("Invalid fixture comparison")
    for operator, expected in conditions.items():
        if operator == "eq" and actual != expected:
            return False
        if operator == "eqIgnoreCase":
            if not isinstance(actual, str) or not isinstance(expected, str):
                raise ValueError("Invalid case-insensitive comparison")
            if actual.casefold() != expected.casefold():
                return False
        if operator == "in":
            if not isinstance(expected, list) or any(not isinstance(v, str) for v in expected):
                raise ValueError("Invalid membership comparison")
            if actual not in expected:
                return False
        if operator not in {"eq", "eqIgnoreCase", "in"}:
            raise ValueError("Unknown fixture operator")
    return True
