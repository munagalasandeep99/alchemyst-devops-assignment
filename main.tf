terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

data "aws_availability_zones" "available" {
  state = "available"
}

# Latest Amazon Linux 2023 AMI
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.common_tags, { Name = "${var.project}-vpc" })
}

resource "aws_subnet" "private" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnet_cidr
  availability_zone = data.aws_availability_zones.available.names[0]

  tags = merge(local.common_tags, { Name = "${var.project}-private" })
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidr
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true

  tags = merge(local.common_tags, { Name = "${var.project}-public" })
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
  tags   = merge(local.common_tags, { Name = "${var.project}-igw" })
}

resource "aws_eip" "nat" {
  domain     = "vpc"
  depends_on = [aws_internet_gateway.igw]
  tags       = merge(local.common_tags, { Name = "${var.project}-nat-eip" })
}

resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public.id
  depends_on    = [aws_internet_gateway.igw]
  tags          = merge(local.common_tags, { Name = "${var.project}-nat" })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = merge(local.common_tags, { Name = "${var.project}-public-rt" })
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat.id
  }

  tags = merge(local.common_tags, { Name = "${var.project}-private-rt" })
}

resource "aws_route_table_association" "private" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private.id
}

resource "aws_security_group" "gateway" {
  name        = "${var.project}-gateway-sg"
  description = "Allow HTTP/HTTPS from internet; SSH from bastion CIDR"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.ssh_allowed_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, { Name = "${var.project}-gateway-sg" })
}

resource "aws_security_group" "engine" {
  name        = "${var.project}-engine-sg"
  description = "iii engine: internal VPC traffic on required ports"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "iii WebSocket port from workers"
    from_port   = 49134
    to_port     = 49134
    protocol    = "tcp"
    cidr_blocks = [var.private_subnet_cidr]
  }

  ingress {
    description = "iii HTTP REST port from gateway"
    from_port   = 3111
    to_port     = 3111
    protocol    = "tcp"
    cidr_blocks = [var.private_subnet_cidr, var.public_subnet_cidr]
  }

  ingress {
    description     = "SSH from gateway"
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.gateway.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, { Name = "${var.project}-engine-sg" })
}

resource "aws_security_group" "workers" {
  name        = "${var.project}-workers-sg"
  description = "Worker VMs: internal VPC traffic on required ports"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "iii WebSocket connection to engine"
    from_port   = 49134
    to_port     = 49134
    protocol    = "tcp"
    cidr_blocks = [var.private_subnet_cidr]
  }

  ingress {
    description     = "SSH from gateway"
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.gateway.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, { Name = "${var.project}-workers-sg" })
}

resource "aws_key_pair" "deployer" {
  key_name   = "${var.project}-key"
  public_key = file(var.public_key_path)
  tags       = local.common_tags
}

resource "aws_iam_role" "ssm_role" {
  name = "${var.project}-ssm-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action    = "sts:AssumeRole"
        Effect    = "Allow"
        Principal = { Service = "ec2.amazonaws.com" }
      }
    ]
  })

  tags = merge(local.common_tags, { Name = "${var.project}-ssm-role" })
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.ssm_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ssm_profile" {
  name = "${var.project}-ssm-profile"
  role = aws_iam_role.ssm_role.name
}

# --- Engine VM (private) ---
resource "aws_instance" "engine" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = var.engine_instance_type
  subnet_id              = aws_subnet.private.id
  vpc_security_group_ids = [aws_security_group.engine.id]
  key_name               = aws_key_pair.deployer.key_name
  iam_instance_profile   = aws_iam_instance_profile.ssm_profile.name

  root_block_device {
    volume_size = 60
    volume_type = "gp3"
  }

  user_data = <<-EOF
    #!/bin/bash
    set -euxo pipefail
    exec > /var/log/user-data.log 2>&1

    # Install git
    dnf install -y git

    # Install iii engine (fix: was "curl -fsSL curl -fsSL ..." duplicate typo)
    curl -fsSL https://install.iii.dev/iii/main/install.sh | sh
    export PATH=$PATH:/root/.local/bin

    # Init iii project
    mkdir -p /opt/iii-engine
    cd /opt/iii-engine
    /root/.local/bin/iii project init

    # Write config with iii-http enabled
    cat > /opt/iii-engine/config.yaml <<'CONF'
