.PHONY: sync collections pre-commit-install ansible-lint markdown-lint lint syntax-check model-test model-check

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

model-test:
	ansible-playbook -i inventories/example/hosts.yaml -i localhost, tests/model.yaml
	ansible-playbook -i localhost, tests/protocols.yaml
	ansible-playbook -i localhost, tests/isis.yaml
	ansible-playbook -i localhost, tests/srv6.yaml
	ansible-playbook -i localhost, tests/vrfs.yaml

model-check:
	ansible-playbook -i inventories/example/hosts.yaml playbooks/site.yaml --tags model
