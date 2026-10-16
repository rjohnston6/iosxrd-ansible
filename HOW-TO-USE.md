# How to Use this Project

This guide explains how to deploy and maintain this project for lab or production environments while keeping your sensitive network data separate from the public codebase.

## Architecture Overview

To ensure security and maintainability, this project separates **Logic** from **Data**:

- **Logic (Public Repo)**: Contains playbooks, roles, and the data model structure.
- **Data (Your Private Repo)**: Contains your actual device IPs, usernames, and passwords.

## Getting Started

### 1. Setup the Logic

Clone this repository to your management server or local workstation:

```bash
git clone <public-repo-url> iosxr-ansible
cd iosxr-ansible
uv sync --group lint
make collections
```

### 2. Setup your Private Configuration

Create a **separate, private Git repository** to store your production and lab inventories. This prevents sensitive network data from ever being accidentally pushed to a public repository.

**Recommended Private Repo Structure:**

```text
my-iosxr-configs/
  inventories/
    production/
      hosts.yaml
      group_vars/
      host_vars/
    lab/
      hosts.yaml
      group_vars/
      host_vars/
  secrets/
    vault-password
```

### 3. Managing Infrastructure

To run the playbooks using your private data, specify the path to your private inventory using the `-i` flag.

#### Example: Deploying to Lab

```bash
ansible-playbook -i ~/my-iosxr-configs/inventories/lab/hosts.yaml playbooks/site.yaml --check --diff
```

#### Example: Deploying to Production

```bash
ansible-playbook -i ~/my-iosxr-configs/inventories/production/hosts.yaml playbooks/site.yaml --ask-vault-pass
```

## Maintenance and Updates

### Updating the Logic (Public Repo)

When the public repository is updated with new features or roles:

```bash
git pull origin main
# Re-sync dependencies if pyproject.toml changed
uv sync --group lint 
```

Since your inventories are in a separate private repository, `git pull` will **never** overwrite your production data.

### Updating the Data (Private Repo)

Manage your device additions, IP changes, and password rotations within your private repository:

```bash
cd ~/my-iosxr-configs
git add .
git commit -m "Add new edge router to production"
git push origin main
```

## Summary of Workflow

| Action | Where to perform | Command |
| :--- | :--- | :--- |
| **Update Logic** | Public Repo | `git pull` |
| **Update Devices** | Private Repo | `git commit && git push` |
| **Apply Config** | Public Repo | `ansible-playbook -i <path-to-private-inv> ...` |
