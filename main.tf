/* Terraform AWS provider */
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 3.27"
    }
  }
}

provider "aws" {
  profile = "default"
  region  = "me-south-1"
}

/* VPC */
resource "aws_vpc" "vpc" {
  cidr_block = "10.0.0.0/16"
}

/* NAT */
resource "aws_internet_gateway" "nat_gw" {
  vpc_id = aws_vpc.vpc.id
  depends_on = [aws_internet_gateway.ig]

}

resource "aws_eip" "nat_eip" {
  vpc        = true
  depends_on = [aws_internet_gateway.nat_gw]
}

resource "aws_nat_gateway" "nat" {
  subnet_id     = aws_subnet.private_subnet.id
  depends_on    = [aws_internet_gateway.nat_eip]
}

/* Subnets */
resource "aws_subnet" "public_subnet" {
  vpc_id        = aws_vpc.vpc.id
  cidr_block    = 10.0.0.0/24
}

resource "aws_subnet" "private_subnet" {
  vpc_id        = aws_vpc.vpc.id
  cidr_block    = 10.0.1.0/24
}

/ * IAM Role */
data "aws_iam_policy_document" "devops-assume-role-policy" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }

    principals {
      type        = "Service"
      identifiers = ["s3.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "devops_role" {
  name                = "devops_role"
  assume_role_policy = data.aws_iam_policy_document.devops-assume-role-policy.json
  managed_policy_arns = [aws_iam_policy.policy_ec2.arn, aws_iam_policy.policy_s3.arn] 
}

resource "aws_iam_instance_profile" "devops_profile" {
  name = "devops_profile"
  role = aws_iam_role.devops_role.name
}

resource "aws_iam_policy" "policy_ec2" {
  name = "policy-ec2"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action   = ["ec2:*"]
        Effect   = "Allow"
        Resource = "*"
      },
    ]
  })
}

resource "aws_iam_policy" "policy_s3" {
  name = "policy-s3"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action   = ["s3:*"]
        Effect   = "Allow"
        Resource = "*"
      },
    ]
  })
}



/* EC2 */
data "aws_ami" "amazon-linux-2" {
 most_recent = true

 filter {
   name   = "owner-alias"
   values = ["amazon"]
 }

 filter {
   name   = "name"
   values = ["amzn2-ami-hvm*"]
 }
}

resource "aws_instance" "apache" {
  ami                   = data.aws_ami.amazon-linux-2.id
  instance_type         = "t2.micro"
  iam_instance_profile  = aws_iam_instance_profile.devops_profile.name
  subnet_id             = aws_subnet.private_subnet.id
  user_data             = <<-EOF
                          #!/bin/bash
                          sudo su
                          yum -y install httpd
                          sudo systemctl enable httpd
                          sudo systemctl start httpd
                          EOF
}

/* ELB */
resource "aws_elb" "apache_elb" {
  availability_zones = ["me-south-1a", "me-south-1b", "me-south-1c"]

  listener {
    instance_port     = 8000
    instance_protocol = "http"
    lb_port           = 80
    lb_protocol       = "http"
  }

  health_check {
    healthy_threshold   = 5
    unhealthy_threshold = 2
    timeout             = 5
    target              = "HTTP:8000/"
    interval            = 30
  }

  instances                   = [aws_instance.apache.id]
  connection_draining         = true
}

/* Autoscaling */
resource "aws_autoscaling_group" "apache_asg" {
  name               = "apache_asg"
  availability_zones = ["me-south-1a", "me-south-1b", "me-south-1c"]
  min_size           = 1
  max_size           = 3
  load_balancers     = [aws_elb.apache_elb.name]
  health_check_type  = "ELB"
}

resource "aws_autoscaling_policy" "apache_asg_policy_up" {
  name                   = "apache_asg_policy_up"
  scaling_adjustment     = 1
  adjustment_type        = "ChangeInCapacity"
  cooldown               = 300
  autoscaling_group_name = aws_autoscaling_group.apache_asg.name
}

resource "aws_autoscaling_policy" "apache_asg_policy_down" {
  name                   = "apache_asg_policy_up"
  scaling_adjustment     = -1
  adjustment_type        = "ChangeInCapacity"
  cooldown               = 300
  autoscaling_group_name = aws_autoscaling_group.apache_asg.name
}

resource "aws_cloudwatch_metric_alarm" "apache_cpu_alarm_up" {
  alarm_name            = "apache_cpu_alarm_up"
  comparison_operator   = "GreaterThanOrEqualToThreshold"
  evaluation_periods    = "2"
  metric_name           = "CPUUtilization"
  namespace             = "AWS/EC2"
  period                = "120"
  statistic             = "Average"
  threshold             = "80"

  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.apache_asg.name
  }

  alarm_description     = "This metric monitor EC2 instance CPU utilization"
  alarm_actions         = [ aws_autoscaling_policy.apache_asg_policy_up.arn ]
}

resource "aws_cloudwatch_metric_alarm" "apache_cpu_alarm_down" {
  alarm_name            = "apache_cpu_alarm_down"
  comparison_operator   = "GreaterThanOrEqualToThreshold"
  evaluation_periods    = "2"
  metric_name           = "CPUUtilization"
  namespace             = "AWS/EC2"
  period                = "120"
  statistic             = "Average"
  threshold             = "60"

  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.apache_asg.name
  }

  alarm_description = "This metric monitor EC2 instance CPU utilization"
  alarm_actions = [ aws_autoscaling_policy.apache_asg_policy_down.arn ]
}

/* ¿¿ Persistence layer ?? */
