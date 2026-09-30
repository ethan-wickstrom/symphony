---
tracker:
  kind: linear
  active_states: [Todo, In Progress]
  terminal_states: [Done, Canceled]
  provider:
    project_slug: replace-with-project-slug
    api_key: $LINEAR_API_KEY
workspace:
  root: ./workspaces
---
You are working on {{ issue.identifier }}: {{ issue.title }}.
State: {{ issue.state }}. Labels: {{ issue.labels | join(', ') }}.
{% if attempt %}Retry attempt: {{ attempt }}.{% endif %}
