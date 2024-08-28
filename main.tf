terraform {
    required_providers {
        kubernetes = {
            source  = "hashicorp/kubernetes"
            version = ">= 2.0.0"
        }
    }
}

provider "kubernetes" {
    config_path = var.kubeconfig
}

resource "kubernetes_namespace" "zuul" {
    metadata {
        name = "zuul"
    }
}

resource "kubernetes_secret" "tenant_config" {
    metadata {
        name = "zuul-tenant-config"
        namespace = kubernetes_namespace.zuul.metadata[0].name
    }
    data = {
        "main.yaml" = "${file("${path.module}/tenant-config.yaml")}"
    }
}

resource "kubernetes_service" "mysql" {
    metadata {
        name = "mysql"
        labels = {
            k8s-app = "mysql"
        }
        namespace = kubernetes_namespace.zuul.metadata[0].name
    }
    spec {
        selector = {
            k8s-app = "mysql"
        }
        port {
            port = 3306
            name = "client"
        }
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
                storage_class_name = var.storage_class_name

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
        namespace = kubernetes_namespace.zuul.metadata[0].name
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
        namespace = kubernetes_namespace.zuul.metadata[0].name
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

resource "kubernetes_service" "zookeeper_cs_tls" {
    metadata {
        name = "zk-cs-tls"
        labels = {
            k8s-app = "zookeeper"
        }
        namespace = kubernetes_namespace.zuul.metadata[0].name
    }
    spec {
        selector = {
            k8s-app = "zookeeper"
        }
        port {
            port = "2281"
            name = "client-tls"
        }
    }
}

resource "kubernetes_pod_disruption_budget_v1" "zookeeper_pdb" {
    metadata {
        name = "zk-pdb"
        namespace = kubernetes_namespace.zuul.metadata[0].name
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
                init_container {
                    name = "keystore-set-up"
                    image = "busybox:latest"
                    command = [
                        "sh",
                        "-c",
                        "cat /tls/client/tls.crt /tls/client/tls.key > /var/lib/zookeeper/zookeeper-client-tls.pem && chown 1000:1000 /var/lib/zookeeper/zookeeper-client-tls.pem"
                    ]
                    volume_mount {
                        name = "datadir"
                        mount_path = "/var/lib/zookeeper"
                    }
                    volume_mount {
                        name = "zookeeper-client-tls"
                        mount_path = "/tls/client"
                        read_only = "true"
                    }
                }
                init_container {
                    name = "truststore-set-up"
                    image = "busybox:latest"
                    command = [
                        "sh",
                        "-c",
                        "cp /tls/client/ca.crt /var/lib/zookeeper/ca.pem && chown 1000:1000 /var/lib/zookeeper/ca.pem"
                    ]
                    volume_mount {
                        name = "datadir"
                        mount_path = "/var/lib/zookeeper"
                    }
                    volume_mount {
                        name = "zookeeper-client-tls"
                        mount_path = "/tls/client"
                        read_only = "true"
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
                        container_port = 2281
                        name = "client-tls"
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
                        name = "ZOO_STANDALONE_ENABLED"
                        value = "false"
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
                        value = "heap=512M logLevel=INFO maxClientCnxns=60 secureClientPort=2281 ssl.keyStore.location=/var/lib/zookeeper/zookeeper-client-tls.pem ssl.trustStore.location=/var/lib/zookeeper/ca.pem ssl.hostnameVertification=false serverCnxnFactory=org.apache.zookeeper.server.NettyServerCnxnFactory"

                    }

                    env {
                        name = "ZOO_MAX_CLIENT_CNXNS"
                        value = "60"
                    }

                    volume_mount {
                        name        = "datadir"
                        mount_path  = "/var/lib/zookeeper"
                    }

                    volume_mount {
                        name        = "zookeeper-server-tls"
                        mount_path  = "/tls/server"
                        read_only   = "true"
                    }

                    volume_mount {
                        name        = "zookeeper-client-tls"
                        mount_path  = "/tls/client"
                        read_only   = "true"
                    }
                }
                security_context {
                    run_as_user = 1000
                    fs_group    = 1000
                }
                volume {
                    name = "zookeeper-server-tls"
                    secret {
                        secret_name = "zookeeper-server-tls"
                    }
                }
                volume {
                    name = "zookeeper-client-tls"
                    secret {
                        secret_name = "zookeeper-client-tls"
                    }
                }
            }
        }
        volume_claim_template {
            metadata {
                name = "datadir"
            }

            spec {
                access_modes = ["ReadWriteOnce"]
                storage_class_name = var.storage_class_name
                resources {
                    requests = {
                        storage = "10Gi"
                    }
                }
            }
        }
    }
}

