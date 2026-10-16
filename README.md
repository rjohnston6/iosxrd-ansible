# IOS-XR Ansible

Reusable Ansible playbooks and roles for configuring Cisco IOS-XR devices from
structured host and group variables.

## Prerequisites

- Python and [UV](https://docs.astral.sh/uv/)
- `libssh` installed on the system (e.g., `brew install libssh` on macOS)
- Ansible and `ansible-pylibssh` installed in the same active environment
- `markdownlint-cli2` available on `PATH` for Markdown checks

> [!NOTE]
> On macOS (Apple Silicon), `uv sync` may fail to find `libssh` headers. This is expected when using brew for package management.
> Set the following environment variables before syncing:
>
> ```bash
> export CFLAGS="-I$(brew --prefix libssh)/include"
> export LDFLAGS="-L$(brew --prefix libssh)/lib"
> uv sync --group lint
> ```

## Getting started

1. Install the project lint and pre-commit dependencies with `uv sync --group lint`.
2. Install the required Ansible collections into the ignored local collection
  directory with `make collections`.
3. Enable the Git commit hooks with `make pre-commit-install`.
4. Update `inventories/example/hosts.yaml` with your device address and the
  model variables under `inventories/example/group_vars/` and `host_vars/`.
5. Run `make syntax-check` to validate the playbook, then run it against the
  reachable device with `ansible-playbook playbooks/site.yaml --ask-pass`.

### SSH backend

`network_cli` uses libssh via `ansible-pylibssh`. The project dependency and
lockfile install the binding with `uv sync --group lint`; `ansible.cfg` explicitly
sets `[persistent_connection] ssh_type = libssh`, without automatic Paramiko
fallback. Password prompting with `--ask-pass` remains unchanged, and host-key
checking remains enabled.

If Ansible is installed separately as a UV tool, install the binding into that
tool environment too:

```bash
uv tool install --with ansible-pylibssh ansible --force
```

Alternatively, use `uv run --group lint ansible-playbook` to run Ansible from
the project's lint environment, which also includes Ansible Core. Installing
the binding only in the project environment does not make it available to a
separately installed `ansible-playbook` executable. Existing inventory or
environment overrides selecting Paramiko must be removed or changed to libssh.

### Inventory and targeting

The example targets the CML test device `router-01` at `192.0.2.1`. Change the
address when using a different device. The inventory includes the non-secret
SSH username; supply passwords through the interactive prompt, Ansible Vault,
or an external secrets provider, not in inventory files.

The play defaults to inventory group `isp_core`. Select another provider
explicitly, then optionally narrow it with `--limit`:

```bash
ansible-playbook -i inventories/example/hosts.yaml playbooks/site.yaml \
  -e iosxr_target_hosts=my_provider --list-hosts
ansible-playbook -i inventories/example/hosts.yaml playbooks/site.yaml \
  -e iosxr_target_hosts=my_provider --limit my_router --check --diff -k
```

Replace `my_provider` and `my_router` with your inventory group and host names.
Remove `--check` to apply after inspecting the proposed changes. The temporary
MTC inventory has been removed; offline test fixtures are independent of it.

## Data model and roles

The model uses one `iosxr` root with `defaults`, `global`, `device_groups`,
`devices`, and `interface_groups`. Devices and groups are mappings keyed by
stable names, so separate files can contribute features to the same entry.
This is an Ansible-oriented adaptation of NetAsCode, not a guarantee of exact
schema compatibility. Each inventory group and host has a variable directory:

```text
inventories/example/
  hosts.yaml
  group_vars/
    all/
      connection.yaml
      route_policies.yaml
    isp_core/
      defaults.yaml
      devices.yaml
      ntp.yaml
  host_vars/
    router-01/
      system.yaml
      interfaces.yaml
      bgp.yaml
```

### Split files and precedence

Normal Ansible variable precedence can discard earlier definitions of `iosxr`.
The `iosxr_model` role loads each file into an isolated namespace and assembles
its contribution explicitly, without relying on `hash_behaviour=merge` or the
final inventory value of `iosxr`. Connection settings remain ordinary inventory
variables; files without `iosxr` contribute nothing to the model.

Default discovery reads direct `.yaml` and `.yml` children of `group_vars/all/`,
then directories for the host's inventory groups alphabetically, then
`host_vars/<inventory_hostname>/`. Files within each directory are sorted by
filename. Later fragments override earlier fragments within the same scope.
Missing directories are skipped. Legacy single-file group/host model variables
are not loaded. Set `iosxr_model_directories` to an ordered list of absolute
directories to load a separate model library instead of the default directories.

Collected configuration resolves from lowest to highest precedence:

1. `iosxr.defaults.configuration`
2. `iosxr.global.configuration`
3. Selected `iosxr.device_groups.<name>.configuration`, in order
4. `iosxr.devices.<inventory_hostname>.configuration`

Matching inventory group names select modeled device groups alphabetically by
default. A device's `device_groups` list replaces that selection with explicit
ordering; later groups win. `[]` disables group inheritance. Selected groups
must exist in the loaded model. A reference does not automatically load another
inventory group's directory: use inventory membership or explicit directories.

Mappings merge recursively. Configuration lists, including NTP servers,
interfaces, and banners, replace rather than append or merge by item, both
within a scope and across scopes. Split different features across files, but
keep each interface/server list together. Named route-policy mappings merge
additively. The example provider NTP list replaces the default list.

### Adding devices and groups

Add the device to its group in `hosts.yaml`, add a named device entry in that
group's `devices.yaml`, then create feature files in `host_vars/<device>/`.
No global configuration file needs to change. Explicit model membership can
be declared separately from feature configuration:

```yaml
iosxr:
  devices:
    router-01:
      device_groups:
        - isp_core
```

A separate group feature file contributes to the same named group:

```yaml
iosxr:
  device_groups:
    isp_core:
      configuration:
        ntp:
          servers:
            - server: 192.0.2.100
              vrf: management
```

### Interface groups

Interface groups provide reusable metadata for `configuration.interfaces`.
Referenced groups merge in list order, followed by explicit interface settings.
Undefined references fail validation; membership is stripped from module input:

```yaml
iosxr:
  interface_groups:
    uplink:
      configuration:
        enabled: true
        mtu: 9000
  devices:
    router-01:
      configuration:
        interfaces:
          - name: GigabitEthernet0/0/0/1
            interface_groups: [uplink]
            mtu: 1500
```

Interface-group inheritance currently covers metadata, not the separate
`l3_interfaces` addressing list or protocol interface configuration.

Feature roles consume only the resulting `iosxr_effective_model`, retaining
the internal `iosxr.devices.configuration` shape regardless of input scopes.
For field-level scope and feature documentation, see [DATA_MODEL.md](DATA_MODEL.md).
For architecture decisions, validation status, and topology work, see
[ARCHITECTURE.md](ARCHITECTURE.md).

The field guide's [customer VRF and L3VPN section](DATA_MODEL.md#customer-vrfs-and-l3vpn-services)
shows how global VPN AFs, VRF route targets, PE-CE interfaces, and per-VRF BGP
neighbors fit together.

The playbook includes `iosxr_system`, `iosxr_l3_interfaces`, `iosxr_ntp`,
`iosxr_isis`, and `iosxr_bgp` roles. The system role applies the modeled
hostname and banners; the device example includes login and MOTD banners.
IS-IS runs only with effective `isis.enabled: true` and modeled processes.
All BGP tasks, including route policies, require effective `bgp.enabled: true`.
Missing activation flags default to false, even when protocol data is inherited.

### Protocol participation

Keep shared BGP/IS-IS settings and route policies in defaults or global without
enabling them there. Enable protocols only for participating device groups or
individual devices. For example, a PE group can opt into both protocols:

```yaml
iosxr:
  device_groups:
    pe:
      configuration:
        bgp:
          enabled: true
        isis:
          enabled: true
```

P routers outside this group need no BGP stanza to skip inherited BGP settings
and policies. They can inherit `isis.enabled: true` from a separate core group.
Select these groups through inventory membership or the device's explicit
`device_groups` list, and ensure their definitions are in loaded directories.

Activation follows normal precedence: defaults, global, ordered device groups,
then device. A device-level `enabled: false` overrides an inherited opt-in.
If a shared provider/core group includes both P and PE routers, do not enable
BGP on that shared group; enable it on the PE-only group instead.

This is a behavior change: existing protocol models need `enabled: true` to
continue applying configuration. The example BGP device and standalone IS-IS
model have been updated. False or omitted flags skip management; they do not
remove existing protocol configuration from the router. Other features still
run normally.

### Interface configuration

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
    description: << To peer-router-02 gi0/0/0/2 >>
    enabled: true
    mtu: 1500
  - name: Loopback0
    description: << Router ID >>
    enabled: true
l3_interfaces:
  - name: GigabitEthernet0/0/0/1
    ipv4:
      - address: 192.0.2.0/31
    ipv6:
      - address: 2001:db8:acad::1/64
  - name: Loopback0
    ipv4:
      - address: 192.0.2.10/31
    ipv6:
      - address: 2001:db8:acad::10/128
```

### Customer VRFs and L3VPN services

`configuration.vrfs` is a map keyed by stable VRF identifiers. Each entry can
set a router-facing `name` from customer variables, then define IPv4/IPv6
route-target AFs, interfaces to bind, and optional BGP service settings. The
`iosxr_vrf` role uses the IOS-XR VRF-global, VRF-AF, and VRF-interface resource
modules. BGP VRF AFs use `iosxr_bgp_address_family`; custom BGP VRF RDs and
per-VRF SRv6 AF settings use narrow `iosxr_config` fallbacks because the
installed resource modules do not expose those fields.

See [examples/vrf-service-model.yaml](examples/vrf-service-model.yaml) for an
isolated customer L3VPN with interface assignment, import/export route targets,
BGP RD, and an SRv6 locator. It is not loaded by IX-POP inventory. The rendered
resource-module and fallback CLI checks run offline with `make model-test`; no
VRF or SRv6 service has been applied to IX-POP.

### Stage 1 validation

The interface roles were applied to the IOS XRd 26.1.1 test device `router-01`.
Both modeled interfaces reported `up/up`; the running configuration matched
the model, and a subsequent L3 merge reported no changes.

The NTP role applies the effective structured server list with
`cisco.iosxr.iosxr_ntp_global` in `merged` state. It checks `show version` and
skips NTP on IOS XRd, where the NTP CLI is not available on the test image. The
router-01 provider model specifies `192.0.2.100` through VRF `management`. The
`vrf` property is optional and belongs to each server entry:
use the exact VRF name configured on the device (for example, `mgmt`), or omit
`vrf` to configure the server in the global routing table. The role passes
these entries directly to the collection module. For example:

```yaml
ntp:
  servers:
    - server: 192.0.2.100
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
interface. It is deliberately not loaded by the `router-01` example inventory or
the `router-01` model; use it only with an IOS-XR device intended for IS-IS. The
default playbook includes the role, but it does nothing without
`isis.enabled: true` and an IS-IS process in the effective model.
IS-IS was not applied to the original `router-01` example. In the later MTC XRd
topology, basic configuration and enabled IS-IS setup were validated. This does
not establish adjacency, route exchange, or TI-LFA recovery; see the validation
record in [ARCHITECTURE.md](ARCHITECTURE.md).

Each IS-IS process is rendered as one hierarchical configuration by
`roles/iosxr_isis/templates/process.j2`. Process address families support
`metric_style` (default `wide`), `microloop_avoidance: segment-routing` for
`microloop avoidance segment-routing`. The microloop value is an IOS-XR command
suffix, allowing other platform-supported options. Omitted or empty microloop
values do not emit the optional command. No `multi-topology` command is emitted
for IOS-XR. The previous boolean
`microloop_avoidance_sr` field is no longer consumed.

Interface address families accept either the original strings (`ipv4`, `ipv6`)
or mappings. Names may include `unicast`; the role does not append it twice.
Mappings can supply an ordered `fast-reroute` list:

```yaml
isis:
  enabled: true
  processes:
    - name: CORE
      net: 49.0001.0000.0000.0011.00
      is_type: level-2-only
      address_families:
        - name: ipv4
          metric_style: wide
          microloop_avoidance: segment-routing
        - name: ipv6
          metric_style: wide
          microloop_avoidance: segment-routing
      interfaces:
        - name: Loopback0
          passive: true
          address_families:
            - name: ipv4 unicast
            - name: ipv6 unicast
        - name: GigabitEthernet0/0/0/0
          point_to_point: true
          address_families:
            - name: ipv6 unicast
              fast-reroute:
                - per-prefix
                - per-prefix ti-lfa
```

Place this under the chosen device or device group's `configuration`, and use
a unique NET per router. `passive`, `point_to_point`, and `circuit_type` remain
supported interface attributes. Process/interface/AF lists still replace
inherited lists rather than merge by name.

For IOS-XRd labs, explicitly configure `hello-padding: disable` on participating
GigabitEthernet IS-IS interfaces (at the same level as `point_to_point`), which
renders `hello-padding disable`. The role checks `show version` when IS-IS is enabled and processes
are modeled. On XRd, active non-loopback interfaces without a hello-padding
field produce a warning and configuration continues without injecting a default.
Passive interfaces and loopbacks do not warn. An explicit value is respected.
Disabling padding can avoid oversized hellos on virtual links; it is not proof
that adjacency will form. Check MTUs, peer configuration, and connectivity too.

Fast-reroute entries are IOS-XR command suffixes, not a generic CLI block; each
renders as `fast-reroute <entry>` within its interface AF. These controls alone
do not enable SRv6: locator configuration, IS-IS SRv6 advertisement, platform
support, and TI-LFA operation need separate modeling and device verification.
Configuration remains additive; omitting settings or setting a flag false does
not remove previously deployed commands. `make model-test` verifies exact CLI
rendering, legacy AFs, empty microloop values, device fixtures, and XRd warnings
offline. These tests do not validate router acceptance or operational recovery.

### SRv6 locators and IS-IS advertisement

SRv6 is independently opt-in with `configuration.srv6.enabled: true`.
Named `srv6.locators` mappings define each locator's `prefix`; groups can enable
SRv6 while devices supply their unique /64. The new `iosxr_srv6` role configures
locators before IS-IS. Under the IS-IS IPv6 process AF, `srv6.locators` is a list
of local locator names to advertise. Undefined references, non-IPv6 AFs, and
advertisements with disabled local SRv6 are rejected.

See [examples/srv6-model.yaml](examples/srv6-model.yaml) for a BGP-free P router
and [DATA_MODEL.md](DATA_MODEL.md) for scope/field details. The example is not
loaded by active inventory, and IX-POP remains unchanged because it does not
support SRv6. Rendering and reference tests are offline; no SRv6 deployment,
SID/service programming, or operational reachability is claimed.

### BGP modeling

`iosxr_bgp` composes the installed IOS-XR BGP global, address-family,
neighbor-address-family, and templates modules. Its process-level
`address_families` list explicitly activates AFs under `router bgp` before
peer configuration. Neighbor-group model entries use plural
`address_families`; the role converts them to the collection's singular
`address_family` input. AFs under a neighbor group separately configure that
group's per-neighbor policy, while `neighbor_address_families` configures
individual peers. The `router-01` host model uses
local AS 64520 and one eBGP peer in AS 64521 over IPv4 `192.0.2.2` and IPv6
`2001:db8:acad::2`, with IPv4/IPv6 unicast in the default VRF. It sets
the explicit `EBGP-ACCEPT-ALL` route policy in both directions for each AF.
That policy contains `pass`, so it permits every route; it is intentionally
limited to this isolated CML test device and is not an appropriate production
policy without deliberate route filtering. Both sessions inherit the remote AS
and address-family policies from the `EBGP-AS64521` neighbor group. Model input
uses `neighbor_groups` and a top-level `neighbors` list; the role maps these to
the collection's `neighbor` and `global.neighbors` inputs. Legacy `peer_groups`
and `global.neighbors` remain accepted when the preferred fields are absent; do
not define both forms together. The role derives the BGP router ID from the
configured IPv4 address on the modeled
`router_id_interface` (default `Loopback0`); if that interface or its IPv4
address is not modeled, it warns and omits the router ID.

For redundant route reflectors, set a unique `cluster_id` per router. Put
client behavior such as `route_reflector_client.set` and `next_hop_self.set`
under a neighbor group's address family. Model RR-to-RR peering as a direct
neighbor without the client flag and configure its AFs separately. The
[standalone route-reflector example](examples/bgp-route-reflector.yaml) shows
IPv4/VPNv4 AFs and this separation. The IX-POP example remains unchanged.

Route policies are mappings keyed by policy name, so recursive scope merging
preserves policies declared at broader scopes and lets a host add or override
one by name. `EBGP-ACCEPT-ALL` is defined in
`group_vars/all/route_policies.yaml` and inherited by the CML device.
Attach each policy under the relevant peer-group or neighbor
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
loaded on `router-01`.

The BGP model was deployed to `router-01`; running configuration includes router
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

Neighbor-group address families can opt into SRv6 encapsulation:

```yaml
neighbor_groups:
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
- `make model-test` verifies split fragments, precedence, interface groups,
  invalid references, migrated example configuration, and protocol participation
  gates without device access.
- `make model-check` resolves the example inventory only; configuration roles
  are excluded by `--tags model`, so it performs no device configuration.
