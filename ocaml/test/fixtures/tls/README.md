# Test TLS identity

These public fixture keys are deliberately committed for local tests. Never use
them for deployment. Production has no embedded fixture CA; tests supply ca.pem
through the normal explicit trust path.

server.pem is signed by ca.pem for DNS localhost/IP127.0.0.1. wrong-host.pem is
signed by the same CA for unrelated.example.test. The CA signing key was discarded.
Validity is2020-01-01 through2040-01-01; expiry is a separate fake-clock control.
other-ca.pem has an unrelated signing identity for trust rejection controls.