workers:
  - name: iii-observability
    config:
      enabled: true
      service_name: iii
      exporter: memory
      memory_max_spans: 10000
      metrics_enabled: true
      metrics_exporter: memory
      logs_enabled: true
      logs_exporter: memory
      logs_console_output: true
      sampling_ratio: 1.0
  - name: iii-queue
    config:
      adapter:
        name: builtin
  - name: iii-http
    config:
      port: 3111
      host: 0.0.0.0
      default_timeout: 120000
      concurrency_request_limit: 1024
      cors:
        allowed_origins:
          - '*'
        allowed_methods:
          - GET
          - POST
          - PUT
          - DELETE
          - OPTIONS
CONF

    # Create systemd service
    cat > /etc/systemd/system/iii-engine.service <<'SVC'
[Unit]
Description=iii Engine
After=network.target

[Service]
User=root
WorkingDirectory=/opt/iii-engine
ExecStart=/root/.local/bin/iii
Restart=always
RestartSec=5
Environment=PATH=/root/.local/bin:/usr/local/bin:/usr/bin:/bin

[Install]
WantedBy=multi-user.target
SVC

    systemctl daemon-reload
    systemctl enable --now iii-engine
  EOF

  tags = merge(local.common_tags, { Name = "${var.project}-engine", Role = "engine" })
}

# --- Inference Worker VM (private) ---
resource "aws_instance" "inference" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = var.inference_instance_type
  subnet_id              = aws_subnet.private.id
  vpc_security_group_ids = [aws_security_group.workers.id]
  key_name               = aws_key_pair.deployer.key_name
  iam_instance_profile   = aws_iam_instance_profile.ssm_profile.name

  root_block_device {
    volume_size = 60
    volume_type = "gp3"
  }

  depends_on = [aws_instance.engine]

  user_data = <<-EOF
    #!/bin/bash
    set -euxo pipefail
    exec > /var/log/user-data.log 2>&1

    ENGINE_IP="${aws_instance.engine.private_ip}"

    # Install deps (Python 3.11 explicit)
    dnf install -y python3.11 python3.11-pip git
    alternatives --install /usr/bin/python3 python3 /usr/bin/python3.11 1

    # Clone repo
    git clone https://github.com/Alchemyst-ai/hiring.git /opt/hiring

    cd /opt/hiring/may-2026/devops/quickstart/workers/inference-worker

    # Fix inference_worker.py to return a dict instead of bare string
    python3 - <<'PYFIX'
import re
path = 'inference_worker.py'
content = open(path).read()
content = content.replace('return result', 'return {"result": result}')
open(path, 'w').write(content)
PYFIX

    # Install CPU torch (avoids 2GB CUDA download on CPU-only instance)
    pip3.11 cache purge
    pip3.11 install --no-cache-dir torch --index-url https://download.pytorch.org/whl/cpu
    pip3.11 install --no-cache-dir iii-sdk==0.11.0 watchfiles transformers gguf accelerate

    # Systemd service — heredoc unquoted so $ENGINE_IP expands from bash var set above
    cat > /etc/systemd/system/iii-inference.service <<SVC
[Unit]
Description=iii Inference Worker
After=network.target

[Service]
User=root
WorkingDirectory=/opt/hiring/may-2026/devops/quickstart/workers/inference-worker
Environment=III_URL=ws://$ENGINE_IP:49134
ExecStart=/usr/bin/python3.11 inference_worker.py
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
SVC

    systemctl daemon-reload
    systemctl enable --now iii-inference
  EOF

  tags = merge(local.common_tags, { Name = "${var.project}-inference", Role = "inference-worker" })
}