resource "kubernetes_service" "zuul_executor" {
    metadata {
        name = "zuul-executor"
        labels = {
            k8s-app                         = "zuul"
            "app.kubernetes.io/part-of"     = "zuul"
            "app.kubernetes.io/component"   = "zuul-executor"
        }
        namespace = kubernetes_namespace.zuul.metadata[0].name
    }

    spec {
        type        = "ClusterIP"
        cluster_ip  = "None"
        port {
            name        = "logs"
            port        = "7900"
            protocol    = "TCP"
            target_port = "logs"
        }
        selector = {
            k8s-app                         = "zuul"
            "app.kubernetes.io/part-of"     = "zuul"
            "app.kubernetes.io/component"   = "zuul-executor"
        }
    }
}

resource "kubernetes_service" "zuul_web" {
    metadata {
        name = "zuul-web"
        labels = {
            k8s-app                         = "zuul"
            "app.kubernetes.io/part-of"     = "zuul"
            "app.kubernetes.io/component"   = "zuul-web"
        }
        namespace = kubernetes_namespace.zuul.metadata[0].name
    }
    spec {
        type = "NodePort"
        port {
            name        = "zuul-web"
            port        = "9000"
            protocol    = "TCP"
            target_port = "zuul-web"
        }
        selector = {
            k8s-app                         = "zuul"
            "app.kubernetes.io/part-of"     = "zuul"
            "app.kubernetes.io/component"   = "zuul-web"
        }
    }
}

resource "kubernetes_service" "zuul_fingergw" {
    metadata {
        name = "zuul-fingergw"
        labels = {
            k8s-app                         = "zuul"
            "app.kubernetes.io/part-of"     = "zuul"
            "app.kubernetes.io/component"   = "zuul-fingergw"
        }
        namespace = kubernetes_namespace.zuul.metadata[0].name
    }
    spec {
        type = "NodePort"
        port {
            name        = "zuul-fingergw"
            port        = "9079"
            protocol    = "TCP"
            target_port = "zuul-web"
        }
        selector = {
            k8s-app                         = "zuul"
            "app.kubernetes.io/part-of"     = "zuul"
            "app.kubernetes.io/component"   = "zuul-fingergw"
        }
    }
}


resource "kubernetes_config_map" "zuul_config" {
    metadata {
        name = "zuul-config"
        namespace = kubernetes_namespace.zuul.metadata[0].name
    }
    data = {
        "zuul.conf" = "${file("${path.module}/zuul.conf")}"
    }
}

