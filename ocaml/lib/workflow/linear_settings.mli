(** Linear settings-only profile. Network reads are introduced in slice 3. Scope
    is endpoint plus project slug; secret source names never contain values.

    Endpoints use ASCII RFC3986 syntax; non-ASCII data must be percent-encoded.
    Only absolute HTTPS endpoints without userinfo/fragments are accepted.
    Reg-name hosts and IPv6 literals are supported. Explicit ports are decimal
    1..65535; omitting the port preserves the HTTPS default.

    URI/IPv6 parsing belongs to Uri's public Angstrom parsers with full-input
    consumption. A raw syntax guard rejects repairs that Uri would otherwise
    perform: invalid percent escapes, separators, characters, and ports.
    Expected endpoint failure is always Invalid_tracker_config at
    tracker.provider.endpoint; no endpoint or credential value is printed. *)

include Tracker_adapter.CONFIG
