# Architecture and Planning

This document captures design decisions and validation context for future work on
this repository. Keep it current when the model, role boundaries, or test
strategy changes.

## Goals

- Model IOS-XR configuration as structured data under
  `iosxr.devices.configuration`.
- Reuse model layers across devices while allowing provider, region, and device
  overrides.
- Keep feature implementations in focused Ansible roles and use the installed
  `cisco.iosxr` resource modules where they cover the required configuration.
- Validate rendered configuration before applying it, then verify running and
  operational state on an appropriate CML topology.

The example inventory currently targets one CML device. It is a working
integration target for system, interface, banner, and BGP configuration, but it
is not a multi-router routing-protocol lab yet.

## Model Layers and Merge Rules

The playbook combines these variables in precedence order:

1. `iosxr_model_defaults` from `group_vars/all.yaml`
2. `iosxr_model_provider` from the matching provider group
3. `iosxr_model_region` from an optional region group
4. `iosxr_model_device` from the host variables

The merge is recursive for mappings. Lists replace inherited lists; they do not
append or merge by item. Use maps keyed by stable names for data that should
inherit additively across scopes. BGP route policies use this pattern: a policy
with the same name at a narrower scope overrides the inherited definition, and
new names add policies without removing shared ones.

Feature roles consume `iosxr_effective_model`; they should not need to know
whether a value came from global, provider, region, or host scope. Model all
configuration under `iosxr.devices.configuration` and keep secrets outside
inventory files.

## Role Boundaries

- `iosxr_system` applies hostname and login/MOTD banners.
- `iosxr_l3_interfaces` configures interface metadata and L3 addresses. It uses
  `cisco.iosxr.iosxr_interfaces` for descriptions, enabled state, and Ethernet
  MTU, and `cisco.iosxr.iosxr_l3_interfaces` for IPv4/IPv6 addresses.
- `iosxr_ntp` uses `cisco.iosxr.iosxr_ntp_global`. It skips NTP on XRd because
  the CML XRd image rejects the NTP CLI used by the resource module.
- `iosxr_isis` uses `cisco.iosxr.iosxr_config` because the installed collection
  has no IS-IS resource module. It is a no-op unless `isis.processes` is
  modeled. `examples/isis-model.yaml` is a standalone design example, not part
  of the active CML host model.
- `iosxr_bgp` combines the collection's BGP global, address-family,
  neighbor-address-family, and templates modules with `iosxr_config` where
  required by the installed collection's behavior.

Prefer a collection resource module for a feature when it accurately handles
that feature. Use generic CLI configuration narrowly when no resource module
exists or when a verified collection limitation prevents the needed config.
Keep platform-specific fallbacks isolated and idempotent.

## BGP Model

BGP lives at `iosxr.devices.configuration.bgp` and currently supports:

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

## Next Topology Work

When the additional CML routers are ready:

1. Define router inventory and provider/device model layers without putting
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
8. Test IS-IS on a suitable image/topology rather than the current XRd device,
   which is intentionally running without IS-IS.

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
