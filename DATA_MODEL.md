# IOS-XR Model Reference

This reference describes the models implemented by this repository. The input
is an Ansible-oriented adaptation of NetAsCode, not its exact schema. `iosxr`
is a mapping, not an array. Device and group names are mapping keys.

## Scopes

| Path under `iosxr` | Purpose |
| --- | --- |
| `defaults.configuration` | Lowest-precedence baseline for hosts loading the file |
| `global.configuration` | Shared configuration above defaults |
| `device_groups.<name>.configuration` | Configuration for selected modeled groups |
| `devices.<inventory_hostname>.configuration` | Highest-precedence device overrides |
| `devices.<inventory_hostname>.device_groups` | Optional ordered group selection |
| `interface_groups.<name>.configuration` | Reusable interface metadata |

Configuration can live at defaults, global, group, or device scope. A complete
device fragment looks like:

```yaml
iosxr:
  devices:
    router-01:
      device_groups: [provider, east, pe]
      configuration:
        hostname: router-01
```

The device key must match the Ansible inventory hostname, not its address or
the desired hostname. The filename does not select the modeled device.

## Files And Inheritance

The default loader reads direct `.yaml` and `.yml` files in this order:

1. `group_vars/all/`
2. The host's inventory-group directories, alphabetically
3. `host_vars/<inventory_hostname>/`

Filenames are sorted within each directory. Each fragment is loaded separately
so normal Ansible replacement of repeated `iosxr` variables cannot lose it.
Files without `iosxr` contribute no model. Missing directories contribute
nothing and may produce a fileglob warning. Nested directories and old
single-file group/host models are not discovered.

`iosxr_model_directories` replaces this discovery with an ordered list of
absolute directories. Ordinary connection variables still use Ansible inventory
precedence; they are not model data.

File location controls availability, not configuration scope. A defaults file
in a provider directory supplies defaults only to hosts that load that directory.
Separate east and west files in the same provider directory can define both
groups; each host inherits only the groups it selects. Defining a group does
not make it active, and referencing one does not load another directory.

After collection, configuration merges as:

```text
defaults < global < selected device groups in order < device
```

Without an explicit selection, modeled groups matching inventory membership
are selected alphabetically. `devices.<name>.device_groups` replaces that
selection; include the provider explicitly if it should still apply. Later
groups win, and `[]` disables group inheritance. Ansible group priority does
not change this order.

Mappings merge recursively. All lists replace, including lists within fragments
of the same scope. An empty mapping does not clear inherited keys. An empty
list replaces an inherited list, but does not delete existing router settings.
Policies keyed by name are additive; lists of interfaces, peers, processes,
and servers do not merge by name. Split features across files rather than
splitting individual entries of the same list across files.

## System

Fields below belong under the chosen scope's `configuration`:

```yaml
hostname: router-01
banners:
  - banner: login
    text: |-
      Authorized users only.
  - banner: motd
    text: |-
      Maintenance window in progress.
```

`hostname` is optional; omission skips hostname management. `banners` is an
optional list of `{banner, text}` entries. The example uses login and MOTD
banners, applied in present state. An inherited banner list is replaced as a
whole by a narrower list.

## Interfaces

Interface metadata and addresses are separate lists matched by interface name:

```yaml
interfaces:
  - name: GigabitEthernet0/0/0/0
    description: To core router
    enabled: true
    mtu: 9000
  - name: Loopback0
    enabled: true
l3_interfaces:
  - name: GigabitEthernet0/0/0/0
    ipv4: [{address: 198.19.3.0/31}]
    ipv6: [{address: '2001:db8:1000:1000::/127'}]
  - name: Loopback0
    ipv4: [{address: 198.19.2.1/32}]
    ipv6: [{address: '2001:db8:1000::1/128'}]
```

| Field | Behavior |
| --- | --- |
| `name` | Required IOS-XR interface name |
| `description` | Optional interface description |
| `enabled` | True issues no shutdown; false issues shutdown; omission leaves state alone |
| `mtu` | Ethernet MTU; do not apply to loopbacks |
| `interface_groups` | Ordered metadata-group references on an `interfaces` entry |
| `ipv4`, `ipv6` | Address lists on an `l3_interfaces` entry |

Use `/31` and `/127` for two-address P2P links, and normally `/32` and `/128`
for loopbacks. The role passes the resulting lists to collection resource
modules in merged state; it does not reconcile absent addresses by deleting them.

Interface groups use the top-level `iosxr.interface_groups` mapping:

```yaml
iosxr:
  interface_groups:
    core_link:
      configuration:
        enabled: true
        mtu: 9000
  devices:
    router-01:
      configuration:
        interfaces:
          - name: GigabitEthernet0/0/0/0
            interface_groups: [core_link]
            mtu: 1500
```

