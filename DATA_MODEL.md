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

## BGP

| Field under `configuration.bgp` | Shape and purpose |
| --- | --- |
| `enabled` | Required true to run any BGP task |
| `as_number` | Local AS required for process, AF, and peer configuration |
| `router_id_interface` | Defaults to Loopback0; first modeled IPv4 address supplies router ID |
| `route_policies` | Mapping of policy name to `{statements: multiline RPL}` |
| `address_families` | Collection AF list with `afi`, `safi`, and optional `vrf` |
| `peer_groups` | Templates-module neighbor list with `name`, remote AS, update source, and AF policy settings |
| `global` | BGP-global module data, including global/VRF neighbors |
| `neighbor_address_families` | Neighbor-AF module data, including per-VRF neighbor AFs |

`iosxr.global.configuration` is a model scope; `configuration.bgp.global` is
module input. They serve different purposes. The BGP role wraps module data
with `as_number` and applies resource modules in merged state.

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
