# Architecture and Planning

This document captures design decisions and validation context for future work on
this repository. Keep it current when the model, role boundaries, or test
strategy changes.

## Goals

- Model IOS-XR configuration as structured data under
  one `iosxr` root with defaults, global, named device groups, named devices,
  and named interface groups.
- Reuse model layers across devices while allowing device-group and device
  overrides; provider and region are group names rather than hard-coded scopes.
- Keep feature implementations in focused Ansible roles and use the installed
  `cisco.iosxr` resource modules where they cover the required configuration.
- Validate rendered configuration before applying it, then verify running and
  operational state on an appropriate CML topology.

The reusable example targets `ix-pop`; a temporary seven-router MTC topology
has also been used to validate basic configuration and enabled IS-IS setup.
The site play defaults to `provider_ix_pop`, with an `iosxr_target_hosts`
inventory-pattern override for other providers. Field-level model documentation
lives in [DATA_MODEL.md](DATA_MODEL.md).

## SSH Transport

Device access uses `ansible.netcommon.network_cli` with the libssh backend,
selected explicitly by `[persistent_connection] ssh_type = libssh` in
`ansible.cfg`. `ansible-pylibssh` replaces Paramiko as the project's runtime
dependency and must be installed in the Python environment running Ansible.
There is no automatic fallback to Paramiko. Inventory variables or environment
settings can override this project default and should be reviewed when migrating.
Password prompts and enabled host-key checking remain unchanged. Offline model,
rendering, lint, and syntax tests do not establish live SSH connectivity; validate
the transport separately against a reachable IOS-XR device.

## Model Layers and Merge Rules

The `iosxr_model` role collects independent `iosxr` fragments, then resolves
configuration in ascending precedence order:

1. `iosxr.defaults.configuration`
2. `iosxr.global.configuration`
3. `iosxr.device_groups.<name>.configuration` for each selected group
4. `iosxr.devices.<inventory_hostname>.configuration`

Devices and groups are mappings keyed by name. Separate files can contribute
different features to the same entry. This is an Ansible-oriented adaptation
of NetAsCode; exact schema compatibility is not currently guaranteed.

Inventory variables use directories, for example `group_vars/all/`,
`group_vars/provider_ix_pop/`, and `host_vars/ix-pop/`. Membership and feature
configuration live in separate files, so adding a device does not require
editing global configuration.

Ansible normally replaces repeated `iosxr` variables. The resolver bypasses
that loss by loading direct `.yaml`/`.yml` files individually under an isolated
namespace and combining their registered contributions. It does not rely on
`hash_behaviour=merge`. Connection variables remain ordinary inventory
variables; files without `iosxr` are ignored by assembly.

Default collection order is all-group directory, matching inventory-group
directories alphabetically, then the host directory; filenames are sorted
within each directory. Later fragments win within the same scope. Legacy
single-file model variables are not consumed. `iosxr_model_directories` can
replace discovery with an ordered list of absolute directories.

By default, modeled groups matching the host's inventory groups are selected
alphabetically. `devices.<name>.device_groups` explicitly replaces that
selection with an ordered list; later groups win, and `[]` disables group
inheritance. Unknown references fail. References do not load another group's
files: use inventory membership or explicit model directories to make those
definitions available. Ansible group priority does not change resolver order.

The merge is recursive for mappings. Lists replace inherited lists; they do not
append or merge by item. Use maps keyed by stable names for data that should
inherit additively across scopes. BGP route policies use this pattern: a policy
with the same name at a narrower scope overrides the inherited definition, and
new names add policies without removing shared ones. List replacement also
applies within a scope; split features, not entries of interface/server lists.

`interface_groups.<name>.configuration` provides interface metadata defaults.
Resolved `interfaces` entries can reference ordered `interface_groups` lists.
Group settings merge first; explicit interface settings win last. Unknown
references fail and membership is stripped from module input. This does not
yet extend to L3 addressing or protocol interface settings.

Feature roles consume `iosxr_effective_model`; they should not need to know
whether a value came from defaults, global, group, or device scope. The role
publishes `iosxr_model_effective`; a playbook alias preserves the existing
contract rooted at `iosxr.devices.configuration`. Keep secrets outside
inventory files.