Groups merge in list order, then explicit interface settings win. Membership
is stripped before module input. This facility covers metadata only, not L3
addresses or IS-IS/BGP interface configuration. Unknown group references fail.

## Customer VRFs And L3VPN Services

VRFs use a name-keyed mapping at `configuration.vrfs`. Each VRF can define an
optional router-facing `name` (defaulting to its map key), interfaces to bind,
route targets per AF, and optional BGP service settings. This lets a stable
model key coexist with a name templated from customer data:

```yaml
vrfs:
  customer_a:
    name: "{{ customer.name }}"
    description: "{{ customer.name }} IPv4 L3VPN"
    interfaces:
      - GigabitEthernet0/0/0/0.101
    address_families:
      - afi: ipv4
        safi: unicast
        import_config:
          route_target: 64521:101
        export:
          route_target: 64521:101
    bgp:
      rd: 198.19.2.11:101
      address_families:
        - afi: ipv4
          safi: unicast
          srv6:
            locator: MAIN_LOCATOR
            allocation_mode: per-vrf
      neighbors:
        - neighbor: 192.168.2.2
          remote_as: 64530
          address_families:
            - afi: ipv4
              safi: unicast
              route_policy:
                inbound: EBGP-ACCEPT-ALL
                outbound: EBGP-ACCEPT-ALL
```

`iosxr_vrf` uses `iosxr_vrf_global`, `iosxr_vrf_address_family`, and
`iosxr_vrf_interfaces` for VRF metadata, route-target import/export, and
interface assignment. The `interfaces` list contains IOS-XR interface names;
IP addressing remains in `l3_interfaces`. VRF and BGP AF/list collections
replace inherited lists, consistent with the general model merge rules.

The nested `bgp` section is applied only when root `configuration.bgp.enabled`
is true. Per-VRF AF activation uses `iosxr_bgp_address_family`, with the VRF
name attached. The installed module only exposes automatic RD in its BGP VRF
schema, so a custom `bgp.rd` uses a narrow `iosxr_config` command. It also uses
`iosxr_config` for BGP-VRF SRv6 `segment-routing srv6`, locator, and allocation
mode because those fields are not in the resource-module schema. Per-VRF SRv6
requires global SRv6 enabled, a defined locator, and `allocation_mode: per-vrf`.

Per-VRF `bgp.neighbors` configures sessions with `iosxr_bgp_global` and nested
neighbor AFs with `iosxr_bgp_neighbor_address_family`, both scoped to the
router-facing VRF name. Use `neighbor` for the peer address and
`address_families` for its AF list; collection aliases `neighbor_address` and
`address_family` are also accepted, but do not supply both spellings. Session
fields such as `remote_as` and `description` pass through to the collection.
Referenced route policies must already exist or be defined in root
`configuration.bgp.route_policies`. An accept-all policy is suitable for lab
testing, not a production filtering policy.

The standalone [customer VRF service example](examples/vrf-service-model.yaml)
is not loaded into IX-POP inventory. `tests/vrfs.yaml` renders the collection
resource modules and checks the CLI fallback offline; no VRF or SRv6 customer
service has been applied to IX-POP.

## NTP

```yaml
ntp:
  servers:
    - server: 198.18.128.1
      vrf: management
    - server: 192.0.2.123
```

Each entry requires `server`; `vrf` is optional and must name an existing VRF.
Omission uses the global routing table. Lists replace inherited servers; the
resource module's merged state does not remove previously configured servers.
The role detects XRd with `show version` and skips NTP on the tested XRd image,
where the required CLI is unavailable. Empty or absent servers skip device access.

## Protocol Participation

`bgp.enabled` and `isis.enabled` default to false after model resolution. Set
true only on participating groups or devices. Configuration inheritance alone
does not activate protocols. All BGP tasks, including route policies, are gated.

Keep shared settings unactivated in defaults/global. A PE group can enable BGP;
a core group can enable IS-IS independently. P routers need no BGP stanza if
none of their selected scopes enables BGP. A device can override group activation
with false. Omission does not negate an inherited true value.

False means skip management, not remove or disable a running protocol.

## IS-IS

```yaml
isis:
  enabled: true
  processes:
    - name: CORE
      net: 49.0001.0000.0000.0001.00
      is_type: level-2-only
      address_families:
        - name: ipv4
          metric_style: wide
          microloop_avoidance: segment-routing
        - name: ipv6 unicast
          metric_style: wide
          microloop_avoidance: segment-routing
      interfaces:
        - name: Loopback0
          passive: true
          address_families: [ipv4, ipv6]
        - name: GigabitEthernet0/0/0/0
          circuit_type: level-2-only
          point_to_point: true
          hello-padding: disable
          address_families:
            - name: ipv4 unicast
            - name: ipv6 unicast
              fast-reroute: [per-prefix, per-prefix ti-lfa]
```

