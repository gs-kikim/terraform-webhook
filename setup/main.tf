provider "aws" {
  region = var.region
}

# 간단한 VPC 및 보안 그룹
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

resource "aws_security_group" "atlantis_sg" {
  name        = "atlantis-sg"
  description = "Security group for Atlantis server"
  vpc_id      = aws_vpc.atlantis_vpc.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

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

# 인라인 설치 스크립트가 포함된 EC2 인스턴스
resource "aws_instance" "atlantis_instance" {
  ami                    = var.ami_id
  instance_type          = var.instance_type
  key_name               = var.key_name
  subnet_id              = aws_subnet.atlantis_subnet.id
  vpc_security_group_ids = [aws_security_group.atlantis_sg.id]

  user_data = <<-EOF
    #!/bin/bash

    # 시스템 로그 파일 설정
    exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1
    echo "시작: $(date)"

    # 1. 패키지 업데이트 및 필요한 도구 설치
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y docker.io snapd curl git jq
    
    # 2. Docker 설정
    systemctl start docker
    systemctl enable docker
    usermod -aG docker ubuntu

    # 3. Kubernetes 도구 설치 (microk8s)
    snap install microk8s --classic --channel=1.28/stable
    usermod -aG microk8s ubuntu
    mkdir -p /home/ubuntu/.kube

    # 4. 권한 적용을 위해 새 그룹 세션 시작
    echo "microk8s 그룹 설정..."
    sudo -u ubuntu bash -c 'mkdir -p ~/.kube'

    # 5. microk8s 준비 대기
    echo "microk8s가 준비될 때까지 대기 중..."
    microk8s status --wait-ready

    # 6. 필요한 add-on 활성화
    echo "microk8s add-on 활성화 중..."
    microk8s enable dns ingress storage

    # 7. Kubeconfig 설정
    echo "Kubeconfig 설정 중..."
    microk8s config > /home/ubuntu/.kube/config
    chown ubuntu:ubuntu /home/ubuntu/.kube/config
    chmod 600 /home/ubuntu/.kube/config

    # 8. 환경 변수 설정
    echo 'export KUBECONFIG=~/.kube/config' >> /home/ubuntu/.bashrc
    echo 'alias kubectl="microk8s kubectl"' >> /home/ubuntu/.bashrc

    # 9. kubectl 설치
    echo "kubectl 설치 중..."
    snap install kubectl --classic

    # 10. helm 설치
    echo "Helm 설치 중..."
    curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
    chmod +x get_helm.sh
    ./get_helm.sh

    # 11. 퍼블릭 DNS 및 IP 가져오기
    PUBLIC_DNS=$(curl -s http://169.254.169.254/latest/meta-data/public-hostname)
    PUBLIC_IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4)

    echo "퍼블릭 DNS: $PUBLIC_DNS"
    echo "퍼블릭 IP: $PUBLIC_IP"

    # 12. Atlantis 값 파일 생성
    echo "Atlantis 설정 파일 생성 중..."
    cat > /home/ubuntu/atlantis-values.yaml << VALUESEOF
    atlantis:
        service:
        type: NodePort
        ingress:
        enabled: true
        hosts:
            - host: "$PUBLIC_DNS"
            paths: ["/"]
            - host: "$PUBLIC_IP"
            paths: ["/"]
        github:
        user: "${var.github_username}"
        token: "${var.github_token}"
        secret: "${var.webhook_secret}"
        allowForkPRs: true
        repoConfig: |
        repos:
        - id: /.*/
            branch: /.*/
            workflow: default
            apply_requirements: [approved, mergeable]
        resources:
        requests:
            memory: "256Mi"
            cpu: "200m"
        limits:
            memory: "512Mi"
            cpu: "500m"
    VALUESEOF

    chown ubuntu:ubuntu /home/ubuntu/atlantis-values.yaml

    # 13. Helm 리포지토리 추가
    echo "Helm 리포지토리 추가 중..."
    sudo -u ubuntu bash -c "microk8s helm3 repo add runatlantis https://runatlantis.github.io/helm-charts"
    sudo -u ubuntu bash -c "microk8s helm3 repo update"

    # 14. Atlantis 배포
    echo "Atlantis 배포 중..."
    sudo -u ubuntu bash -c "microk8s helm3 install atlantis runatlantis/atlantis -f /home/ubuntu/atlantis-values.yaml"

    # 15. 배포 완료 대기
    echo "배포 완료 대기 중..."
    sleep 30

    # 16. NodePort를 80 포트로 포워딩 설정
    echo "포트 포워딩 설정 중..."
    NODEPORT=$(microk8s kubectl get svc atlantis -o jsonpath='{.spec.ports[0].nodePort}')
    iptables -t nat -A PREROUTING -p tcp --dport 80 -j REDIRECT --to-port $NODEPORT
    
    # 재부팅 후에도 iptables 규칙이 유지되도록 부팅 스크립트 생성
    cat > /etc/rc.local << 'RCLOCAL'
    #!/bin/bash
    NODEPORT=$(microk8s kubectl get svc atlantis -o jsonpath='{.spec.ports[0].nodePort}')
    iptables -t nat -A PREROUTING -p tcp --dport 80 -j REDIRECT --to-port $NODEPORT
    exit 0
    RCLOCAL
    
    chmod +x /etc/rc.local

    # 18. 완료 메시지
    echo "설치 완료!"
    echo "Atlantis는 다음 주소에서 접근할 수 있습니다:"
    echo "http://$PUBLIC_DNS"
    echo "또는"
    echo "http://$PUBLIC_IP"

    # 19. 설치 완료 메시지 파일 생성
    cat > /home/ubuntu/setup-complete.txt << COMPLETEEOF
    Atlantis 설치가 완료되었습니다.
    접근 URL:
    http://$PUBLIC_DNS
    http://$PUBLIC_IP

    GitHub Webhook URL: http://$PUBLIC_DNS/events 또는 http://$PUBLIC_IP/events
    Content Type: application/json
    Secret: <WEBHOOK_SECRET 값>
    이벤트: Pull requests, pushes
    COMPLETEEOF

    chown ubuntu:ubuntu /home/ubuntu/setup-complete.txt
    echo "종료: $(date)"
    EOF

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
  }

  tags = {
    Name = "atlantis-server"
  }
}

# 변수 정의
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