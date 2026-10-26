# Cluster local (Rancher Desktop, k3s, kind...) ou qualquer kubeconfig. Estado local por padrão.
provider "kubernetes" {
  config_path    = pathexpand(var.kubeconfig)
  config_context = var.kube_context
}