## Protocol Participation

BGP and IS-IS require explicit effective `configuration.bgp.enabled: true` or
`configuration.isis.enabled: true`. Missing flags default to false. Inherited
AS numbers, peers, policies, and IS-IS processes alone do not activate a role.
The BGP gate covers all tasks, including shared route-policy configuration.

Activation merges with the same scope precedence as other configuration.
Put shared settings in defaults/global without activation; opt participating
devices in through a PE/core group or device flag. P routers require no BGP
stanza if no selected scope activates it. Do not activate BGP on a common
provider group containing both P and PE routers. Device-level false can override
a group opt-in. Protocols are independently controlled.

Existing models must add true flags to continue applying protocols; the example
BGP device and standalone IS-IS model have been migrated. Skipping management
does not remove existing router configuration. Other feature roles are unchanged.
`make model-test` checks activation inheritance and device overrides, and runs
protocol roles locally with populated data and absent/false flags to verify
they perform no device configuration. Enabled BGP initialization is also tested;
live protocol application and operational state still require topology testing.

## Role Boundaries

- `iosxr_model` collects model files and resolves device/group/interface
  inheritance. It performs no device access and is tagged `model` in the site
  playbook. `make model-check` resolves the example without configuring it.
- `iosxr_system` applies hostname and login/MOTD banners.
- `iosxr_l3_interfaces` configures interface metadata and L3 addresses. It uses
  `cisco.iosxr.iosxr_interfaces` for descriptions, enabled state, and Ethernet
  MTU, and `cisco.iosxr.iosxr_l3_interfaces` for IPv4/IPv6 addresses.
- `iosxr_ntp` uses `cisco.iosxr.iosxr_ntp_global`. It skips NTP on XRd because
  the CML XRd image rejects the NTP CLI used by the resource module.
- `iosxr_srv6` renders named locator prefixes using `iosxr_config`, gated by
  `srv6.enabled`. It runs before IS-IS; active IX-POP inventory does not enable it.
- `iosxr_isis` uses `cisco.iosxr.iosxr_config` because the installed collection
  has no IS-IS resource module. It is a no-op unless `isis.enabled` is true
  and `isis.processes` is modeled. `examples/isis-model.yaml` is a standalone
  design example, not part of the active CML host model. Processes are rendered
  through one hierarchical template, including interface AF subcommands.
- `iosxr_bgp` combines the collection's BGP global, address-family,
  neighbor-address-family, and templates modules with `iosxr_config` where
  required by the installed collection's behavior. All tasks require
  `bgp.enabled: true`.

Prefer a collection resource module for a feature when it accurately handles
that feature. Use generic CLI configuration narrowly when no resource module
exists or when a verified collection limitation prevents the needed config.
Keep platform-specific fallbacks isolated and idempotent.

## IS-IS Model

IS-IS process AFs support metric style and `microloop_avoidance`.
No `multi-topology` command is emitted for IOS-XR. Interface AFs accept legacy
family strings or mappings with
`name` and ordered `fast-reroute` command suffixes, including `per-prefix` and
`per-prefix ti-lfa`. AF names can include `unicast` without duplicating it.
Existing passive, circuit-type, and point-to-point attributes are preserved.

Interface `hello-padding: disable` renders explicitly at IS-IS interface scope.
Enabled IS-IS with modeled processes triggers `show version`; XRd active non-loopback
interfaces missing the field warn but do not fail or receive an implicit setting.
Passive interfaces and loopbacks are excluded. Explicit values remain user-owned.
Offline tests cover XRd versus non-XRd warnings, omission, and device fixtures
independent of the temporary MTC models.
Operational adjacency and virtual-link MTU checks remain necessary.

`microloop_avoidance` is a command suffix such as `segment-routing`, rendered
as `microloop avoidance <value>`. Omitted or empty values emit nothing; supported
options depend on the target platform. The old `microloop_avoidance_sr` boolean
is no longer consumed.

