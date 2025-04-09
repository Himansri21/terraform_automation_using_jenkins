terraform {
  backend "s3" {
    bucket         = "your-terraform-state-bucket"
    key            = "./terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "terraform-locks"
    encrypt        = true
  }
}

##############################
# VARIABLES & DATA SOURCES
##############################
variable "project_name" {
  default = "aryaman_tasl"
}

data "aws_availability_zones" "available" {}

##############################
# VPC & NETWORK RESOURCES
##############################
resource "aws_vpc" "task-vpc" {
  cidr_block = "10.0.0.0/16"
}

resource "aws_internet_gateway" "gw" {
  vpc_id = aws_vpc.task-vpc.id
}

# Public Subnets
resource "aws_subnet" "public-subnet" {
  vpc_id            = aws_vpc.task-vpc.id
  cidr_block        = "10.0.1.0/24"
  availability_zone = data.aws_availability_zones.available.names[0]
}

resource "aws_subnet" "public-subnet-2" {
  vpc_id            = aws_vpc.task-vpc.id
  cidr_block        = "10.0.3.0/24"
  availability_zone = data.aws_availability_zones.available.names[1]
}

# Private Subnets
resource "aws_subnet" "private-subnet" {
  vpc_id     = aws_vpc.task-vpc.id
  cidr_block = "10.0.2.0/24"
}

resource "aws_subnet" "private-subnet-2" {
  vpc_id     = aws_vpc.task-vpc.id
  cidr_block = "10.0.4.0/24"
  availability_zone = data.aws_availability_zones.available.names[1]
}

# Public Route Table & Association
resource "aws_route_table" "nat-route-table-to-internet-gateway" {
  vpc_id = aws_vpc.task-vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.gw.id
  }
}

resource "aws_route_table_association" "public-subnet-route-to-internet-gateway" {
  subnet_id      = aws_subnet.public-subnet.id
  route_table_id = aws_route_table.nat-route-table-to-internet-gateway.id
}

# Create EIP & NAT Gateway in the public subnet
resource "aws_eip" "eip-for-natgateway" {
  domain = "vpc"
}

resource "aws_nat_gateway" "NAT" {
  allocation_id = aws_eip.eip-for-natgateway.id
  subnet_id     = aws_subnet.public-subnet.id
}

# Private Route Table & Associations
resource "aws_route_table" "private-route-table-1" {
  vpc_id = aws_vpc.task-vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_nat_gateway.NAT.id
  }
}

resource "aws_route_table_association" "private-subnet-route-to-nat-gateway" {
  subnet_id      = aws_subnet.private-subnet.id
  route_table_id = aws_route_table.private-route-table-1.id
}

resource "aws_route_table_association" "private-subnet-2-route-to-nat-gateway" {
  subnet_id      = aws_subnet.private-subnet-2.id
  route_table_id = aws_route_table.private-route-table-1.id
}

##############################
# FRONTEND: S3 STATIC WEBSITE
##############################
resource "aws_s3_bucket" "s3" {
  bucket = "my-react-bucket-frontend-task-optimize1"
}

resource "aws_s3_bucket_policy" "allow_access_from_another_account" {
  bucket = aws_s3_bucket.s3.id
  policy = data.aws_iam_policy_document.allow_access_from_another_account.json
}

data "aws_iam_policy_document" "allow_access_from_another_account" {
  statement {
    principals {
      type        = "AWS"
      identifiers = ["841162705069"]
    }
    actions = [
      "s3:GetObject",
      "s3:ListBucket",
    ]
    resources = [
      aws_s3_bucket.s3.arn,
      "${aws_s3_bucket.s3.arn}/*",
    ]
  }
}

