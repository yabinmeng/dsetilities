# Overview

"kubeadm" is [Kubernetes](https://kubernetes.io/)'s own packaged utility/tool to install and configure a minumum viable k8s cluster (aka, vanilla k8s cluster) that follows "kubeadm init and kubeadm join" as fast path best practices.

Please note that "kubeadm" utility only does cluster bootstrapping, but not provisisoning. Therefore, this installation method requires the underlying machines to be prepared in advance. It also doesn't include other nice-to-have "add-ons"/features such as k8s dashboard.

In this tutorial, a step-by-step procedure is presented regarding how to use kubeadm to install and configure a vanilla k8s cluster with a single control-plane node. For the demonstration purpose, 3 VM instances are provisioned in advance with the following specs and configurations on each instance
*Ubuntu Xenial (16.04.6 LTS) OS is installed
*4 vCPU and 16GB total system

# Install "kubeadm"

## Prerequisite Check and Settings

There are a few prerequisite checks/operations that need to be done on each of the hosting machine before we start provisioning a k8s cluster.

* Disable SWAP

* Verify ***MAC address*** is unique each instance (NOTE: replace "eth0" with the right network adaptor name)

```bash
$ ifconfig eth0 | grep -o -E '([[:xdigit:]]{1,2}:){5}[[:xdigit:]]{1,2}', or
$ ip link show eth0 | awk '/ether/ {print $2}'
```

* Verify ***product_uuid*** is unique on each instance

```bash
$ sudo cat /sys/class/dmi/id/product_uuid
```

* Check if Linux module ***br_netfilter*** is enabled. Enable it if not. This is required for the next step.

```bash
// check if "br_netfilter" module is enabled (enabled if value is returned)
$ lsmod | grep br_netfilter

// Enable "br_netfilter" module
$ sudo modprobe br_netfilter
```

* Make sure each instance's iptable can see bridged traffic

```bash
$ cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
EOF
$ sudo sysctl --system
```

* Make sure the following ports are open on the control-plan instance/node and the worker instances/nodes. All traffic for the following ports are inbound.

**Control-plane Instance/Node**

| Description        | Protocol/Port       | Note              |
| ------------------ | ------------------- | ------------------|
| Kubernetes API server | TCP/6443 ||
| etcd server client API | TCP/2379-2380 | Used by kube-apiserver, etcd |
| Kubelet API | TCP/10250 | Kubelet on the control-plane node |
| kube-scheduler | TCP/10251 ||
| kube-controller-manager | TCP/10252 ||

**Worker Instance/Node**

| Description        | Protocol/Port       | Note              |
| ------------------ | ------------------- | ------------------|
| Kubelet API | TCP/10250 | Kubelet on the worker node |
| NodePort Services | TCP/30000-32767 ||

## Install container runtime

K8s can work with different container runtimes (docker, containerd, CRI-O) via [K8s container runtime interface](https://github.com/kubernetes/community/blob/master/contributors/devel/sig-node/container-runtime-interface.md).

In this tutorial, docker container runtime is used. The procedure to install the latest Docker on Ubuntu is as follows:

```bash
# Instll prerequisites packages for Docker
$ sudo apt-get update
$ sudo apt-get install -y \
    apt-transport-https \
    ca-certificates \
    curl \
    gnupg-agent \
    software-properties-common

# Add Docker's official GPG key
$ curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -

# Set up Docker stable repository
$ sudo add-apt-repository \
   "deb [arch=amd64] https://download.docker.com/linux/ubuntu \
   $(lsb_release -cs) \
   stable"

# Install Docker engine
$ sudo apt-get update
$ sudo apt-get install -y docker-ce docker-ce-cli containerd.io
## Install specific version of Docker
#$ sudo apt-get install -y docker-ce=<version_string> docker-ce-cli=<version_string> containerd.io

# Use Docker as a non-root user
$ sudo usermod -aG docker your-user
```

### Make sure "systemd" is used as the cgroup driver for Docker (for improved system stability) 

```bash
# Set up Docker dameon
$  cat > /etc/docker/daemon.json <<EOF
{
  "exec-opts": ["native.cgroupdriver=systemd"],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m"
  },
  "storage-driver": "overlay2"
}
EOF

$ mkdir -p /etc/systemd/system/docker.service.d

# Restart Docker
$ systemctl daemon-reload
$ systemctl restart docker
```

Please **NOTE** that it is highly NOT recommended to change cgroup driver of a node that has joined a K8s cluster. The best approach is to drain the node; remove it from the cluster; and re-join it.

## Install "kubeadm", "kubelet", and "kubectl"

We need to install the matching versions of "kubeadm", "kubelet", and "kubectl" commands on all of the provisioned VM instances. In this tutorial, K8s version 1.17.6 is installed (**NOTE**: please do NOT install K8s version 1.18.x, which has some issues with DataStax Cassandra K8s operator).

```bash
$ sudo apt-get update
$ sudo apt-get install -y apt-transport-https curl

$ curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo apt-key add -

$cat <<EOF | sudo tee /etc/apt/sources.list.d/kubernetes.list
deb https://apt.kubernetes.io/ kubernetes-xenial main
EOF

$ sudo apt-get update
$ export K8S_VER="1.17.6-00"
$ sudo apt-get install -y kubelet=$K8S_VER kubeadm=$K8S_VER kubectl=$K8S_VER

$ sudo apt-mark hold kubelet kubeadm kubectl

$ sudo systemctl daemon-reload
$ sudo systemctl restart kubelet
```

## Configure cgroup driver used by "kubelet" on control-plane node

**NOTE**: this is only needed when K8s is using a container runtime other than Docker. For Docker runtime, K8s will automatically detect the cgroup driver used by ***kubelet*** and set it in ***/var/lib/kubelet/config.yaml*** file.

```bash
$ cat > kubeletConfig.yaml <<EOF
cat <<EOF | apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: <value>
EOF

$ kubectl apply -f kubeletConfig.yaml

```

# 