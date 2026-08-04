packer {
    required_plugins {
        amazon = {
            version = ">= 1.2.8"
            source  = "github.com/hashicorp/amazon"
        }
        ansible = {
            version = ">= 1.1.0"
            source  = "github.com/hashicorp/ansible"
        }
    }
}

variable "aws_region" {
    type    = string
    default = "ap-southeast-1"
}

variable "source_ami" {
    type        = string
    default     = "ami-05b741ae2ab9f1742" 
    description = "Base Amazon Linux 2023 AMI ID"
}

# 1. Builder: Launch temporary EC2 instance to build AMI 
source "amazon-ebs" "datalayer" {
    ami_name        = "iot-bigdata-datalayer-${formatdate("YYYYMMDDhhmmss", timestamp())}" 
    instance_type   = "t3.small"
    region          = var.aws_region
    source_ami      = var.source_ami
    ssh_username    = "ec2-user"

    tags = {
        Name        = "iot-bigdata-datalayer-ami"
        Project     = "iot-bigdata"
        ManagedBy   = "packer"
    }
}

# 2. Provisioner: Run Ansible install.yml tasks and save disk snapshot as AMI
build {
    name    = "iot-bigdata-datalayer"
    sources = ["source.amazon-ebs.datalayer"]

    provisioner "ansible" {
        playbook_file    = "../../ansible/packer-datalayer.yml"
        user             = "ec2-user"
        use_proxy        = false
        ansible_env_vars = [
            "ANSIBLE_ROLES_PATH=../../ansible/roles"
        ]
    }
}