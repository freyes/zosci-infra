# Deploy Zuul CI, MariaDB, and Apache Zookeeper
This repo contains a [Terraform](https://www.terraform.io) plan and configuration files you can use to deploy [Zuul CI](zuul-ci.org/) 9.1 and its dependencies - [MariaDB](https://mariadb.com) and [Apache Zookeeper](https://zookeeper.apache.org/) - to [Kubernetes](https://kubernetes.io) using [the Kubernetes Terraform provider](https://registry.terraform.io/providers/hashicorp/kubernetes/latest).

To use this repo, clone the repo, initialize Terraform, and run the Terraform plan.

You can use `terraform init` to initialize Terraform. You can use `terraform apply` to deploy the Terraform plan.

At this point, running Terraform with the plan will result in a proof-of-concept deployment of Zuul CI 9. This deployment should work on Kubernetes 1.27 or newer.

I put this deployment myself using [Microk8s](https://microk8s.io), which is an all-in-one [snap-based](https://snapcraft.io) distribution of Kubernetes. I am fan of Microk8s because I can run a Kubernetes cluster without having to worry about actually knowing how to set up Kubernetes.

## Proxy configuration for Microk8s
One of the environments I commonly work in requires a proxy for HTTP connections. You can configure Microk8s to use a proxy by modifying the `/etc/environment` file and adding something like the following:
```
HTTPS_PROXY=http://squid.internal:3128
HTTP_PROXY=http://squid.internal:3128
NO_PROXY=10.0.0.0/8,192.168.0.0/16,127.0.0.1,172.16.0.0/16,.svc,.svc.cluster.local
https_proxy=http://squid.internal:3128
http_proxy=http://squid.internal:3128
no_proxy=10.0.0.0/8,192.168.0.0/16,127.0.0.1,172.16.0.0/16,.svc,.svc.cluster.local
```

Defining `HTTPS_PROXY`, `HTTP_PROXY`, `NO_PROXY`, `https_proxy`, `http_proxy`, and `no_proxy` environment variables will tell Microk8s to proxy or not proxy requests. Replace `http://squid.internal:3128` with the address of your proxy if you are not using [Squid Proxy](http://www.squid-cache.org). The NO_PROXY/no_proxy settings must include what I have provided in order to make sure Kubernetes does not try to proxy internal traffic. Either define the variables before you install Microk8s or run `sudo snap restart microk8s` to restart the Microk8s services.