resource "kubernetes_stateful_set" "zuul_scheduler" {
    metadata {
        name = "zuul-scheduler"
        labels = {
            k8s-app                         = "zuul"
            "app.kubernetes.io/part-of"     = "zuul"
            "app.kubernetes.io/component"   = "zuul-scheduler"
        }
        namespace = kubernetes_namespace.zuul.metadata[0].name
    }
    spec {
        replicas = 1
        service_name = "zuul-scheduler"
        selector {
            match_labels = {
                k8s-app                         = "zuul"
                "app.kubernetes.io/part-of"     = "zuul"
                "app.kubernetes.io/component"   = "zuul-scheduler"
            }
        }
        template {
            metadata {
                labels = {
                    k8s-app                         = "zuul"
                    "app.kubernetes.io/part-of"     = "zuul"
                    "app.kubernetes.io/component"   = "zuul-scheduler"
                }
            }
            spec {
                container {
                    name = "scheduler"
                    image = "quay.io/zuul-ci/zuul-scheduler:9.1"
                    args = [
                        "/usr/local/bin/zuul-scheduler",
                        "-f",
                        "-d"
                    ]
                    volume_mount {
                        name = "zuul-config"
                        mount_path = "/etc/zuul"
                        read_only = "true"
                    }
                    volume_mount {
                        name = "zuul-tenant-config"
                        mount_path = "/etc/zuul/tenant"
                        read_only = "true"
                    }
                    volume_mount {
                        name = "zuul-scheduler"
                        mount_path = "/var/lib/zuul"
                    }
                    volume_mount {
                        name = "zookeeper-client-tls"
                        mount_path = "/tls/client"
                        read_only = "true"
                    }
                    env {
                        name = "ZUUL_MYSQL_PASSWORD"
                        value = "secret"
                    }
                    env {
                        name = "ZUUL_MYSQL_USER"
                        value = "zuul"
                    }
                }
                volume {
                    name = "zuul-config"
                    config_map {
                        name = kubernetes_config_map.zuul_config.metadata[0].name
                        items {
                            key = "zuul.conf"
                            path = "zuul.conf"
                        }
                    }
                }
                volume {
                    name = "zuul-tenant-config"
                    secret {
                        secret_name = "zuul-tenant-config"
                    }
                }
                volume {
                    name = "zookeeper-client-tls"
                    secret {
                        secret_name = "zookeeper-client-tls"
                    }
                }
            }
        }
        volume_claim_template {
            metadata {
                name = "zuul-scheduler"
            }

            spec {
                access_modes = [ "ReadWriteOnce" ]
                storage_class_name = var.storage_class_name
                resources {
                    requests = {
                        storage = "10Gi"
                    }
                }
            }
        }
    }
}

resource "kubernetes_deployment" "zuul_web" {
    metadata {
        name = "zuul-web"
        labels = {
            k8s-app                         = "zuul"
            "app.kubernetes.io/part-of"     = "zuul"
            "app.kubernetes.io/component"   = "zuul-web"
        }
        namespace = kubernetes_namespace.zuul.metadata[0].name
    }
    spec {
        replicas = "1"
        selector {
            match_labels = {
                k8s-app                         = "zuul"
                "app.kubernetes.io/part-of"     = "zuul"
                "app.kubernetes.io/component"   = "zuul-web"
            }
        }
        template {
            metadata {
                labels = {
                    k8s-app                         = "zuul"
                    "app.kubernetes.io/part-of"     = "zuul"
                    "app.kubernetes.io/component"   = "zuul-web"
                }
            }
            spec {
                container {
                    name = "web"
                    image = "quay.io/zuul-ci/zuul-web:9.1"
                    port {
                        name = "zuul-web"
                        container_port = "9000"
                    }
                    volume_mount {
                        name = "zuul-config"
                        mount_path = "/etc/zuul"
                    }
                    volume_mount {
                        name = "zookeeper-client-tls"
                        mount_path = "/tls/client"
                        read_only = "true"
                    }
                }
                volume {
                    name = "zuul-config"
                    config_map {
                        name = kubernetes_config_map.zuul_config.metadata[0].name
                        items {
                            key = "zuul.conf"
                            path = "zuul.conf"
                        }
                    }
                }
                volume {
                    name = "zookeeper-client-tls"
                    secret {
                        secret_name = "zookeeper-client-tls"
                    }
                }
            }
        }
    }
}

resource "kubernetes_deployment" "zuul_fingergw" {
    metadata {
        name = "zuul-fingergw"
        labels = {
            k8s-app                         = "zuul"
            "app.kubernetes.io/part-of"     = "zuul"
            "app.kubernetes.io/component"   = "zuul-fingergw"
        }
        namespace = kubernetes_namespace.zuul.metadata[0].name
    }
    spec {
        replicas = "1"
        selector {
            match_labels = {
                k8s-app                         = "zuul"
                "app.kubernetes.io/part-of"     = "zuul"
                "app.kubernetes.io/component"   = "zuul-fingergw"
            }
        }
        template {
            metadata {
                labels = {
                    k8s-app                         = "zuul"
                    "app.kubernetes.io/part-of"     = "zuul"
                    "app.kubernetes.io/component"   = "zuul-fingergw"
                }
            }
            spec {
                container {
                    name = "fingergw"
                    image = "quay.io/zuul-ci/zuul-fingergw:9.1"
                    port {
                        name = "zuul-fingergw"
                        container_port = "9079"
                    }
                    volume_mount {
                        name = "zuul-config"
                        mount_path = "/etc/zuul"
                    }
                    volume_mount {
                        name = "zookeeper-client-tls"
                        mount_path = "/tls/client"
                        read_only = "true"
                    }
                }
                volume {
                    name = "zuul-config"
                    config_map {
                        name = kubernetes_config_map.zuul_config.metadata[0].name
                        items {
                            key = "zuul.conf"
                            path = "zuul.conf"
                        }
                    }
                }
                volume {
                    name = "zookeeper-client-tls"
                    secret {
                        secret_name = "zookeeper-client-tls"
                    }
                }
            }
        }
    }
}

