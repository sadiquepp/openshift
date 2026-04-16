output "installer_instance_id" {
  description = "EC2 instance ID of the installer/bastion"
  value       = aws_instance.installer.id
}

output "installer_public_ip" {
  description = "Public IP of the installer/bastion — use this for SSH and Ansible inventory"
  value       = aws_instance.installer.public_ip
}

output "installer_public_dns" {
  description = "Public DNS of the installer/bastion"
  value       = aws_instance.installer.public_dns
}

output "security_group_id" {
  description = "ID of the installer security group"
  value       = aws_security_group.installer.id
}

output "key_pair_name" {
  description = "Name of the imported EC2 key pair"
  value       = aws_key_pair.installer.key_name
}

output "ansible_inventory_hint" {
  description = "Quick-start SSH command for Ansible dynamic inventory"
  value       = "ansible-playbook setup-bastion-ec2.yaml -i '${aws_instance.installer.public_ip},' -u ec2-user"
}