| Level | Fields |
| --- | --- |
| IS-IS | `enabled`; optional `processes` list |
| Process | Required `name`, unique `net`, and `is_type`; optional AF/interface lists |
| Process AF | Required `name`; `metric_style` defaults to wide; optional `microloop_avoidance` suffix |
| Interface | Required `name`; optional `passive`, `point_to_point`, `circuit_type`, `hello-padding`, AF list |
| Interface AF | Family string or mapping with `name` and optional `fast-reroute` suffix list |

Names such as `ipv6` normalize to `ipv6 unicast`; full AF names are preserved.
`microloop_avoidance: segment-routing` emits `microloop avoidance segment-routing`.
An omitted/empty option emits nothing. The old `microloop_avoidance_sr` boolean
is not supported. No `multi-topology` command is emitted for IOS-XR.

`hello-padding: disable` emits at interface scope. On enabled XRd IS-IS devices,
the role checks `show version` and warns if an active non-loopback interface
has no hello-padding field. It continues without injecting a setting. Explicit
values, passive interfaces, and loopbacks do not produce that warning.

Every fast-reroute entry emits `fast-reroute <suffix>` at interface AF scope.
These suffixes are platform CLI options, not full configuration blocks. The
role uses one hierarchical `iosxr_config` merge per process. Process lists
replace across scopes, so a device-specific NET requires a complete process
entry, not just a name and NET override.

FRR and microloop controls do not provide full SRv6 deployment. Locators,
IS-IS SRv6 advertisement, platform support, and repair-path verification remain
separate work. Omitting an option does not remove an existing CLI command.

## SRv6 Locators And Underlay

SRv6 uses `configuration.srv6` at any configuration scope. It defaults to
disabled. Groups can supply activation and reusable locator definitions; devices
should supply unique prefixes. Locator mappings merge by name across scopes:

```yaml
iosxr:
  device_groups:
    srv6_core:
      configuration:
        srv6:
          enabled: true
  devices:
    srv6-p-101:
      device_groups: [srv6_core]
      configuration:
        srv6:
          locators:
            MAIN_LOCATOR:
              prefix: 2001:db8:1f00:101::/64
```

The `iosxr_srv6` role renders `segment-routing / srv6 / locators` and each
`locator <name>` / prefix pair before the IS-IS role runs. Names may contain
letters, digits, and underscores; hyphens are rejected by validation. Prefix validation checks CIDR shape and length
range and uses Python's standard-library IPv6 parser. Locator prefixes are
rendered in canonical compressed form, so padded hextets such as `0011` become
`11`, matching IOS-XR running-config. Prefixes must be network-aligned CIDRs;
host bits are rejected. Uniqueness and summary allocation are not checked.
Allocate a unique /64 per node from the intended summary block; duplicates
across devices are not automatically detected.

Under a modeled IS-IS process's IPv6 AF, add:

```yaml
address_families:
  - name: ipv6
    metric_style: wide
    srv6:
      locators: [MAIN_LOCATOR]
```

This renders `segment-routing srv6` and the locator reference under IPv6 unicast.
IS-IS must also be enabled. References to undefined local locators, disabled
local SRv6, or non-IPv6-unicast AFs fail validation before IS-IS device access.
Empty/absent reference lists emit no advertisement block. The locator role has
its own opt-in gate; disabled SRv6 does not remove existing configuration.

The standalone [SRv6 example](examples/srv6-model.yaml) is a BGP-free P-router
model, not active inventory. It includes process identity to compose with the
existing IS-IS role; add the participating interfaces for your topology.
IS-IS process and AF lists still replace inherited lists, not merge by name.
No SRv6 data is added to IX-POP, which does not support SRv6. Tests run offline
only. This slice does not implement SID formats, services, SR policies, or
end-to-end repair; platform and operational validation remain required.

## BGP

| Field under `configuration.bgp` | Shape and purpose |
| --- | --- |
| `enabled` | Required true to run any BGP task |
| `as_number` | Local AS required for process, AF, and peer configuration |
| `cluster_id` | Optional route-reflector cluster ID, configured under the local BGP process |
| `router_id_interface` | Defaults to Loopback0; first modeled IPv4 address supplies router ID |
| `route_policies` | Mapping of policy name to `{statements: multiline RPL}` |
| `address_families` | Collection AF list with `afi`, `safi`, and optional `vrf` |
| `neighbor_groups` | Neighbor-group list with `name`, remote AS, update source, and `address_families` policy settings |
| `neighbors` | Global neighbor list with `neighbor_address`, optional `use.neighbor_group`, and peer settings |
| `global` | Additional BGP-global module data, including VRF settings |
| `neighbor_address_families` | Neighbor-AF module data, including per-VRF neighbor AFs |

