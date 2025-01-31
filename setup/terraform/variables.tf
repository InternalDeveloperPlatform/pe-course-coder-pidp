variable "humanitec_org" {
  description = "The ID of the organization"
  default     = "humanitec"
  type        = string
}

variable "humanitec_token" {
  description = "Token for accessing Humanitec"
  default     = "humanitec"
  type        = string
}

variable "kubeconfig" {
  description = "Kubeconfig used by the Humanitec Agent / terraform"
  type        = string
  default     = "/home/vscode/state/kube/config-internal.yaml"
}

variable "tls_cert_string" {
  description = "Cert as string for TLS setup"
  type        = string
  default     = ""
}

variable "tls_key_string" {
  description = "Key as string for TLS setup"
  type        = string
  default     = ""
}