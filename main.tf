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
                            memory = "500Mi"
                        }

                        requests = {
                            cpu = "1000m"
                            memory = "500Mi"
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

resource "kubernetes_service" "zookeeper_hs" {
    metadata {
        name = "zk-hs"
        labels = {
            k8s-app = "zookeeper"
        }
    }

    spec {
        selector = {
            k8s-app = "zookeeper"
        }
        port {
            port = 2888
            name = "server"
        }
        port {
            port = 3888
            name = "leader-election"
        }
        cluster_ip = "None"
    }
}

resource "kubernetes_service" "zookeeper_cs" {
    metadata {
        name = "zk-cs"
        labels = {
            k8s-app = "zookeeper"
        }
    }

    spec {
        selector = {
            k8s-app = "zookeeper"
        }
        port {
            port = 2181
            name = "client"
        }
    }
}

resource "kubernetes_pod_disruption_budget_v1" "zookeeper_pdb" {
    metadata {
        name = "zk-pdb"
    }
    
    spec {
        selector {
            match_labels = {
                k8s-app = "zookeeper"
            }
        }
        max_unavailable = 1
    }
}

resource "kubernetes_stateful_set" "zookeeper" {
    metadata {
        labels = {
            k8s-app                             ="zookeeper"
            "kubernetes.io/cluster-service"     = "true"
            "addonmanager.kubernetes.io/mode"   = "Reconcile"
            version                             = "3"
        }
        name = "zookeeper"
        namespace = kubernetes_namespace.zuul.metadata[0].name
    }

    spec {
        pod_management_policy = "OrderedReady"
        replicas = 1
        revision_history_limit = 5

        selector {
            match_labels = {
              k8s-app = "zookeeper"
            }
        }

        service_name = "zk-hs"
        update_strategy {
            type = "RollingUpdate"
        }

        template {
            metadata {
                labels = {
                    k8s-app = "zookeeper"
                }
                annotations = {}
            }

            spec {
                affinity {
                    pod_anti_affinity {
                        required_during_scheduling_ignored_during_execution {
                            label_selector {
                                match_expressions {
                                    key = "k8s-app"
                                    operator = "In"
                                    values = ["zookeeper"]
                                }
                            }
                            topology_key = "kubernetes.io/hostname"
                        }
                    }
                }
                container {
                    name = "kubernetes-zookeeper"
                    image_pull_policy = "Always"
                    image = "zookeeper:3.9"
                    resources {
                        requests = {
                            memory  = "1Gi"
                            cpu     = "0.5"
                        }
                    }
                    port {
                        container_port = 2181
                        name = "client"
                    }

                    port {
                        container_port = 2888
                        name = "server"
                    }

                    port {
                        container_port = 3888
                        name = "leader-election"
                    }

                    env {
                        name = "ZOO_INIT_LIMIT"
                        value = "10"
                    }

                    env {
                        name = "ZOO_SYNC_LIMIT"
                        value = "5"
                    }

                    env {
                        name = "ZOO_CFG_EXTRA"
                        value = "heap=512M logLevel=INFO"
                    }

                    volume_mount {
                        name        = "datadir"
                        mount_path  = "/var/lib/zookeeper"
                    }
                }
                security_context {
                    run_as_user = 1000
                    fs_group    = 1000
                }
            }
        }
        volume_claim_template {
            metadata {
                name = "datadir"
            }

            spec {
                access_modes = ["ReadWriteOnce"]
                resources {
                    requests = {
                        storage = "10Gi"
                    }
                }
            }
        }
    }
}