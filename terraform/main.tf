terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "ap-south-1"
}

# ─────────────────────────────────────
# VPC
# ─────────────────────────────────────
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags = { Name = "prod-vpc" }
}

# ─────────────────────────────────────
# PUBLIC SUBNETS
# ─────────────────────────────────────
resource "aws_subnet" "public_1" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "ap-south-1a"
  map_public_ip_on_launch = true
  tags = { Name = "prod-public-1" }
}

resource "aws_subnet" "public_2" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.2.0/24"
  availability_zone       = "ap-south-1b"
  map_public_ip_on_launch = true
  tags = { Name = "prod-public-2" }
}

# ─────────────────────────────────────
# PRIVATE SUBNETS
# ─────────────────────────────────────
resource "aws_subnet" "private_1" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.3.0/24"
  availability_zone = "ap-south-1a"
  tags = { Name = "prod-private-1" }
}

resource "aws_subnet" "private_2" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.4.0/24"
  availability_zone = "ap-south-1b"
  tags = { Name = "prod-private-2" }
}

# ─────────────────────────────────────
# INTERNET GATEWAY (public subnet)
# ─────────────────────────────────────
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags = { Name = "prod-igw" }
}

# ─────────────────────────────────────
# NAT GATEWAY (private subnet outbound)
# ─────────────────────────────────────
resource "aws_eip" "nat" {
  domain = "vpc"
  tags = { Name = "prod-nat-eip" }
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public_1.id
  tags = { Name = "prod-nat-gw" }
  depends_on = [aws_internet_gateway.main]
}

# ─────────────────────────────────────
# ROUTE TABLES
# ─────────────────────────────────────

# Public route table → Internet Gateway
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
  tags = { Name = "prod-public-rt" }
}

resource "aws_route_table_association" "public_1" {
  subnet_id      = aws_subnet.public_1.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "public_2" {
  subnet_id      = aws_subnet.public_2.id
  route_table_id = aws_route_table.public.id
}

# Private route table → NAT Gateway
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }
  tags = { Name = "prod-private-rt" }
}

resource "aws_route_table_association" "private_1" {
  subnet_id      = aws_subnet.private_1.id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "private_2" {
  subnet_id      = aws_subnet.private_2.id
  route_table_id = aws_route_table.private.id
}

# ─────────────────────────────────────
# SECURITY GROUPS
# ─────────────────────────────────────

# Bastion Host SG - SSH from anywhere
resource "aws_security_group" "bastion" {
  name   = "prod-bastion-sg"
  vpc_id = aws_vpc.main.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "prod-bastion-sg" }
}

# ALB SG - HTTP from anywhere
resource "aws_security_group" "alb" {
  name   = "prod-alb-sg"
  vpc_id = aws_vpc.main.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "prod-alb-sg" }
}

# App Server SG - only from ALB and Bastion
resource "aws_security_group" "app" {
  name   = "prod-app-sg"
  vpc_id = aws_vpc.main.id

  ingress {
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  ingress {
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.bastion.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "prod-app-sg" }
}

# RDS SG - only from App servers
resource "aws_security_group" "rds" {
  name   = "prod-rds-sg"
  vpc_id = aws_vpc.main.id

  ingress {
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.app.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "prod-rds-sg" }
}

# ─────────────────────────────────────
# BASTION HOST (public subnet)
# ─────────────────────────────────────
resource "aws_instance" "bastion" {
  ami                    = "ami-040e95ba14632401d"
  instance_type          = "t3.micro"
  subnet_id              = aws_subnet.public_1.id
  vpc_security_group_ids = [aws_security_group.bastion.id]
  key_name               = "lup21"

  tags = { Name = "prod-bastion" }
}

# ─────────────────────────────────────
# APP SERVER (private subnet)
# ─────────────────────────────────────
resource "aws_instance" "app" {
  ami                    = "ami-040e95ba14632401d"
  instance_type          = "t3.micro"
  subnet_id              = aws_subnet.private_1.id
  vpc_security_group_ids = [aws_security_group.app.id]
  key_name               = "lup21"

  user_data = base64encode(<<-EOF
    #!/bin/bash
    apt-get update -y
    apt-get install -y nginx
    systemctl start nginx
    systemctl enable nginx
    echo "<h1>Hello from Private Subnet!</h1><p>Server: $(hostname)</p><p>This EC2 is in a PRIVATE subnet - not directly accessible from internet!</p>" > /var/www/html/index.html
  EOF
  )

  tags = { Name = "prod-app-server" }
}

# ─────────────────────────────────────
# RDS MySQL (private subnet)
# ─────────────────────────────────────
resource "aws_db_subnet_group" "main" {
  name       = "prod-db-subnet-group"
  subnet_ids = [aws_subnet.private_1.id, aws_subnet.private_2.id]
  tags = { Name = "prod-db-subnet-group" }
}

resource "aws_db_instance" "main" {
  identifier           = "prod-mysql"
  engine               = "mysql"
  engine_version       = "8.0"
  instance_class       = "db.t3.micro"
  allocated_storage    = 20
  storage_type         = "gp2"
  db_name              = "proddb"
  username             = "admin"
  password             = "Admin12345!"
  skip_final_snapshot  = true
  publicly_accessible  = false
  vpc_security_group_ids = [aws_security_group.rds.id]
  db_subnet_group_name   = aws_db_subnet_group.main.name

  tags = { Name = "prod-mysql" }
}

# ─────────────────────────────────────
# ALB (public subnet)
# ─────────────────────────────────────
resource "aws_lb" "main" {
  name               = "prod-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = [aws_subnet.public_1.id, aws_subnet.public_2.id]
  tags = { Name = "prod-alb" }
}

resource "aws_lb_target_group" "main" {
  name     = "prod-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  health_check {
    path                = "/"
    healthy_threshold   = 2
    unhealthy_threshold = 2
    interval            = 30
  }
  tags = { Name = "prod-tg" }
}

resource "aws_lb_listener" "main" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.main.arn
  }
}

resource "aws_lb_target_group_attachment" "main" {
  target_group_arn = aws_lb_target_group.main.arn
  target_id        = aws_instance.app.id
  port             = 80
}

# ─────────────────────────────────────
# OUTPUTS
# ─────────────────────────────────────
output "alb_dns_name" {
  value       = aws_lb.main.dns_name
  description = "Hit this URL to access the app"
}

output "bastion_public_ip" {
  value       = aws_instance.bastion.public_ip
  description = "SSH into bastion using this IP"
}

output "app_private_ip" {
  value       = aws_instance.app.private_ip
  description = "App server private IP"
}

output "rds_endpoint" {
  value       = aws_db_instance.main.endpoint
  description = "RDS endpoint"
}