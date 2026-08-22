.PHONY: tf-init tf-plan tf-apply ansible-apply lint

tf-init:
	cd terraform && terraform init -backend-config=backend.hcl

tf-plan:
	cd terraform && terraform plan

tf-apply:
	cd terraform && terraform apply

ansible-apply:
	cd ansible && ansible-playbook site.yaml --vault-password-file .vault_pass

lint:
	cd ansible && ansible-lint site.yaml
