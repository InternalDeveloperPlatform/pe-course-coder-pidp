### Export needed env-vars for terraform
export TF_VAR_humanitec_org=$HUMANITEC_ORG
export TF_VAR_humanitec_token=$HUMANITEC_SERVICE_USER
# Variables for TLS in Terraform
export TF_VAR_tls_cert_string=$TLS_CERT_STRING
export TF_VAR_tls_key_string=$TLS_KEY_STRING

terraform -chdir=setup/terraform destroy -auto-approve