`process.j2` generates the process, interface, and AF hierarchy for a single
`iosxr_config` merge per process. False/omitted optional flags emit nothing;
this is not deletion semantics. Processes, interfaces, and AFs remain lists
with replacement inheritance. Explicit `isis.enabled` gating is unchanged.

Offline tests compare the exact requested configuration and cover the revised
device fixtures, legacy family strings, empty microloop values, and absence of
the unsupported `multi-topology` command. New commands still
require platform acceptance and operational verification, including adjacency,
IPv4/IPv6 routes, and TI-LFA repair paths. FRR/microloop options alone are not
complete SRv6 support; locators and IS-IS SRv6 advertisement remain separate.

## SRv6 Locator Model

`configuration.srv6.enabled` is an independent opt-in gate. Locators are a
name-keyed mapping with IPv6 CIDR `prefix` fields, allowing group activation
and per-device prefix overrides. The locator role precedes IS-IS and uses a
hierarchical CLI template because no dedicated collection resource module is
installed. This first slice implements only the supplied locator hierarchy.

IS-IS IPv6 process AFs reference local locators through `srv6.locators` lists.
Validation rejects undefined references, disabled local SRv6, and non-IPv6 AFs
before IS-IS device access. Locator checks validate name/CIDR shape and prefix
length, not full address validity, cross-device uniqueness, or summary allocation.
Existing recursive map/list-replacement semantics apply. There is no deletion
or auto-allocation behavior, and P routers do not need BGP enabled.

The isolated example and offline tests cover exact CLI hierarchy, group/device
composition, absent/disabled gating, and invalid references. IX-POP must not be
used for SRv6 deployment: it lacks support, and its active model is unchanged.
SRv6 SID formats, services, policies, and operational validation remain future
work. No live SRv6 configuration has been applied by this implementation.

## BGP Model

BGP lives under each scope's `configuration.bgp`, resolved to
`iosxr.devices.configuration.bgp` for roles, and currently supports:

- Local AS, a router-ID source interface, and process-level global AF
  activation.
- Named peer groups with remote AS, IPv4/IPv6 AF settings, and route policies.
- Global and per-VRF AF configuration through the corresponding collection
  modules.
- Individual global or VRF neighbors inheriting a peer group.
- Named route policies defined as a map from policy name to a multiline IOS-XR
  RPL body. Policies merge by name across model scopes. A policy must still be
  attached to a peer group or neighbor AF before it affects routes.
- Router ID derived from the first IPv4 address on `router_id_interface`,
  defaulting to `Loopback0`. If no modeled IPv4 address is found, the role warns
  and omits the router ID.

The CML example defines `EBGP-ACCEPT-ALL` globally and attaches it inbound and
outbound to both AFs in peer group `EBGP-AS64521`. Its body is `pass`; this is
intentionally limited to the isolated lab and must not be treated as a
production filtering policy. Production peers should use explicit prefix,
community, and other route-attribute filters appropriate to the service.

Multiline RPL bodies can contain nested conditions and multiple statements,
including `if`, `elseif`, `else`, and `endif`. The model/template preserves the
body indentation. Prefix-set modeling is not implemented yet; conditional
policy examples referring to prefix sets are documentation only until those
sets are modeled and deployed.

The installed BGP templates module accepts an SRv6 encapsulation option but
does not merge/render it. The role therefore uses a narrow `iosxr_config`
fallback for explicitly requested peer-group AF encapsulation. SRv6 locator
and service configuration are outside the current BGP role and require separate
modeling and device validation.

## CML Validation State

The current CML example device is `ix-pop` at `198.18.191.1`, running IOS XRd
26.1.1. The SSH username is stored in inventory; the password is supplied
interactively or through an external secret mechanism.

Verified configuration on this device includes:

- `GigabitEthernet0/0/0/1`, enabled, MTU 1500, IPv4 `198.19.1.0/31`, IPv6
  `2001:db8:5555:2000::1/64`.
- `Loopback0`, enabled, IPv4 `198.19.0.1/31`, IPv6
  `2001:db8:5555::1/128`.
