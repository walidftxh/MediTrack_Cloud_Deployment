terraform {

  required_version = ">= 1.6"
  required_providers {
    aws = {
      source = "hashicorp/aws", version = ">= 5.80, < 7.0"
    }

  }


}

provider "aws" {
  region  = var.region
  profile = var.profile
}

variable "region" {
  type    = string
  default = "eu-west-3"
}

variable "profile" {
  type    = string
  default = "meditrack-deploy"
}

variable "admin_cidr" {
  type        = string
  description = "IP publique administrateur /32"
}

variable "ssh_public_key_path" {
  type = string
}

data "aws_availability_zones" "current" {
  state = "available"
}

data "aws_ami" "ubuntu" {

  most_recent = true
  owners      = ["099720109477"]
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }


}

resource "aws_vpc" "main" {

  cidr_block           = "10.42.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = {
    Name = "meditrack-vpc"
  }


}

resource "aws_subnet" "public" {

  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.42.1.0/24"
  availability_zone = data.aws_availability_zones.current.names[0]
  tags = {
    Name = "meditrack-public"
  }


}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
}

resource "aws_route_table" "public" {

  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }


}

resource "aws_route_table_association" "public" {

  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id

}

resource "aws_security_group" "web" {

  name   = "meditrack-web"
  vpc_id = aws_vpc.main.id
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.admin_cidr]
  }

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

resource "aws_key_pair" "admin" {

  key_name   = "meditrack-admin"
  public_key = file(var.ssh_public_key_path)

}

resource "aws_instance" "demo" {

  ami                         = data.aws_ami.ubuntu.id
  instance_type               = "t3.micro"
  subnet_id                   = aws_subnet.public.id
  associate_public_ip_address = true
  vpc_security_group_ids      = [aws_security_group.web.id]
  key_name                    = aws_key_pair.admin.key_name
  metadata_options {
    http_tokens = "required"
  }

  root_block_device {
    encrypted   = true
    volume_type = "gp3"
    volume_size = 12
  }

  tags = {
    Name = "meditrack-ansible-demo"
  }


}

resource "aws_s3_bucket" "site" {
  bucket_prefix = "meditrack-static-"
}

resource "aws_s3_bucket_public_access_block" "site" {

  bucket                  = aws_s3_bucket.site.id
  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true

}

resource "aws_s3_bucket_server_side_encryption_configuration" "site" {

  bucket = aws_s3_bucket.site.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }

  }


}

resource "aws_s3_bucket_versioning" "site" {

  bucket = aws_s3_bucket.site.id
  versioning_configuration {
    status = "Enabled"
  }


}

resource "aws_cloudfront_origin_access_control" "site" {

  name                              = "meditrack-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"

}

resource "aws_cloudfront_distribution" "site" {

  enabled             = true
  default_root_object = "index.html"
  price_class         = "PriceClass_100"
  origin {

    domain_name              = aws_s3_bucket.site.bucket_regional_domain_name
    origin_id                = "private-s3"
    origin_access_control_id = aws_cloudfront_origin_access_control.site.id

  }

  default_cache_behavior {

    target_origin_id       = "private-s3"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true
    forwarded_values {
      query_string = false
      cookies {
        forward = "none"
      }

    }

    min_ttl     = 0
    default_ttl = 300
    max_ttl     = 3600

  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }

  }

  viewer_certificate {
    cloudfront_default_certificate = true
    minimum_protocol_version       = "TLSv1.2_2021"
  }


}

data "aws_iam_policy_document" "read" {

  statement {

    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.site.arn}/*"]
    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    condition {

      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.site.arn]

    }


  }


}

resource "aws_s3_bucket_policy" "read" {

  bucket     = aws_s3_bucket.site.id
  policy     = data.aws_iam_policy_document.read.json
  depends_on = [aws_s3_bucket_public_access_block.site]

}

output "bucket_name" {
  value = aws_s3_bucket.site.bucket
}

output "cloudfront_url" {
  value = "https://${aws_cloudfront_distribution.site.domain_name}"
}

output "cloudfront_id" {
  value = aws_cloudfront_distribution.site.id
}

output "ec2_ip" {
  value = aws_instance.demo.public_ip
}

