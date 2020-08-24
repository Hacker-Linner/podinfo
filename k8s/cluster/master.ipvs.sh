#!/bin/bash -

### Add yum-utils, if not installed already
yum -y update
yum install -y epel-release
yum install -y yum-utils device-mapper-persistent-data lvm2 net-tools conntrack-tools wget vim ntpdate libseccomp libtool-ltdl

### hostname
hostnamectl  set-hostname  k8s-master1
echo "10.10.28.170   $(hostname)" >> /etc/hosts
echo "127.0.0.1   $(hostname)" >> /etc/hosts

### time
systemctl start chronyd.service && systemctl enable chronyd.service

### Disable Firewall
systemctl stop firewalld && systemctl disable firewalld

### Disable SELinux
setenforce 0
sed -i 's/^SELINUX=enforcing$/SELINUX=disabled/' /etc/selinux/config

### Disable Swap
sed -i '/swap/d' /etc/fstab
swapoff -a && sysctl -w vm.swappiness=0

cat <<EOF > /etc/sysctl.d/k8s.conf

net.ipv4.ip_forward = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 10
EOF

### br_netfilter
modprobe br_netfilter
sysctl -p /etc/sysctl.d/k8s.conf
ls /proc/sys/net/bridge


### IPVS
cat > /etc/sysconfig/modules/ipvs.modules <<EOF

#!/bin/bash
modprobe -- ip_vs
modprobe -- ip_vs_rr
modprobe -- ip_vs_wrr
modprobe -- ip_vs_sh
modprobe -- nf_conntrack_ipv4

EOF

### ipvs.modules
chmod 755 /etc/sysconfig/modules/ipvs.modules
bash /etc/sysconfig/modules/ipvs.modules
lsmod | grep -e ip_vs -e nf_conntrack_ipv4

### ipset
yum install -y ipset

### security/limits
echo "* soft nofile 65536" >> /etc/security/limits.conf
echo "* hard nofile 65536" >> /etc/security/limits.conf
echo "* soft nproc 65536"  >> /etc/security/limits.conf
echo "* hard nproc 65536"  >> /etc/security/limits.conf
echo "* soft memlock  unlimited"  >> /etc/security/limits.conf
echo "* hard memlock  unlimited"  >> /etc/security/limits.conf

### Install Docker CE.
yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
yum install -y docker-ce-18.09.9-3.el7

mkdir -p /etc/docker
cat > /etc/docker/daemon.json << EOF

{
  "exec-opts": ["native.cgroupdriver=systemd"],
  "registry-mirrors": [],
  "storage-driver": "overlay2",
  "storage-opts": [
    "overlay2.override_kernel_check=true"
  ],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m",
    "max-file":"5"
  },
  "insecure-registries": []
}

EOF

systemctl start docker && systemctl enable docker

### Install kubelet/kubectl/kubeadm
cat <<EOF > /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://packages.cloud.google.com/yum/repos/kubernetes-el7-x86_64
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=https://packages.cloud.google.com/yum/doc/yum-key.gpg https://packages.cloud.google.com/yum/doc/rpm-package-key.gpg
EOF

yum install -y kubelet-1.16.3-0
yum install -y kubectl-1.16.3-0
yum install -y kubeadm-1.16.3-0

systemctl start kubelet && systemctl enable kubelet

cat > kubeadm-config.yaml << EOF

apiVersion: kubeadm.k8s.io/v1beta2
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: 10.10.28.170
  bindPort: 6443
nodeRegistration:
  taints:
  - effect: PreferNoSchedule
    key: node-role.kubernetes.io/master
---
apiVersion: kubeadm.k8s.io/v1beta2
kind: ClusterConfiguration
imageRepository: k8s.gcr.io
kubernetesVersion: v1.16.3
networking:
  podSubnet: 10.244.0.0/16
---
apiVersion: kubeproxy.config.k8s.io/v1alpha1
kind: KubeProxyConfiguration
mode: ipvs

EOF

kubeadm init --config kubeadm-config.yaml

mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

# Calico
sed -i 's/192.168.0.0/10.244.0.0/g' calico.yaml
kubectl apply -f calico.yaml