- BGP AS 64520, router ID `198.19.0.1`, global IPv4/IPv6 unicast AFs,
  peer group `EBGP-AS64521`, and IPv4/IPv6 neighbors `198.19.1.1` and
  `2001:db8:5555:2000::2` in the default VRF.
- Both BGP neighbors inherit remote AS 64521 and the explicit accept-all
  inbound/outbound policy from the peer group.

The playbook has completed successfully and a repeat run reported no changes.
At last verification, the IPv4 peer was `Idle` and the IPv6 peer was `Active`;
BGP establishment and route exchange are not yet verified. The remote peer
router has not been configured as part of this repository's test run.

NTP is intentionally skipped on this XRd image. IS-IS has not been applied to
this device. Do not infer protocol adjacency or route exchange from successful
configuration alone.

The split-file refactor is validated offline by `make model-test`,
`make model-check`, syntax checks, and lint. Tests cover precedence, named
fragment preservation, list replacement, interface inheritance, undefined
device-group rejection, and the migrated example's configuration. The original
`ix-pop` validation above describes pre-refactor configuration. Subsequent MTC
validation on 2026-10-11 confirmed hostnames, inherited login banners, interface
attributes/addressing, and IS-IS setup when enabled. The displayed P-102 running
configuration includes the unique NET, both AFs, microloop avoidance, passive
loopback, point-to-point interfaces, and IPv6 FRR/TI-LFA commands.

The displayed neighbor table was empty; protocol adjacency and route exchange
are not established by that evidence. An interface showed 8983-byte padded
hellos and no received hellos. `hello-padding disable` was manually committed on
one interface and subsequently added to the model/renderer; no post-change
adjacency or recovery result is recorded here. NTP remains unvalidated on XRd,
and end-to-end SRv6/TI-LFA repair remains unverified.

## Review And Merge Readiness

The refactor review covered fragment loading, scope precedence, device selection,
interface groups, protocol opt-in, route-policy merging/rendering, hierarchical
IS-IS rendering, and XRd warning behavior. Tests now use stable example data or
self-contained fixtures rather than MTC files. The temporary MTC inventory has
been removed, and the site play no longer hard-codes that provider.

After inventory cleanup, `make model-test`, `make model-check`, `make lint`, and
`make syntax-check` passed. Keep local `.vscode`
settings and secrets out of the PR unless deliberately reviewed for inclusion.
The breaking migrations are per-directory `iosxr` fragments and explicit protocol
activation; see [DATA_MODEL.md](DATA_MODEL.md). Collection-version pinning,
complete model schema validation, and topology validation are not part of this
refactor. Configuration merges remain additive, not deletion/reconciliation.

## Next Topology Work

On the multi-router topology:

1. Define router inventory and device-group/device model layers without putting
   credentials in YAML.
2. Configure the remote AS 64521 router with the reciprocal IPv4/IPv6 interface
   addresses and matching eBGP neighbor settings.
3. Apply the model, then verify both peers reach `Established` and inspect
   received/advertised prefixes in IPv4 and IPv6.
4. Add prefix-set modeling before using the conditional community-policy
   example; verify matching and non-matching routes on both directions.
5. Add a separate iBGP scenario and validate loopback sourcing, multihop, and
   internal policy behavior.
6. Add VRF AF scenarios and verify neighbor AFs and route isolation per VRF.
7. Plan SRv6 locator, service, and BGP signaling together; the current SRv6
   peer-group option alone is not a complete SRv6 deployment.
8. Verify IS-IS neighbors and IPv4/IPv6 routes after hello-padding changes;
  then test failure/recovery and TI-LFA repair paths on a suitable topology.

## Working Practices for Future Changes

- Read this file, the README, and the current model/role files before changing
  protocol behavior; preserve any uncommitted user edits.
- Use offline resource-module rendering and playbook syntax/lint checks first.
- Use `--check` before applying a broad playbook to CML. For live tests, scope
  changes to the intended host/feature and verify running configuration.
- After routing changes, check operational protocol state and routes separately
  from configuration state. Report sessions that are not established.
- Do not configure example RPL that references prefix sets until those sets are
  present in the effective model.
- Do not commit secrets or use the lab's accept-all route policy outside the
  isolated example.
