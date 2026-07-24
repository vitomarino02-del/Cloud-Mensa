[control_plane]
mensa-cp ansible_host=${cp_ip}

[workers]
%{ for i, ip in worker_ips ~}
mensa-worker-${i + 1} ansible_host=${ip}
%{ endfor ~}

[k8s_cluster:children]
control_plane
workers

[k8s_cluster:vars]
ansible_user=ubuntu
ansible_ssh_private_key_file=${ssh_key_path}
ansible_ssh_common_args='-o StrictHostKeyChecking=no'