resource "aws_s3_bucket_public_access_block" "s3-public-block" {
  bucket = aws_s3_bucket.s3.id

  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

resource "aws_s3_bucket_ownership_controls" "s3-ownership" {
  bucket = aws_s3_bucket.s3.id

  rule {
    object_ownership = "BucketOwnerPreferred"
  }
}

resource "aws_s3_bucket_acl" "s3_ACL" {
  bucket = aws_s3_bucket.s3.id
  acl    = "public-read"

  depends_on = [aws_s3_bucket_public_access_block.s3-public-block]
}

resource "aws_s3_object" "build" {
  for_each = fileset("./frontend/build", "**/*")

  bucket  = aws_s3_bucket.s3.id
  key     = each.value
  source  = "./frontend/build/${each.value}"
  etag    = filemd5("./frontend/build/${each.value}")

  content_type = lookup(
    {
      "html" = "text/html",
      "css"  = "text/css",
      "js"   = "application/javascript",
      "png"  = "image/png",
      "jpg"  = "image/jpeg",
      "gif"  = "image/gif",
      "svg"  = "image/svg+xml",
      "json" = "application/json",
    },
    lower(regex("\\.([^.]+)$", each.value)[0]),
    "application/octet-stream"
  )

  acl = "public-read"
}

resource "aws_s3_bucket_website_configuration" "s3-website" {
  bucket = aws_s3_bucket.s3.id

  index_document {
    suffix = "index.html"
  }
}

##############################
# BACKEND: ECS & ALB
##############################
# IAM Roles for ECS
resource "aws_iam_role" "ecs_execution_role" {
  name = "ecs_execution_role"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17",
    Statement = [{
      Action    = "sts:AssumeRole",
      Effect    = "Allow",
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role" "ecs_task_role" {
  name = "ecs_task_role"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17",
    Statement = [{
      Action    = "sts:AssumeRole",
      Effect    = "Allow",
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_execution_role_policy" {
  role       = aws_iam_role.ecs_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# ECS Cluster & Task Definition
resource "aws_ecs_cluster" "my-backend-cluster" {
  name = "my-backend-cluster"
}

resource "aws_ecs_task_definition" "new-backend-task-def" {
  family                   = "new-backend-task"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.ecs_execution_role.arn
  task_role_arn            = aws_iam_role.ecs_task_role.arn

  container_definitions = jsonencode([
    {
      name         = "backend-task-def",
      image        = "841162705069.dkr.ecr.us-east-1.amazonaws.com/backend-backend",
      essential    = true,
      portMappings = [
        {
          containerPort = 5000,
          hostPort      = 5000
        }
      ]
    }
  ])
}

# Use name_prefix to avoid duplicate security group issues
resource "aws_security_group" "ecs-service-sg" {
  name_prefix = "ecs_service_sg-"
  description = "Security group for ECS service in private subnets"
  vpc_id      = aws_vpc.task-vpc.id

  ingress {
    from_port       = 5000
    to_port         = 5000
    protocol        = "tcp"
    security_groups = [aws_security_group.application-load-balancer-sg.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ECS Service with multiple private subnets for resiliency
resource "aws_ecs_service" "ecs-service" {
  name            = "backend-ecs-service"
  cluster         = aws_ecs_cluster.my-backend-cluster.id
  task_definition = aws_ecs_task_definition.new-backend-task-def.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets         = [aws_subnet.private-subnet.id, aws_subnet.private-subnet-2.id]
    security_groups = [aws_security_group.ecs-service-sg.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.backend-target-group.arn
    container_name   = "backend-task-def"
    container_port   = 5000
  }

  depends_on = [
    aws_lb_listener.backend_listener,
    aws_lb_target_group.backend-target-group
  ]
}

# ALB Security Group
resource "aws_security_group" "application-load-balancer-sg" {
  name_prefix = "alb_sg-"
  description = "Security group for ALB"
  vpc_id      = aws_vpc.task-vpc.id

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
}

# Application Load Balancer
resource "aws_lb" "backend-load-balancer" {
  name               = "backend-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.application-load-balancer-sg.id]
  subnets            = [aws_subnet.public-subnet.id, aws_subnet.public-subnet-2.id]
}

# ALB Target Group with Health Check
resource "aws_lb_target_group" "backend-target-group" {
  name        = "backend-target-group"
  port        = 5000
  protocol    = "HTTP"
  vpc_id      = aws_vpc.task-vpc.id
  target_type = "ip"

  health_check {
    path                = "/"
    port                = "5000"
    protocol            = "HTTP"
    interval            = 30
    healthy_threshold   = 2
    unhealthy_threshold = 2
    timeout             = 5
  }
}

# ALB Listener
resource "aws_lb_listener" "backend_listener" {
  load_balancer_arn = aws_lb.backend-load-balancer.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.backend-target-group.arn
  }
}

##############################
# OUTPUTS
##############################
output "alb_dns" {
  value = aws_lb.backend-load-balancer.dns_name
}
