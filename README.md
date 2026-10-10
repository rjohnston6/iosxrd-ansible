# IOS-XR Ansible

Reusable Ansible playbooks and roles for configuring Cisco IOS-XR devices from
structured host and group variables.

## Prerequisites

- Python and [UV](https://docs.astral.sh/uv/)
- Ansible installed in the active environment
- `markdownlint-cli2` available on `PATH` for Markdown checks

## Getting started

1. Install the project lint and pre-commit dependencies with `uv sync --group lint`.
2. Install the required Ansible collections into the ignored local collection
  directory with `make collections`.
3. Enable the Git commit hooks with `make pre-commit-install`.
4. Update `inventories/example/hosts.yaml` with your device address and the
  model variables under `inventories/example/group_vars/` and `host_vars/`.
5. Run `make syntax-check` to validate the playbook, then run it against the
  reachable device with `ansible-playbook playbooks/site.yaml --ask-pass`.

The example targets the CML test device `ix-pop` at `198.18.191.1`. Change the
address when using a different device. The inventory includes the non-secret
SSH username; supply passwords through the interactive prompt, Ansible Vault,
or an external secrets provider, not in inventory files.

## Data model and roles

The example follows the NetAsCode IOS-XR shape: configuration is rooted at
`iosxr.devices.configuration`, with shared defaults and device-level data kept
separate from the playbook. It extends that pattern with provider and region
layers using Ansible inventory groups:

```text
inventories/example/
  hosts.yaml
  group_vars/
    all.yaml
    provider_ix_pop.yaml
  host_vars/
    ix-pop.yaml
```

`playbooks/site.yaml` combines the model in this order: global defaults,
provider, optional region, then device. Nested mappings merge recursively;
lists replace the inherited list. In the example, the provider NTP server list
replaces the global default. A feature role consumes only the resulting
`iosxr_effective_model`, not the hierarchy it came from.
For example, banners declared in `group_vars/all.yaml` apply by default to all
devices. If a provider, region, or device defines its own `banners` list, that
list replaces the inherited list rather than appending to it.
For architecture decisions, current validation status, and planned topology
work, see [ARCHITECTURE.md](ARCHITECTURE.md).

The playbook includes `iosxr_system`, `iosxr_l3_interfaces`, `iosxr_ntp`,
`iosxr_isis`, and `iosxr_bgp` roles. The system role applies the modeled
hostname and banners; the device example includes login and MOTD banners.
IS-IS remains a no-op unless
`isis.processes` is supplied in the effective model. BGP is a no-op unless
`bgp` is supplied.
The `iosxr_l3_interfaces` role consumes a list of named interfaces. Each entry
can define IPv4 addresses, IPv6 addresses, or both; the same structure applies
to physical interfaces and loopbacks. Interface descriptions and Ethernet MTU
are modeled separately under `interfaces`, using the same interface names;
the collection supports MTU on Ethernet interfaces, not loopbacks. Set
`enabled: true` to issue `no shutdown` or `enabled: false` to issue `shutdown`;
omit it to leave the current administrative state unchanged. The device example
models both address families and descriptions on a physical interface and
`Loopback0`, enables both, and sets MTU on the physical interface:

```yaml
interfaces:
  - name: GigabitEthernet0/0/0/1
    description: << To mtc-core-02 gi0/0/0/2 >>
    enabled: true
    mtu: 1500
  - name: Loopback0
    description: << Router ID >>
    enabled: true
l3_interfaces:
  - name: GigabitEthernet0/0/0/1
    ipv4:
      - address: 198.19.1.0/31
    ipv6:
      - address: 2001:db8:5555:2000::1/64
  - name: Loopback0
    ipv4:
      - address: 198.19.0.1/31
    ipv6:
      - address: 2001:db8:5555::1/128
```

### Stage 1 validation

The interface roles were applied to the IOS XRd 26.1.1 test device `ix-pop`.
Both modeled interfaces reported `up/up`; the running configuration matched
the model, and a subsequent L3 merge reported no changes.

The NTP role applies the effective structured server list with
`cisco.iosxr.iosxr_ntp_global` in `merged` state. It checks `show version` and
skips NTP on IOS XRd, where the NTP CLI is not available on the test image. The
ix-pop provider model specifies `198.18.128.1` through VRF `management`. The
`vrf` property is optional and belongs to each server entry:
use the exact VRF name configured on the device (for example, `mgmt`), or omit
`vrf` to configure the server in the global routing table. The role passes
these entries directly to the collection module. For example:

```yaml
ntp:
  servers:
    - server: 198.18.128.1
      vrf: mgmt
    - server: 192.0.2.123
```

This state adds or updates modeled servers but does not remove previously
configured servers that are absent from the model.

### IS-IS modeling

The installed `cisco.iosxr` collection does not provide an IS-IS resource
module, so `iosxr_isis` uses `cisco.iosxr.iosxr_config` with structured process
and interface data. The separate [`examples/isis-model.yaml`](examples/isis-model.yaml)
shows an L2-only provider process with a NET, IPv4/IPv6 unicast address
families, wide metrics, a passive loopback, and a point-to-point physical
interface. It is deliberately not loaded by the `ix-pop` example inventory or
the `ix-pop` model; use it only with an IOS-XR device intended for IS-IS. The
default playbook includes the role, but it does nothing without an IS-IS process
in the effective model. No IS-IS configuration or adjacency was tested on the
CML XRd device.

### BGP modeling

`iosxr_bgp` composes the installed IOS-XR BGP global, address-family,
neighbor-address-family, and templates modules. Its process-level
`address_families` list explicitly activates AFs under `router bgp` before
peer configuration; AFs under a peer group separately configure that group's
per-neighbor policy. The `ix-pop` host model uses
local AS 64520 and one eBGP peer in AS 64521 over IPv4 `198.19.1.1` and IPv6
`2001:db8:5555:2000::2`, with IPv4/IPv6 unicast in the default VRF. It sets
the explicit `EBGP-ACCEPT-ALL` route policy in both directions for each AF.
That policy contains `pass`, so it permits every route; it is intentionally
limited to this isolated CML test device and is not an appropriate production
policy without deliberate route filtering. Both sessions inherit the remote AS
and address-family policies from the `EBGP-AS64521` neighbor group. The role
derives the BGP router ID from the configured IPv4 address on the modeled
`router_id_interface` (default `Loopback0`); if that interface or its IPv4
address is not modeled, it warns and omits the router ID.

Route policies are mappings keyed by policy name, so recursive scope merging
preserves policies declared at broader scopes and lets a host add or override
one by name. `EBGP-ACCEPT-ALL` is defined in `group_vars/all.yaml` and inherited
by the CML device. Attach each policy under the relevant peer-group or neighbor
address family; defining a policy alone does not apply it. For example, a host
can add a route policy with multiple conditional branches:

```yaml
bgp:
  route_policies:
    SET-COMMUNITY-EXAMPLE:
      statements: |-
        if destination in (PFX-SET-A) then
          set community (65000:111) additive
          pass
        elseif destination in (PFX-SET-B) then
          set community (65000:222) additive
          pass
        else
          pass
        endif
```

Policy bodies are multiline IOS-XR RPL, preserving indentation and control-flow
keywords such as `if`, `elseif`, `else`, and `endif`. This example references
prefix sets that will be modeled separately; it is illustrative and is not
loaded on `ix-pop`.

The BGP model was deployed to `ix-pop`; running configuration includes router
ID `198.19.0.1`, global IPv4/IPv6 unicast, the neighbor group, both peers, and
the explicit accept-all policies. A subsequent playbook run reported no
changes. At validation time, the IPv4 peer was `Idle` and the IPv6 peer was
`Active`, so session establishment and route exchange remain unverified.

The same model supports iBGP by setting a peer's AS to the local AS and, for
loopback-sourced sessions, setting `update_source` on its peer group. Global
AF-level settings use `address_families` entries with an optional `vrf`; per-
neighbor activation and policy use `neighbor_address_families`, with a `vrfs`
list containing peers and their AFs. For example, an iBGP peer can carry both
AFs in multiple VRFs:

```yaml
neighbor_address_families:
  vrfs:
    - vrf: CUSTOMER_A
      neighbors:
        - neighbor_address: "{{ bgp_route_reflector }}"
          address_family:
            - afi: ipv4
              safi: unicast
              route_policy:
                inbound: CUSTOMER-A-V4-IN
                outbound: CUSTOMER-A-V4-OUT
              maximum_prefix:
                max_limit: 1000
                threshold_value: 80
            - afi: ipv6
              safi: unicast
              route_policy:
                inbound: CUSTOMER-A-V6-IN
                outbound: CUSTOMER-A-V6-OUT
              maximum_prefix:
                max_limit: 1000
                threshold_value: 80
    - vrf: CUSTOMER_B
      neighbors:
        - neighbor_address: "{{ bgp_route_reflector }}"
          address_family:
            - afi: ipv4
              safi: unicast
            - afi: ipv6
              safi: unicast
```

Peer-group address families can opt into SRv6 encapsulation:

```yaml
peer_groups:
  - name: SRV6-CORE
    address_family:
      - afi: ipv4
        safi: unicast
        encapsulation_type_srv6: true
```

The installed templates module accepts but does not merge that SRv6 field, so
the role applies it with a narrow `iosxr_config` fallback. SRv6 locator and
service configuration is separate from BGP and needs its own platform
configuration and device-specific validation.

Reference: [NetAsCode IOS-XR data models](https://netascode.cisco.com/docs/data_models/iosxr/).

## Checks

- `make ansible-lint` runs Ansible linting in the UV-managed project environment.
- `make markdown-lint` checks Markdown with `markdownlint-cli2`.
- `make lint` runs both linters.
- Pre-commit runs both lint checks on every commit; `uv run pre-commit run --all-files`
  runs them manually across the repository.
- `make syntax-check` checks playbook syntax without connecting to devices.
