.PHONY: sync collections pre-commit-install ansible-lint markdown-lint lint syntax-check

sync:
	uv sync --group lint

collections:
	ansible-galaxy collection install -r requirements.yaml -p .ansible/collections --force

pre-commit-install:
	uv run pre-commit install

ansible-lint:
	uv run --group lint ansible-lint

markdown-lint:
	markdownlint-cli2 "**/*.md"

lint: ansible-lint markdown-lint

syntax-check:
	ansible-playbook --syntax-check -i inventories/example/hosts.yaml playbooks/site.yaml
