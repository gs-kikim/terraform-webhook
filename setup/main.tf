provider "aws" {
  region = var.region
}

# VPC 리소스
resource "aws_vpc" "atlantis_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "atlantis-vpc"
  }
}

resource "aws_subnet" "atlantis_subnet" {
  vpc_id                  = aws_vpc.atlantis_vpc.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "${var.region}a"
  map_public_ip_on_launch = true

  tags = {
    Name = "atlantis-subnet"
  }
}

resource "aws_internet_gateway" "atlantis_igw" {
  vpc_id = aws_vpc.atlantis_vpc.id

  tags = {
    Name = "atlantis-igw"
  }
}

resource "aws_route_table" "atlantis_rt" {
  vpc_id = aws_vpc.atlantis_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.atlantis_igw.id
  }

  tags = {
    Name = "atlantis-rt"
  }
}

resource "aws_route_table_association" "atlantis_rta" {
  subnet_id      = aws_subnet.atlantis_subnet.id
  route_table_id = aws_route_table.atlantis_rt.id
}

# 보안 그룹 (Atlantis 및 Kubernetes 포트 추가)
resource "aws_security_group" "atlantis_sg" {
  name        = "atlantis-sg"
  description = "Security group for Atlantis server"
  vpc_id      = aws_vpc.atlantis_vpc.id

  # SSH
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # HTTP
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # HTTPS
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Kubernetes API 서버
  ingress {
    from_port   = 6443
    to_port     = 6443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Kubernetes NodePort 범위
  ingress {
    from_port   = 30000
    to_port     = 32767
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # 모든 아웃바운드 트래픽 허용
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "atlantis-sg"
  }
}

# EC2 인스턴스 리소스
resource "aws_instance" "atlantis_instance" {
  ami                    = var.ami_id
  instance_type          = var.instance_type
  key_name               = var.key_name
  subnet_id              = aws_subnet.atlantis_subnet.id
  vpc_security_group_ids = [aws_security_group.atlantis_sg.id]

  user_data = base64encode(<<-EOF
    #!/bin/bash
    set -e

    # 로깅 설정
    exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1

    # 기본 패키지 업데이트 및 설치
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get upgrade -y
    apt-get install -y docker.io snapd curl git jq

    # Docker 설정
    systemctl enable docker
    systemctl start docker
    usermod -aG docker ubuntu

    # Kubernetes (MicroK8s) 설치
    snap install microk8s --classic --channel=1.28/stable
    usermod -aG microk8s ubuntu

    # MicroK8s 초기 설정
    microk8s status --wait-ready
    microk8s enable dns helm3 storage

    # Helm 리포지토리 설정
    microk8s helm3 repo add runatlantis https://runatlantis.github.io/helm-charts
    microk8s helm3 repo update

    # Atlantis 설정 파일 생성
    cat > /home/ubuntu/atlantis-values.yaml << VALUESEOF
    service:
      type: NodePort
    ingress:
      enabled: false
    github:
      user: "${var.github_username}"
      token: "${var.github_token}"
      secret: "${var.webhook_secret}"
    repoConfig: |
      repos:
      - id: /.*/
        workflow: default
    VALUESEOF

    # Atlantis 배포
    microk8s helm3 install atlantis runatlantis/atlantis -f /home/ubuntu/atlantis-values.yaml

    # 포트 포워딩 설정
    NODEPORT=$(microk8s kubectl get svc atlantis -o jsonpath='{.spec.ports[0].nodePort}')
    iptables -t nat -A PREROUTING -p tcp --dport 80 -j REDIRECT --to-port $NODEPORT

    # 웹훅 URL 파일 생성
    PUBLIC_IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4)
    echo "GitHub Webhook URL: http://$PUBLIC_IP/events" > /home/ubuntu/webhook-url.txt

    # 최종 로그
    echo "Atlantis 설치 완료: $(date)"
    EOF
  )

  user_data_replace_on_change = true

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
  }

  tags = {
    Name = "atlantis-server"
  }
}

# 변수 정의 (이전 코드와 동일)
variable "region" {
  description = "AWS 리전"
  default     = "ap-northeast-2"
}

variable "ami_id" {
  description = "Ubuntu 22.04 LTS AMI ID"
  default     = "ami-0e735aba742568824"
}

variable "instance_type" {
  description = "EC2 인스턴스 타입"
  default     = "t3.medium"
}

variable "key_name" {
  description = "SSH 키 페어 이름"
  type        = string
}

variable "github_username" {
  description = "GitHub 사용자 이름"
  type        = string
}

variable "github_token" {
  description = "GitHub 개인 액세스 토큰"
  type        = string
  sensitive   = true
}

variable "webhook_secret" {
  description = "GitHub 웹훅 시크릿"
  type        = string
  sensitive   = true
}

# 출력 정의
output "public_ip" {
  value = aws_instance.atlantis_instance.public_ip
}

output "public_dns" {
  value = aws_instance.atlantis_instance.public_dns
}

output "ssh_command" {
  value = "ssh -i ${var.key_name}.pem ubuntu@${aws_instance.atlantis_instance.public_dns}"
}

output "atlantis_url" {
  value = "http://${aws_instance.atlantis_instance.public_ip}"
}

output "webhook_url_file" {
  value = "/home/ubuntu/webhook-url.txt"
}