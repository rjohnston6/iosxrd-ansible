# Development Guide

This guide outlines the workflow for extending the IOS-XR Ansible project, adding new features, and validating changes against a test bed.

## Development Workflow

To maintain stability and security, follow this cycle for every change:
`Feature Idea` $\rightarrow$ `Local Model Update` $\rightarrow$ `Static Validation` $\rightarrow$ `Virtual Lab Test` $\rightarrow$ `Hardware Validation` $\rightarrow$ `Pull Request`.

### 1. Environment Setup

Ensure your local environment is synced and dependencies are installed:

```bash
uv sync --group lint
make collections
```

### 2. Local Configuration

Do not modify `inventories/example/`. Instead, create a local inventory for your test bed:

```bash
cp -r inventories/example inventories/local
```

Update `inventories/local/hosts.yaml` and the corresponding `host_vars` and `group_vars` with your actual lab device details. Since `inventories/local/` is git-ignored, your lab secrets remain private.

### 3. Implementing Changes

#### Adding a New Feature/Role

1. **Define the Data Model**: Add the necessary fields to `DATA_MODEL.md` and implement them in the YAML variables (defaults $\rightarrow$ global $\rightarrow$ device).
2. **Create the Role**: Implement the logic in `roles/<role_name>/`.
3. **Update the Playbook**: Add the role to `playbooks/site.yaml` or a specific feature playbook.

#### Updating Existing Logic

- Modify the role templates or tasks.
- Update the `iosxr_effective_model` consumption logic if the data structure changes.

### 4. Validation Pipeline

Before committing, run the following checks in order:

#### Phase A: Static Analysis (Fast)

Validate syntax and style to ensure the code is clean.

```bash
make lint          # Run ansible-lint and markdown-lint
make syntax-check  # Validate playbook syntax
```

#### Phase B: Model Validation (Offline)

Verify that the variable merge logic and precedence are working as expected without connecting to a device.

```bash
make model-test
```

#### Phase C: Integration Testing (Safe)

Run the playbook against your test bed in "Check Mode" to see exactly what would change without applying it.

```bash
ansible-playbook -i inventories/local/hosts.yaml playbooks/site.yaml --check --diff
```

#### Phase D: Hardware Validation (Live)

Apply the configuration to the test bed.

```bash
ansible-playbook -i inventories/local/hosts.yaml playbooks/site.yaml
```

### 5. Submission

1. **Sanitize**: Ensure no real IPs or secrets from `inventories/local/` accidentally leaked into `inventories/example/` or the code.
2. **Document**: Update `DATA_MODEL.md` or `ARCHITECTURE.md` if the logic changed.
3. **Commit**: Use descriptive commit messages and push your branch for review.
