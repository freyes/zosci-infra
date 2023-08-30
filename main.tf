terraform {
    required_providers {
        kubernetes = {
            source  = "hashicorp/kubernetes"
            version = ">= 2.0.0"
        }
    }
}

provider "kubernetes" {
    config_path = "~/.kube/config"
}

resource "kubernetes_namespace" "zuul" {
    metadata {
        name = "zuul"
    }
}

resource "kubernetes_stateful_set" "mysql" {
    metadata {
        labels = {
            k8s-app                           = "mysql"
            "kubernetes.io/cluster-service"   = "true"
            "addonmanager.kubernetes.io/mode" = "Reconcile"
            version                           = "8"
        }
        name = "mysql"
        namespace = kubernetes_namespace.zuul.metadata[0].name
    }

    spec {
        pod_management_policy   = "Parallel"
        replicas                = 1
        revision_history_limit  = 5

        selector {
          match_labels = {
            k8s-app = "mysql"
          }
        }

        service_name = "mysql"

        template {
            metadata {
              labels = {
                k8s-app = "mysql"
              }

              annotations = {}
            }

            spec {

                init_container {
                    name                = "init-chown-data"
                    image               = "busybox:latest"
                    image_pull_policy   = "IfNotPresent"
                    command             = ["chown", "-R", "65534:65534", "/var/lib/mysql"]

                    volume_mount {
                        name = "mysql-data"
                        mount_path = "/var/lib/mysql"
                        sub_path = ""
                    }
                }

                container {
                    name                = "mariadb-server"
                    image               = "mariadb:jammy"
                    image_pull_policy   = "IfNotPresent"
                    env {
                        name    = "MYSQL_ROOT_PASSWORD"
                        value   = "rootpassword"
                    }
                    env {
                        name = "MYSQL_DATABASE"
                        value = "zuul"
                    }
                    env {
                        name = "MYSQL_USER"
                        value = "zuul"
                    }

                    env {
                        name = "MYSQL_PASSWORD"
                        value = "secret"
                    }

                    env {
                        name = "MYSQL_INITDB_SKIP_TZINFO"
                        value = 1
                    }

                    port {
                        container_port = 3306
                    }

                    resources {
                        limits = {
                            cpu = "1000m"
                            memory = "2000Mi"
                        }

                        requests = {
                            cpu = "1000m"
                            memory = "2000Mi"
                        }
                    }

                    volume_mount {
                        name        = "mysql-data"
                        mount_path  = "/var/lib/mysql"
                        sub_path    = ""
                    }
                }
                termination_grace_period_seconds = 300
            }
        }

        update_strategy {
            type = "RollingUpdate"

            rolling_update {
                partition = 1
            }
        }

        volume_claim_template {
            metadata {
                name = "mysql-data"
            }

            spec {
                access_modes = ["ReadWriteOnce"]
                storage_class_name = "microk8s-hostpath"

                resources {
                    requests = {
                        storage = "10Gi"
                    }
                }
            }
        }
    }
}