variable "kubeconfig" {
  type = string
  default = "~/.kube/config"
  description = "Path to kubectl configuration file"
}

variable "storage_class_name" {
  type = string
  default = "csi-cinder-default"
  description = "Storage class name to use when creating volumes"
}
