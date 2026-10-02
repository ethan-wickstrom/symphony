# Test TLS identity

These public fixture keys are deliberately committed for local tests. Never use
them for deployment. Production has no embedded fixture CA; tests supply ca.pem
through the normal explicit trust path.

server.pem is signed by ca.pem for DNS localhost/IP 127.0.0.1. wrong-host.pem is
signed by the same CA for unrelated.example.test. The CA signing key was discarded.
Validity is 2020-01-01 through 2040-01-01; expiry is a separate fake-clock control.
other-ca.pem has an unrelated signing identity for trust rejection controls.

rsa-ca.pem is an RSA2048 CA. rsa-signed.pem has the existing server.key's P256
public key, localhost identities and the same 2020–2040 validity window. These
fixtures were generated with OpenSSL `req -x509 -sha256`, explicit dates, critical
CA/key-usage constraints and serverAuth/SAN extensions. The RSA CA key was discarded.

rsa-signature-0.pem and rsa-signature-1.pem preserve every DER byte except the outer
signature payload: a 256-byte big-endian integer 0 or 1. OpenSSL `asn1parse` locates
the outer BIT STRING at offset 386, header 4, content 257 (including zero unused bits),
in the 647-byte leaf. No ASN.1 lengths or signed certificate data change. The server
serves only this leaf; the client independently validates its signature against
rsa-ca.pem. A valid RSA-signed control reaches HTTP; both invalid variants must
return a checked failure without sending the credential. Before the server closes
its accepted socket, its bounded raw read must observe peer termination (EOF or
typed TCP reset). Unrelated read errors remain failures.
