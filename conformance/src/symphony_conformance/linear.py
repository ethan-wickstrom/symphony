"""Validate and project queries against the fixed lifecycle tracker schema.

Effective nodes.id, identifier, title and state.name paths select their schema
fields independently of response aliases. GraphQL handles field execution.
The fixture exposes one issue connection and retains a closed filter contract.
"""

from graphql import (build_schema, default_field_resolver, execute_sync,
                     get_operation_ast, parse, validate, value_from_ast_untyped)
from graphql.language import OperationType

from .assets import decode


_LOGICAL_FIELDS = frozenset({"or", "and"})
_FILTER_FIELDS = frozenset({"id", "project", "state"})
_RELATION_FIELDS = {"project": frozenset({"name", "slugId", "id"}),
                    "state": frozenset({"name", "id"})}
_TEXT_OPERATORS = frozenset({"eq", "eqIgnoreCase"})
_ID_OPERATORS = frozenset({"eq"})
_REQUIRED_FIELDS = {
    ("nodes",): ("IssueConnection", "nodes"),
    ("nodes", 0, "id"): ("Issue", "id"),
    ("nodes", 0, "identifier"): ("Issue", "identifier"),
    ("nodes", 0, "title"): ("Issue", "title"),
    ("nodes", 0, "state"): ("Issue", "state"),
    ("nodes", 0, "state", "name"): ("WorkflowState", "name"),
}
_SCHEMA = build_schema("""
    type Query {
        issues(filter: IssueFilter!, first: Int!, after: String,
               orderBy: PaginationOrderBy = createdAt,
               includeArchived: Boolean = false): IssueConnection!
    }
    enum PaginationOrderBy { createdAt updatedAt }
    input IssueFilter {
        id: IssueIDComparator, project: NullableProjectFilter, state: WorkflowStateFilter,
        or: [IssueFilter!], and: [IssueFilter!]
    }
    input NullableProjectFilter {
        id: EntityIdentifierIDComparator, name: StringComparator, slugId: StringComparator
    }
    input WorkflowStateFilter { id: IDComparator, name: StringComparator }
    input IssueIDComparator { eq: ID, in: [ID!] }
    input EntityIdentifierIDComparator { eq: ID, in: [ID!] }
    input IDComparator { eq: ID, in: [ID!] }
    input StringComparator { eq: String, eqIgnoreCase: String, in: [String!] }
    type IssueConnection { nodes: [Issue!]!, pageInfo: PageInfo! }
    type PageInfo { hasNextPage: Boolean!, endCursor: String }
    type Issue {
        id: ID!, identifier: String!, title: String!, state: WorkflowState!,
        description: String, priority: Int, branchName: String, url: String,
        createdAt: String, updatedAt: String, assignee: User, project: Project,
        labels(first: Int): IssueLabelConnection!,
        inverseRelations(first: Int): IssueRelationConnection!
    }
    type WorkflowState { id: ID, name: String! }
    type User { id: ID }
    type Project { id: ID, slugId: String }
    type IssueLabelConnection { nodes: [IssueLabel!]!, pageInfo: PageInfo! }
    type IssueLabel { id: ID, name: String }
    type IssueRelationConnection { nodes: [IssueRelation!]!, pageInfo: PageInfo! }
    type IssueRelation { id: ID, type: String, issue: Issue, relatedIssue: Issue }
""")


