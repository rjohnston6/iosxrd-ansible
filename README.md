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

The example includes `iosxr_system`, `iosxr_l3_interfaces`, and `iosxr_ntp`
roles. The system role applies the modeled hostname and banners; the device
example includes login and MOTD banners.
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

Reference: [NetAsCode IOS-XR data models](https://netascode.cisco.com/docs/data_models/iosxr/).

## Checks

- `make ansible-lint` runs Ansible linting in the UV-managed project environment.
- `make markdown-lint` checks Markdown with `markdownlint-cli2`.
- `make lint` runs both linters.
- Pre-commit runs both lint checks on every commit; `uv run pre-commit run --all-files`
  runs them manually across the repository.
- `make syntax-check` checks playbook syntax without connecting to devices.