resource "kubernetes_stateful_set" "zuul_executor" {
    metadata {
        name = "zuul-executor"
        labels = {
            k8s-app                         = "zuul"
            "app.kubernetes.io/part-of"     = "zuul"
            "app.kubernetes.io/component"   = "zuul-executor"
        }
        namespace = kubernetes_namespace.zuul.metadata[0].name
    }
    spec {
        service_name = "zuul-executor"
        replicas = "1"
        pod_management_policy = "Parallel"
        selector {
            match_labels = {
                k8s-app                         = "zuul"
                "app.kubernetes.io/part-of"     = "zuul"
                "app.kubernetes.io/component"   = "zuul-executor"
            }
        }
        template {
            metadata {
                labels = {
                    k8s-app                         = "zuul"
                    "app.kubernetes.io/part-of"     = "zuul"
                    "app.kubernetes.io/component"   = "zuul-executor"
                }
            }
            spec {
                security_context {
                    run_as_user = "10001"
                    run_as_group = "10001"
                }
                container {
                    name = "executor"
                    image = "quay.io/zuul-ci/zuul-executor:9.1"
                    args = [
                        "/usr/local/bin/zuul-executor",
                        "-f",
                        "-d"
                    ]
                    port {
                        name = "logs"
                        container_port = "7900"
                    }
                    env {
                        name = "ZUUL_EXECUTOR_SIGTERM_GRACEFUL"
                        value = "1"
                    }
                    volume_mount {
                        name = "zuul-config"
                        mount_path = "/etc/zuul"
                    }
                    volume_mount {
                        name = "zuul-var"
                        mount_path = "/var/lib/zuul"
                    }
                    volume_mount {
                        name = "zookeeper-client-tls"
                        mount_path = "/tls/client"
                        read_only = "true"
                    }
                    security_context {
                        privileged = "true"
                    }
                }
                termination_grace_period_seconds = 300
                volume {
                    name = "zuul-var"
                    empty_dir {}
                }
                volume {
                    name = "zuul-config"
                    config_map {
                        name = kubernetes_config_map.zuul_config.metadata[0].name
                        items {
                            key = "zuul.conf"
                            path = "zuul.conf"
                        }
                    }
                }
                volume {
                    name = "zookeeper-client-tls"
                    secret {
                        secret_name = "zookeeper-client-tls"
                    }
                }
            }
        }
    }
}

