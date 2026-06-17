# Future work

Deferred, non-blocking items for the dev container. Each section records the
rationale and candidate directions for work that is intentionally postponed.

## Firewall hardening

The container enforces outbound network access through a default-deny firewall
in `init-firewall.sh`: `dnsmasq` resolves a fixed set of allowed hosts and
populates an `ipset`, `iptables` permits HTTPS egress only to addresses in that
set, and the published GitHub CIDR ranges are pre-seeded. The current posture
is adequate for the container's threat model — preventing casual or accidental
egress to unlisted services while running Claude Code with
`--dangerously-skip-permissions` — and the hardenings below are deferred rather
than required.

### Known limitations

- **IP-layer allowlisting cannot distinguish CDN tenants.** `iptables` matches
  the destination IP, not the TLS Server Name Indication (SNI). A host that
  shares a CDN address with an allowed host is therefore reachable as
  collateral: `docs.python.org` resolves to the same Fastly address as the
  allowed `files.pythonhosted.org`, and seeding GitHub's `.web` CIDR ranges
  admits the entire GitHub Pages range — every `*.github.io` site, including
  `docs.pola.rs`. A commented-out documentation host in the allow list is
  consequently reachable whether or not it is listed.
- **IPv6 egress is unfiltered.** The firewall configures `iptables` (IPv4)
  only; the `ip6tables` OUTPUT chain retains its default-accept policy. Where
  the container has IPv6 connectivity, the guarantees above are bypassable over
  IPv6, and several allowed hosts publish AAAA records.
- **The resolver is not allowlist-only.** `dnsmasq` forwards arbitrary names to
  the upstream resolver; only the resolved addresses of allowed hosts are added
  to the ipset. A name outside the allow list still resolves, which leaves a
  DNS-based exfiltration channel — the lookup itself carries data to an
  attacker-controlled authoritative nameserver before any connection the IP
  allowlist would block.

### Candidate hardenings

Roughly ordered by value relative to effort:

1. **IPv6 policy.** Mirror the IPv4 rules with an `ip6tables` default-deny
   policy, or disable IPv6 egress in the container. This closes a full bypass
   of the existing controls.
2. **Allowlist-only DNS.** Restrict `dnsmasq` to forward only the permitted
   domain suffixes and refuse all other names. This closes the DNS
   exfiltration channel and is a configuration change to the existing resolver,
   requiring no additional container.
3. **Trim the GitHub CIDR seed.** Dropping the `.web` set from the
   `api.github.com/meta` seed removes the GitHub Pages range from the egress
   surface, at the cost of access to Pages-hosted resources.
4. **SNI-filtering egress proxy.** An egress proxy that inspects the cleartext
   SNI — for example `squid` with `ssl_bump` peek-and-splice — can admit or
   deny individual domains behind a shared CDN address. This is the only
   mechanism that resolves the CDN-tenant limitation, since the IP layer has no
   access to the hostname.
5. **Gateway sidecar for privilege separation.** Moving firewall enforcement
   into a gateway container that the application container routes through —
   with the application container holding no `NET_ADMIN` capability — places the
   control plane outside the blast radius of an application-container
   compromise. The current design is self-enforced: a sufficiently privileged
   process can flush the rules it installed.

### References

- `init-firewall.sh` — the firewall implementation.
- `README.md` § Network firewall — the allow list and operating model.