def select(raw):
    body = decode(raw) if isinstance(raw, (bytes, str)) else raw
    if not isinstance(body, dict) or not isinstance(body.get("query"), str):
        raise ValueError("Missing GraphQL document")

    variables = body.get("variables", {})
    if not isinstance(variables, dict):
        raise ValueError("Invalid GraphQL variables")

    operation_name = body.get("operationName")
    if operation_name is not None and not isinstance(operation_name, str):
        raise ValueError("Invalid GraphQL operation name")
    document = parse(body["query"])
    operation = get_operation_ast(document, operation_name)
    if operation is None or operation.operation != OperationType.QUERY:
        raise ValueError("Fixture requires one selected query")
    if validate(_SCHEMA, document):
        raise ValueError("Invalid fixture GraphQL document")

    values = dict(variables)
    for definition in operation.variable_definitions or ():
        name = definition.variable.name.value
        if name not in values and definition.default_value is not None:
            values[name] = value_from_ast_untyped(definition.default_value)

    selected = []
    observed = {}
    schema_paths = {}
    empty = {"nodes": [], "pageInfo": {"hasNextPage": False, "endCursor": None}}
    probe = {"nodes": [{"id": "probe-id", "identifier": "probe-identifier",
                        "title": "probe-title", "state": {"name": "probe-state"},
                        "labels": empty, "inverseRelations": empty}],
             "pageInfo": empty["pageInfo"]}

    def choose(info, **_coerced):
        if selected:
            raise ValueError("Fixture supports one effective issues field")
        # Preserve strict raw input shapes before GraphQL's ID/list coercion.
        arguments = {argument.name.value: value_from_ast_untyped(argument.value, values)
                     for argument in info.field_nodes[0].arguments}
        selection = _arguments(arguments)
        selection["response_key"] = info.path.key
        selected.append(selection)
        return probe

    def observe(source, info, **arguments):
        response_path = tuple(info.path.as_list())
        if info.parent_type.name == "Query":
            schema_paths[response_path] = ()
            return default_field_resolver(source, info, **arguments)

        parent = response_path[:-1]
        schema_parent = (schema_paths[parent[:-1]] + (0,)
                         if type(parent[-1]) is int else schema_paths[parent])
        path = schema_parent + (info.field_name,)
        schema_paths[response_path] = path
        identity = (info.parent_type.name, info.field_name)
        if _REQUIRED_FIELDS.get(path) == identity:
            # Each effective nodes branch proves its own complete projection.
            branch = response_path[1:2]
            fields = observed.setdefault(branch, {})
            fields.setdefault(path, response_path[1:])
        return default_field_resolver(source, info, **arguments)

    result = execute_sync(_SCHEMA, document, root_value={"issues": choose},
                          variable_values=variables, operation_name=operation_name,
                          field_resolver=observe, check_sync=True)
    if (result.errors or len(selected) != 1 or not observed
            or any(not _REQUIRED_FIELDS.keys() <= fields.keys() for fields in observed.values())):
        raise ValueError("Missing effective fixture projection")
    selection = selected[0]
    selection["response_paths"] = [{"nodes": fields[("nodes",)],
                                     "id": fields[("nodes", 0, "id")][2:],
                                     "state_name": fields[("nodes", 0, "state", "name")][2:]}
                                    for fields in observed.values()]
    if set(result.data) != {selection["response_key"]}:
        raise ValueError("Fixture supports one effective root field")

    def project(connection):
        response = execute_sync(_SCHEMA, document,
                                root_value={"issues": lambda _info, **_args: connection},
                                variable_values=variables, operation_name=operation_name,
                                check_sync=True)
        if response.errors:
            raise RuntimeError("Fixture response projection failed")
        return {"data": response.data}

    selection["project"] = project
    return selection


def _arguments(arguments):
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
            "includeArchived": arguments.get("includeArchived", False)}


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
            _check_comparison(value, _ID_OPERATORS)
            continue
        if not isinstance(value, dict):
            raise ValueError("Invalid fixture relation filter")
        for field, conditions in value.items():
            if field not in _RELATION_FIELDS[name]:
                raise ValueError("Unknown fixture relation field")
            operators = _ID_OPERATORS if field == "id" else _TEXT_OPERATORS
            _check_comparison(conditions, operators)


def _check_comparison(conditions, operators):
    if not isinstance(conditions, dict) or not conditions:
        raise ValueError("Invalid fixture comparison")
    for operator, expected in conditions.items():
        if operator in operators:
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
