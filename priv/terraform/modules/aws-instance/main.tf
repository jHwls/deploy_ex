### EC2 Start ###
#################

# Pulls debian image from AWS AMI
data "aws_ami" "debian-11" {
  most_recent = true
  owners      = ["136693071363"]

  filter {
    name   = "name"
    values = ["debian-11*amd64*"]
  }
}

# Choose Subnet
resource "random_shuffle" "subnet_id" {
  input        = var.subnet_ids
  result_count = 1
}

data "aws_subnet" "random_subnet" {
  id = random_shuffle.subnet_id.result[0]
}

# Create EC2 Instance
resource "aws_instance" "ec2_instance" {
  # Enable when multi-instancing
  count = var.instance_count

  ami           = data.aws_ami.debian-11.id
  instance_type = var.instance_type

  subnet_id              = data.aws_subnet.random_subnet.id
  vpc_security_group_ids = [var.security_group_id]

  key_name = var.key_pair_key_name

  private_dns_name_options {
    hostname_type                     = "resource-name"
    enable_resource_name_dns_a_record = true
  }

  user_data = var.disable_ebs ? "" : file("${path.module}/user_data_init_script.sh")

  tags = merge({
    Name          = format("%s-%s", var.instance_name, count.index)
    Group         = var.resource_group
    InstanceGroup = lower(replace(var.instance_name, " ", "_"))
    Environment   = var.environment
    Type          = "Self Made"
  }, var.tags)
}

### EBS Start ###
#################

# Create EBS Volume
resource "aws_ebs_volume" "ec2_ebs" {
  count             = var.disable_ebs ? 0 : var.instance_count

  availability_zone = data.aws_subnet.random_subnet.availability_zone
  size              = var.instance_ebs_secondary_size

  tags = merge({
    Name          = format("%s-%s-%s", var.instance_name, "ebs", count.index) # instance-name-ebs
    InstanceGroup = lower(replace(var.instance_name, " ", "_"))
    Group         = var.resource_group
    Environment   = var.environment
    Vendor        = "Self"
    Type          = "Self Made"
  }, var.tags)
}

# Attach EBS Volume
resource "aws_volume_attachment" "ec2_ebs_association" {
  count       = var.disable_ebs ? 0 : var.instance_count

  device_name = "/dev/sdh"
  volume_id   = aws_ebs_volume.ec2_ebs[count.index].id
  instance_id = element(aws_instance.ec2_instance, count.index).id
}

### Elastic IP Start ###
########################

# Create Elastic IP
resource "aws_eip" "ec2_eip" {
  count = (var.enable_lb || var.disable_eip) ? 0 : var.instance_count

  vpc = true
  tags = merge({
    Name          = format("%s-%s-%s", var.instance_name, "eip", count.index) # instance-name-eip
    InstanceGroup = lower(replace(var.instance_name, " ", "_"))
    Group         = var.resource_group
    Environment   = var.environment
    Vendor        = "Self"
    Type          = "Self Made"
  }, var.tags)
}

# Associate Elastic IP to Linux Server
resource "aws_eip_association" "ec2_eip_association" {
  count = (var.enable_lb || var.disable_eip) ? 0 : var.instance_count

  instance_id   = element(aws_instance.ec2_instance, count.index).id
  allocation_id = aws_eip.ec2_eip[count.index].id
}

### Elastic LB Start ###
########################

# Add Load Balancing if needed and enabled
resource "aws_lb" "ec2_lb" {
  count              = (var.enable_lb && var.instance_count > 1) ? 1 : 0
  name               = format("%s-%s", (lower(replace(var.instance_name, " ", "-"))), "lb")
  load_balancer_type = "application"

  subnets = var.subnet_ids

  tags = merge({
    Name          = format("%s-%s", var.instance_name, "lb")
    InstanceGroup = lower(replace(var.instance_name, " ", "_"))
    Group         = var.resource_group
    Environment   = var.environment
    Vendor        = "Self"
    Type          = "Self Made"
  }, var.tags)
}

# Create HTTP target group
resource "aws_lb_target_group" "ec2_lb_target_group" {
  count              = (var.enable_lb && var.instance_count > 1) ? 1 : 0
  name               = format("%s-%s", (lower(replace(var.instance_name, " ", "-"))), "lb-tg")

  vpc_id             = data.aws_subnet.random_subnet.vpc_id
  protocol           = "HTTP"
  port               = 80

  tags = merge({
    Name          = format("%s-%s", var.instance_name, "lb-sg")
    InstanceGroup = lower(replace(var.instance_name, " ", "_"))
    Group         = var.resource_group
    Environment   = var.environment
    Vendor        = "Self"
    Type          = "Self Made"
  }, var.tags)
}

# Attach instances to target group
resource "aws_lb_target_group_attachment" "ec2_lb_target_group_attachment" {
  count = (var.enable_lb && var.instance_count > 1) ? var.instance_count : 0

  target_group_arn  = aws_lb_target_group.ec2_lb_target_group[0].arn
  target_id         = aws_instance.ec2_instance[count.index].id
  port              = 80
}

# Create Listener
resource "aws_lb_listener" "ec2_lb_listener" {
  load_balancer_arn = aws_lb.ec2_lb[0].arn
  port              = 80
  protocol          = aws_lb_target_group.ec2_lb_target_group[0].protocol

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.ec2_lb_target_group[0].arn
  }
}
