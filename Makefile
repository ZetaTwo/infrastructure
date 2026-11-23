.PHONY: tf-init tf-plan tf-apply ansible-apply lint

tf-init:
	cd terraform && terraform init -backend-config=backend.hcl

tf-plan:
	cd terraform && terraform plan

tf-apply:
	cd terraform && terraform apply

# TAGS=<role>[,<role>...] applies only those roles (each role in site.yaml is
# tagged with its own name); without it, the whole playbook runs.
ansible-apply:
	cd ansible && ansible-playbook site.yaml --vault-password-file .vault_pass $(if $(TAGS),--tags $(TAGS))

lint:
	cd ansible && uvx --from ansible-core ansible-galaxy collection install -r requirements.yml
	cd ansible && uvx ansible-lint