# --- Caller Worker VM (private) ---
resource "aws_instance" "caller" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = var.caller_instance_type
  subnet_id              = aws_subnet.private.id
  vpc_security_group_ids = [aws_security_group.workers.id]
  key_name               = aws_key_pair.deployer.key_name
  iam_instance_profile   = aws_iam_instance_profile.ssm_profile.name

  root_block_device {
    volume_size = 60
    volume_type = "gp3"
  }

  depends_on = [aws_instance.engine]

  user_data = <<-EOF
    #!/bin/bash
    set -euxo pipefail
    exec > /var/log/user-data.log 2>&1

    ENGINE_IP="${aws_instance.engine.private_ip}"

    # Install git
    dnf install -y git python3.11
    alternatives --install /usr/bin/python3 python3 /usr/bin/python3.11 1

    # Install nvm + Node 20
    curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
    export NVM_DIR="/root/.nvm"
    source "$NVM_DIR/nvm.sh"
    nvm install 20
    nvm use 20

    # Clone repo
    git clone https://github.com/Alchemyst-ai/hiring.git /opt/hiring

    cd /opt/hiring/may-2026/devops/quickstart/workers/caller-worker

    # Fix timeouts in worker.ts
    python3 - <<'PYFIX'
path = 'src/worker.ts'
content = open(path).read()
content = content.replace(
    "function_id: 'inference::run_inference',\n      payload,\n    });",
    "function_id: 'inference::run_inference',\n      payload,\n      timeoutMs: 120000,\n    });"
)
content = content.replace(
    "function_id: 'inference::get_response',\n      payload: payload.body,\n    });",
    "function_id: 'inference::get_response',\n      payload: payload.body,\n      timeoutMs: 120000,\n    });"
)
open(path, 'w').write(content)
print("Patched worker.ts")
PYFIX

    npm install

    # Resolve the actual node/npx paths dynamically to avoid hardcoding a patch version
    NODE_BIN="$(source /root/.nvm/nvm.sh && which node)"
    NPX_BIN="$(source /root/.nvm/nvm.sh && which npx)"
    NODE_DIR="$(dirname "$NODE_BIN")"

    # Systemd service — heredoc unquoted so $ENGINE_IP, $NPX_BIN, $NODE_DIR expand from bash vars
    cat > /etc/systemd/system/iii-caller.service <<SVC
[Unit]
Description=iii Caller Worker
After=network.target

[Service]
User=root
WorkingDirectory=/opt/hiring/may-2026/devops/quickstart/workers/caller-worker
Environment=III_URL=ws://$ENGINE_IP:49134
Environment=PATH=$NODE_DIR:/usr/local/bin:/usr/bin:/bin
ExecStart=$NPX_BIN tsx src/worker.ts
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SVC

    systemctl daemon-reload
    systemctl enable --now iii-caller
  EOF

  tags = merge(local.common_tags, { Name = "${var.project}-caller", Role = "caller-worker" })
}

# --- API Gateway VM (public) ---
resource "aws_instance" "gateway" {
  ami                         = data.aws_ami.al2023.id
  instance_type               = var.gateway_instance_type
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.gateway.id]
  key_name                    = aws_key_pair.deployer.key_name
  iam_instance_profile        = aws_iam_instance_profile.ssm_profile.name
  associate_public_ip_address = true

  root_block_device {
    volume_size = 60
    volume_type = "gp3"
  }

  depends_on = [aws_instance.engine]

  user_data = <<-EOF
    #!/bin/bash
    set -euxo pipefail
    exec > /var/log/user-data.log 2>&1

    ENGINE_IP="${aws_instance.engine.private_ip}"

    # Install Nginx
    dnf install -y nginx

    # Write Nginx config — heredoc unquoted so $ENGINE_IP expands from bash var
    # nginx variables like $host are escaped with \$ to survive bash expansion
    cat > /etc/nginx/conf.d/iii.conf <<NGINX
server {
    listen 80;

    location /v1/chat/completions {
        proxy_pass http://$ENGINE_IP:3111/v1/chat/completions;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_read_timeout 300s;
        proxy_connect_timeout 10s;
        proxy_send_timeout 300s;
    }

    location /health {
        return 200 'ok';
        add_header Content-Type text/plain;
    }
}
NGINX

    # Remove default nginx config to avoid conflicts
    rm -f /etc/nginx/conf.d/default.conf

    systemctl enable --now nginx
  EOF

  tags = merge(local.common_tags, { Name = "${var.project}-gateway", Role = "api-gateway" })
}

# Elastic IP for gateway (stable public address)
resource "aws_eip" "gateway" {
  instance   = aws_instance.gateway.id
  domain     = "vpc"
  depends_on = [aws_internet_gateway.igw]
  tags       = merge(local.common_tags, { Name = "${var.project}-gateway-eip" })
}
