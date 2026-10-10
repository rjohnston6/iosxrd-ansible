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
4. Update `inventories/example/hosts.yaml` with your device addresses and
   `inventories/example/group_vars/iosxr_devices.yaml` with the desired model.
5. Run `make syntax-check` to validate the playbook, then run it against
   reachable devices with `ansible-playbook playbooks/site.yaml`.

The example inventory uses the documentation-only address `192.0.2.10`. Replace
it before running the playbook. Credentials should be supplied through Ansible
Vault or an external secrets provider, not committed to inventory files.

## Data model and roles

The example data model lives in inventory group variables. The `iosxr_system`
role reads `iosxr_system_config.hostname` and applies it with the IOS-XR
configuration module. Add feature data to the model and implement each feature
in a focused role; keep site/device-specific values in inventory rather than
embedding them in playbooks.

```text
inventories/
  example/
    hosts.yaml
    group_vars/
      iosxr_devices.yaml
playbooks/
  site.yaml
roles/
  iosxr_system/
    defaults/main.yaml
    tasks/main.yaml
```

## Checks

- `make ansible-lint` runs Ansible linting in the UV-managed project environment.
- `make markdown-lint` checks Markdown with `markdownlint-cli2`.
- `make lint` runs both linters.
- Pre-commit runs both lint checks on every commit; `uv run pre-commit run --all-files`
  runs them manually across the repository.
- `make syntax-check` checks playbook syntax without connecting to devices.