resource "kubernetes_stateful_set" "zuul_merger" {
    metadata {
        name = "zuul-merger"
        labels = {
            k8s-app                         = "zuul"
            "app.kubernetes.io/part-of"     = "zuul"
            "app.kubernetes.io/component"   = "zuul-merger"
        }
        namespace = kubernetes_namespace.zuul.metadata[0].name
    }
    spec {
        service_name = "zuul-merger"
        replicas = 1
        pod_management_policy = "Parallel"
        selector {
            match_labels = {
                k8s-app                         = "zuul"
                "app.kubernetes.io/part-of"     = "zuul"
                "app.kubernetes.io/component"   = "zuul-merger"
            }
        }
        template {
            metadata {
                labels = {
                    k8s-app                         = "zuul"
                    "app.kubernetes.io/part-of"     = "zuul"
                    "app.kubernetes.io/component"   = "zuul-merger"
                }
            }
            spec {
                security_context {
                    run_as_user     = "10001"
                    run_as_group    = "10001"
                }
                container {
                    name = "merger"
                    image = "quay.io/zuul-ci/zuul-merger:9.1"
                    args = [
                        "/usr/local/bin/zuul-merger",
                        "-f",
                        "-d"
                    ]
                    volume_mount {
                        name = "zuul-config"
                        mount_path = "/etc/zuul"
                    }
                    volume_mount {
                        name = "zuul-var"
                        mount_path = "/var/lib/zuul"
                    }
                    volume_mount {
                        name = "zookeeper-client-tls"
                        mount_path = "/tls/client"
                        read_only = "true"
                    }
                }
                termination_grace_period_seconds = 3600
                volume {
                    name = "zuul-var"
                    empty_dir {}
                }
                volume {
                    name = "zuul-config"
                    config_map {
                        name = kubernetes_config_map.zuul_config.metadata[0].name
                        items {
                            key = "zuul.conf"
                            path = "zuul.conf"
                        }
                    }
                }
                volume {
                    name = "zookeeper-client-tls"
                    secret {
                        secret_name = "zookeeper-client-tls"
                    }
                }
            }
            
        }
    }
}

resource "kubernetes_service" "zuul_preview" {
    metadata {
        name = "zuul-preview"
        labels = {
            k8s-app                         = "zuul"
            "app.kubernetes.io/part-of"     = "zuul"
            "app.kubernetes.io/component"   = "zuul-preview"
        }
        namespace = kubernetes_namespace.zuul.metadata[0].name
    }
    spec {
        type = "NodePort"
        port {
            name = "zuul-preview"
            port = "80"
            protocol = "TCP"
            target_port = "zuul-preview"
        }
        selector = {
            k8s-app                         = "zuul"
            "app.kubernetes.io/part-of"     = "zuul"
            "app.kubernetes.io/component"   = "zuul-preview"
        }
    }
}

resource "kubernetes_deployment" "zuul_preview" {
    metadata {
        name = "zuul-preview"
        labels = {
            k8s-app                         = "zuul"
            "app.kubernetes.io/part-of"     = "zuul"
            "app.kubernetes.io/component"   = "zuul-preview"
        }
        namespace = kubernetes_namespace.zuul.metadata[0].name
    }
    spec {
        replicas = 1
        selector {
            match_labels = {
                k8s-app                         = "zuul"
                "app.kubernetes.io/part-of"     = "zuul"
                "app.kubernetes.io/component"   = "zuul-preview"
            }
        }
        template {
            metadata {
                labels = {
                    k8s-app                         = "zuul"
                    "app.kubernetes.io/part-of"     = "zuul"
                    "app.kubernetes.io/component"   = "zuul-preview"
                }
            }
            spec {
                container {
                    name = "preview"
                    image = "quay.io/zuul-ci/zuul-preview:latest"
                    port {
                        name = "zuul-preview"
                        container_port = "80"
                    }
                    env {
                        name = "ZUUL_API_URL"
                        value = "http://zuul-web/"
                    }
                }
            }
        }
    }
}

resource "kubernetes_ingress_v1" "zuul_web_ingress" {
    wait_for_load_balancer = true
    metadata {
        name = "zuul-web-ingress"
        namespace = kubernetes_namespace.zuul.metadata[0].name
    }

    spec {
        default_backend {
            service {
                name = kubernetes_service.zuul_web.metadata.0.name
                port {
                    number = kubernetes_service.zuul_web.spec.0.port.0.port
                }
            }
        }
        ingress_class_name = "nginx"
        rule {
            http {
                path {
                    backend {
                        service {
                            name = kubernetes_service.zuul_web.metadata.0.name
                            port {
                                number = kubernetes_service.zuul_web.spec.0.port.0.port
                            }
                        }
                    }
                    path = "/"
                }
            }
        }
    }
}

output "load_balancer_hostname" {
    value = kubernetes_ingress_v1.zuul_web_ingress.status.0.load_balancer.0.ingress.0.hostname
}

output "load_balancer_ip" {
    value = kubernetes_ingress_v1.zuul_web_ingress.status.0.load_balancer.0.ingress.0.ip
}

