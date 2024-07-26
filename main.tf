provider "aws" {
  region = "eu-central-1"
}

resource "aws_ssm_parameter" "db_name" {
  name  = "/sigma/db_name"
  type  = "String"
  value = var.db_name
}

resource "aws_ssm_parameter" "db_password" {
  name  = "/sigma/db_password"
  type  = "SecureString"
  value = var.db_password
}

resource "aws_ssm_parameter" "db_user" {
  name  = "/sigma/db_user"
  type  = "String"
  value = var.db_user
}

resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16"

  enable_dns_support   = true
  enable_dns_hostnames = true
}

resource "aws_vpc_dhcp_options" "main" {
  domain_name         = "ec2.internal"
  domain_name_servers = ["AmazonProvidedDNS"]
}

resource "aws_vpc_dhcp_options_association" "main" {
  vpc_id          = aws_vpc.main.id
  dhcp_options_id = aws_vpc_dhcp_options.main.id
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
}

resource "aws_route_table" "main" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
}

resource "aws_route_table_association" "a" {
  subnet_id      = aws_subnet.main_a.id
  route_table_id = aws_route_table.main.id
}

resource "aws_route_table_association" "b" {
  subnet_id      = aws_subnet.main_b.id
  route_table_id = aws_route_table.main.id
}

resource "aws_subnet" "main_a" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.3.0/24"
  availability_zone = "eu-central-1a"
}

resource "aws_subnet" "main_b" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.4.0/24"
  availability_zone = "eu-central-1b"
}

resource "aws_security_group" "ec2_sg" {
  vpc_id = aws_vpc.main.id

  ingress {
    from_port   = 0
    to_port     = 65535
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "db_sg" {
  vpc_id = aws_vpc.main.id

  ingress {
    from_port   = 3306
    to_port     = 3306
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_lb" "this" {
  name               = "project-lb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.ec2_sg.id]
  subnets            = [aws_subnet.main_a.id, aws_subnet.main_b.id]

  enable_deletion_protection = false
}

resource "aws_lb_target_group" "this" {
  name     = "project-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id
}

resource "aws_lb_listener" "this" {
  load_balancer_arn = aws_lb.this.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this.arn
  }
}

resource "aws_iam_role" "my_ec2_ssm_full_access_role" {
  name = "my_ec2_ssm_full_access_role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Principal = {
          Service = "ec2.amazonaws.com"
        },
        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "attach_ec2_full_access" {
  role       = aws_iam_role.my_ec2_ssm_full_access_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2FullAccess"
}

resource "aws_iam_role_policy_attachment" "attach_ssm_full_access" {
  role       = aws_iam_role.my_ec2_ssm_full_access_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMFullAccess"
}

resource "aws_iam_instance_profile" "ec2_role_profile" {
  name = "ec2_role_profile"
  role = aws_iam_role.my_ec2_ssm_full_access_role.id
}

resource "aws_launch_template" "this" {
  name_prefix   = "template-"
  image_id      = "ami-0e872aee57663ae2d"
  instance_type = "t2.micro"
  key_name      = "frankfurt_rsa_key_pair"

  network_interfaces {
    associate_public_ip_address = true
    security_groups             = [aws_security_group.ec2_sg.id]
    delete_on_termination       = true
  }

  iam_instance_profile {
    name = aws_iam_instance_profile.ec2_role_profile.name
  }

  user_data = base64encode(<<-EOF
              #!/bin/bash
              apt-get update              
              curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
              sudo apt install unzip
              unzip awscliv2.zip
              sudo ./aws/install
              apt-get install -y docker.io
              systemctl start docker
              systemctl enable docker
              export PRIVATE_NAME=$(aws ssm get-parameter --name "/sigma/db_user" --with-decryption --query "Parameter.Value" --output text)
              export PRIVATE_PASSWORD=$(aws ssm get-parameter --name "/sigma/db_password" --with-decryption --query "Parameter.Value" --output text)
              export PRIVATE_DBNAME=$(aws ssm get-parameter --name "/sigma/db_name" --with-decryption --query "Parameter.Value" --output text)
              docker run -d -e WORDPRESS_DB_HOST=${aws_db_instance.mariadb.address} -e WORDPRESS_DB_USER=$PRIVATE_NAME -e WORDPRESS_DB_PASSWORD=$PRIVATE_PASSWORD -e WORDPRESS_DB_NAME=$PRIVATE_DBNAME -p 80:80 wordpress
              EOF
  )
}

resource "aws_autoscaling_group" "this" {
  desired_capacity    = 1
  max_size            = 1
  min_size            = 1
  vpc_zone_identifier = [aws_subnet.main_a.id, aws_subnet.main_b.id]
  launch_template {
    id      = aws_launch_template.this.id
    version = "$Latest"
  }

  target_group_arns = [aws_lb_target_group.this.arn]
}

resource "aws_db_instance" "mariadb" {
  identifier             = "terraform-mariadb"
  allocated_storage      = 20
  engine                 = "mariadb"
  instance_class         = "db.t3.micro"
  db_name                = var.db_name
  username               = var.db_user
  password               = var.db_password
  skip_final_snapshot    = true
  vpc_security_group_ids = [aws_security_group.db_sg.id]
  db_subnet_group_name   = aws_db_subnet_group.main.name
  publicly_accessible    = true
}

resource "aws_db_subnet_group" "main" {
  name       = "main-subnet-group"
  subnet_ids = [aws_subnet.main_a.id, aws_subnet.main_b.id]
}

output "alb_dns_name" {
  description = "DNS name of the load balancer"
  value       = aws_lb.this.dns_name
}

output "rds_endpoint" {
  description = "Endpoint of the RDS instance"
  value       = aws_db_instance.mariadb.address
}

output "db_user" {
  description = "The database admin user"
  sensitive   = true
  value       = var.db_user
}

output "db_password" {
  description = "The database admin password"
  sensitive   = true
  value       = var.db_password
}

output "db_name" {
  description = "The name of the database"
  sensitive   = true
  value       = var.db_name
}