`iosxr.global.configuration` is a model scope; `configuration.bgp.global` is
module input. They serve different purposes. The BGP role wraps module data
with `as_number` and applies resource modules in merged state. It maps
`neighbor_groups` to the collection's `neighbor` input and top-level `neighbors`
to `global.neighbors`. Within a model neighbor-group entry, use plural
`address_families`; the role normalizes it to the collection's singular
`address_family` key. The old singular group key and `peer_groups` field remain
compatibility aliases when their preferred fields are absent. Do not set both
top-level `neighbors` and `global.neighbors`.

Process `address_families` activate families under `router bgp`. A neighbor
group's `address_families` configures inherited group settings. The separate
`neighbor_address_families` field controls per-neighbor AF activation and
policy, including per-VRF peers. The collection module takes singular
`address_family` for each group, so the role translates the plural model field
before calling it. These are distinct layers; process AF activation does not
automatically activate an AF for every neighbor.

Example with separate IPv4 and IPv6 groups and peers:

```yaml
bgp:
  enabled: true
  as_number: 64520
  address_families:
    - afi: ipv4
      safi: unicast
    - afi: ipv6
      safi: unicast
  neighbor_groups:
    - name: CORE_V4
      remote_as: 64520
      address_families:
        - afi: ipv4
          safi: unicast
    - name: CORE_V6
      remote_as: 64520
      address_families:
        - afi: ipv6
          safi: unicast
  neighbors:
    - neighbor_address: 192.0.2.2
      use:
        neighbor_group: CORE_V4
    - neighbor_address: 2001:db8::2
      use:
        neighbor_group: CORE_V6
  neighbor_address_families:
    neighbors:
      - neighbor_address: 192.0.2.2
        address_family:
          - afi: ipv4
            safi: unicast
      - neighbor_address: 2001:db8::2
        address_family:
          - afi: ipv6
            safi: unicast
```

The AF lists under process, neighbor groups, and neighbor activation are
separate and intentional. Group `address_families` sets neighbor-group policy;
`neighbor_address_families` activates/policies each peer. Since these are lists,
the nearest scope's list replaces the inherited list. Keep each complete AF or
neighbor list together at the scope that owns it.

For redundant route reflectors, define each router's unique `cluster_id` at its
device scope. Put clients in a neighbor group with
`route_reflector_client: {set: true}` and any group-level `next_hop_self`
setting. Model the other RR as a direct neighbor without the client flag, then
activate its desired AFs under `neighbor_address_families`. See the standalone
[route-reflector example](examples/bgp-route-reflector.yaml). The role maps
`cluster_id` to IOS-XR's `bgp cluster-id` command using `iosxr_config`. This
avoids a collection parser limitation that fails to recognize dotted IPv4
cluster IDs in the running configuration and otherwise reports a change every
run. The task matches the command under the local `router bgp` process.

The checked-in `ix-pop` BGP fragment and README show the complete peer-group,
neighbor, IPv4/IPv6 AF, VRF, and SRv6 encapsulation shapes. Use the installed
collection's module documentation for additional resource-module fields.

Route policies merge by name across files and scopes. Broader policies remain
unless a narrower scope changes the same name. The field is `statements`, not
`statement`. Defining a policy configures it only when BGP is enabled; attachment
under a peer/group AF is still required to affect routes. The accept-all example
is for the isolated lab only. Prefix sets referenced by illustrative RPL are
not currently modeled.

Router-ID derivation warns and omits the derived value if its interface/IPv4
address is missing. For iBGP, use the local AS as remote AS and set the peer
group's `update_source` when sourcing from a loopback. SRv6 peer-group AF
encapsulation uses a narrow CLI fallback because of a collection limitation.

## Validation And Migration

`make model-test` tests resolution, policy rendering, protocol gating, IS-IS
rendering, and XRd warnings offline. Fixtures do not require the temporary MTC
inventory. `make model-check` only resolves the site target. `make lint` and
`make syntax-check` are required before deployment. Use `--list-hosts` and
`--check --diff` before applying to the intended topology.

The play defaults to `provider_ix_pop`; set `iosxr_target_hosts` to change its
inventory pattern. `--limit` narrows the selected pattern rather than expanding it.

Migrating from the old layout requires moving model data into per-group/host
directories, replacing `iosxr_model_defaults/provider/region/device` variables
with the appropriate `iosxr` scopes, keying devices by inventory hostname,
and explicitly enabling participating protocols. Keep passwords in prompts,
Vault, or an external secrets provider, not model files.

Validation is not a full schema or topology validator. Unknown feature keys can
be ignored, invalid CLI suffixes are rejected by the router, and duplicate
addresses/NETs are not automatically detected. Only modeled group references
have explicit reference validation. Collections are not version-pinned; rerun
offline and device validation after upgrades.
