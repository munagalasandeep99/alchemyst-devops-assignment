# Alchemyst DevOps Internship Assignment

**Repo:** https://github.com/munagalasandeep99/alchemyst-devops-assignment

---

## Overview

This project deploys the [quickstart](https://github.com/Alchemyst-ai/hiring/tree/main/may-2026/devops/quickstart) distributed inference system across 4 AWS EC2 VMs inside a private VPC, fulfilling all requirements of the Alchemyst DevOps internship assignment:

- **Private subnet** — only the Nginx gateway VM has a public IP; all workers are in a private subnet with no direct internet exposure
- **Workers on separate VMs** — each worker (inference, caller) runs on its own EC2 instance; the `iii` engine runs on a dedicated VM; all communicate via RPC across the subnet
- **JSON HTTP API** — Nginx on the gateway accepts HTTP POST requests and proxies them through the RPC chain to the model, returning JSON
- **Fully reproducible** — everything is Terraform; `terraform apply` provisions and configures all 4 VMs from scratch via `user_data` scripts; no manual console steps required

A Python worker loads the Gemma 270M model and exposes inference via RPC. A TypeScript worker fans HTTP requests into that RPC and returns JSON. Only the Nginx gateway VM is publicly reachable — all workers communicate privately over the subnet.

---

## Architecture

```
Internet
    │
    ▼
┌─────────────────────────────────────────────────────────┐
│  Public Subnet (10.0.0.0/24)                            │
│                                                         │
│  ┌──────────────────────────────┐                       │
│  │  vm-gateway  (t3.micro)      │  EIP: <gateway_ip>    │
│  │  Nginx :80                   │                       │
│  │  Proxies → engine:3111       │                       │
│  └──────────────┬───────────────┘                       │
└─────────────────│───────────────────────────────────────┘
                  │ proxy_pass (HTTP)
┌─────────────────│───────────────────────────────────────┐
│  Private Subnet (10.0.1.0/24)                           │
│                                                         │
│  ┌──────────────▼───────────────┐                       │
│  │  vm-engine  (t3.small)       │  10.0.1.x             │
│  │  iii engine                  │                       │
│  │  WebSocket  :49134           │                       │
│  │  HTTP REST  :3111            │                       │
│  └────┬──────────────┬──────────┘                       │
│       │ RPC          │ RPC                              │
│  ┌────▼──────┐  ┌────▼──────────────────┐              │
│  │vm-caller  │  │ vm-inference          │              │
│  │(t3.small) │  │ (t3.medium)           │              │
│  │TypeScript │  │ Python                │              │
│  │caller-    │  │ inference-worker      │              │
│  │worker     │  │ Gemma 270M (GGUF Q8)  │              │
│  └───────────┘  └───────────────────────┘              │
│                                                         │
│  NAT Gateway → Internet (for package installs on boot)  │
└─────────────────────────────────────────────────────────┘
```

### RPC Flow

```
curl POST /v1/chat/completions
    → Nginx (gateway)
    → iii HTTP worker (engine :3111)
    → http::run_inference_over_http  (caller-worker, TypeScript)
    → inference::get_response        (caller-worker, TypeScript)
    → inference::run_inference       (inference-worker, Python)
    → Gemma 270M model
    → response JSON
```

---

## Infrastructure

All infrastructure is defined in Terraform (`main.tf`, `variables.tf`, `outputs.tf`, `locals.tf`). No manual console steps are needed.

### Resources provisioned

- 1 VPC (`10.0.0.0/16`) with public + private subnets in a single AZ
- Internet Gateway + NAT Gateway (private VMs can pull packages on first boot)
- Route tables for both subnets
- Security groups:
  - Gateway: inbound HTTP (80), HTTPS (443), SSH from configurable CIDR
  - Engine: inbound WebSocket (49134) and HTTP (3111) from private subnet only; SSH from gateway SG
  - Workers: inbound WebSocket (49134) from private subnet only; SSH from gateway SG
- IAM role with SSM Managed Instance Core policy (for SSM Session Manager access)
- 4 EC2 instances with `user_data` shell scripts that fully install and start each service on first boot
- Elastic IP attached to the gateway VM (stable public address)

### VM roles

| VM | Instance type | Subnet | Service |
|----|--------------|--------|---------|
| vm-gateway | t3.micro | Public | Nginx reverse proxy |
| vm-engine | t3.small | Private | `iii` engine (WebSocket hub + HTTP API) |
| vm-caller | t3.small | Private | TypeScript caller-worker |
| vm-inference | t3.medium | Private | Python inference-worker (Gemma 270M) |

---

## Redeploy from Scratch

### Prerequisites

- AWS CLI installed and configured (`aws configure`)
- Terraform >= 1.6
- An SSH key pair at `~/.ssh/id_rsa` / `~/.ssh/id_rsa.pub` (or set `public_key_path` in `terraform.tfvars`)

### Steps

```bash
# 1. Clone this repo
git clone https://github.com/munagalasandeep99/alchemyst-devops-assignment.git
cd alchemyst-devops-assignment

# 2. Configure variables
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars:
#   - Set ssh_allowed_cidr to your IP: "X.X.X.X/32"
#   - Verify public_key_path points to your SSH public key

# 3. Deploy
terraform init
terraform plan
terraform apply

# 4. Wait for user_data scripts to finish on all VMs (~5–10 minutes)
#    The inference VM takes the longest — it installs PyTorch and downloads Gemma 270M (~300 MB)

# 5. Test the API
curl -X POST http://$(terraform output -raw gateway_public_ip)/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"messages":[{"role":"user","content":"What is 2+2?"}]}' \
  --max-time 180
```

### Tear down

```bash
terraform destroy
```

---

## API Reference

### Endpoint

```
POST http://<gateway_public_ip>/v1/chat/completions
```

### Request body

```json
{
  "messages": [
    { "role": "user", "content": "Your prompt here" }
  ]
}
```

### Sample curl

```bash
curl -X POST http://$(terraform output -raw gateway_public_ip)/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"messages":[{"role":"user","content":"What is 2+2?"}]}' \
  --max-time 180
```

### Sample response

```json
{
  "result": {
    "result": "2+2 equals 4."
  },
  "success": "You've connected two workers and they're interoperating seamlessly..."
}
```

> **Note on inference latency:** During testing, inference requests timed out before returning a response. The full RPC chain is wired correctly — the request flows from Nginx → iii engine → caller-worker → inference-worker and the inference worker loads the model and registers successfully. The timeout occurs during the actual model inference step: Gemma 270M on a CPU-only `t3.medium` takes 2+ minutes per request. The `timeoutMs` on both `iii.trigger()` calls was increased to 120 000 ms and Nginx `proxy_read_timeout` was set to 300 s, but inference on CPU still exceeds this window.
>
> **Fix:** Switching the inference VM to a GPU instance (e.g. `g4dn.xlarge`, T4 GPU) would resolve this — inference takes 1–5 s on a GPU vs 2+ minutes on CPU.

---

## VM Access

Use the gateway as a jump host (bastion) to reach the private VMs. Terraform outputs the exact SSH commands:

```bash
terraform output ssh_gateway
terraform output ssh_engine_via_gateway
terraform output ssh_inference_via_gateway
terraform output ssh_caller_via_gateway
```

Or manually:

```bash
# Gateway (jump host — the only VM with a public IP)
ssh -i ~/.ssh/id_rsa ec2-user@<gateway_public_ip>

# Engine (via gateway)
ssh -i ~/.ssh/id_rsa -J ec2-user@<gateway_public_ip> ec2-user@<engine_private_ip>

# Inference worker (via gateway)
ssh -i ~/.ssh/id_rsa -J ec2-user@<gateway_public_ip> ec2-user@<inference_private_ip>

# Caller worker (via gateway)
ssh -i ~/.ssh/id_rsa -J ec2-user@<gateway_public_ip> ec2-user@<caller_private_ip>
```

### Checking service status

```bash
# On the engine VM
sudo systemctl status iii-engine
sudo journalctl -u iii-engine -f

# On the inference VM
sudo systemctl status iii-inference
sudo journalctl -u iii-inference -f

# On the caller VM
sudo systemctl status iii-caller
sudo journalctl -u iii-caller -f

# On the gateway VM
sudo systemctl status nginx
sudo tail -f /var/log/nginx/error.log
```

---

## Troubleshooting: VMs Deployed but Services Not Running

The `user_data` scripts run once on first boot and can take 5–10 minutes. If a service isn't up after waiting, SSH in and run the setup steps manually.

### Check what user_data did

```bash
sudo cat /var/log/user-data.log
```

This shows the full boot script output. Look for errors near the bottom.

### Engine VM — manual setup

```bash
ssh -i ~/.ssh/id_rsa -J ec2-user@<gateway_ip> ec2-user@<engine_private_ip>

# Install iii if missing
curl -fsSL https://install.iii.dev/iii/main/install.sh | sh
export PATH=$PATH:/root/.local/bin

# Init and configure
mkdir -p /opt/iii-engine && cd /opt/iii-engine
/root/.local/bin/iii project init

# Write the config (see main.tf for the full config.yaml content)
# Then start the service
sudo systemctl daemon-reload
sudo systemctl restart iii-engine
sudo journalctl -u iii-engine -f
```

### Inference VM — manual setup

```bash
ssh -i ~/.ssh/id_rsa -J ec2-user@<gateway_ip> ec2-user@<inference_private_ip>

# Check if Python packages are installed
pip3.11 show iii-sdk transformers

# If not, install manually
sudo pip3.11 install --no-cache-dir torch --index-url https://download.pytorch.org/whl/cpu
sudo pip3.11 install --no-cache-dir iii-sdk==0.11.0 watchfiles transformers gguf accelerate

# Check the worker code is present
ls /opt/hiring/may-2026/devops/quickstart/workers/inference-worker/

# If the repo wasn't cloned, clone it
sudo git clone https://github.com/Alchemyst-ai/hiring.git /opt/hiring

# Run the worker manually to see errors in real time
export III_URL=ws://<engine_private_ip>:49134
sudo -E python3.11 /opt/hiring/may-2026/devops/quickstart/workers/inference-worker/inference_worker.py

# Once working, restart the systemd service
sudo systemctl restart iii-inference
sudo journalctl -u iii-inference -f
```

### Caller VM — manual setup

```bash
ssh -i ~/.ssh/id_rsa -J ec2-user@<gateway_ip> ec2-user@<caller_private_ip>

# Load nvm and Node
export NVM_DIR="/root/.nvm"
source "$NVM_DIR/nvm.sh"
nvm use 20

# Check the worker code is present
ls /opt/hiring/may-2026/devops/quickstart/workers/caller-worker/

# If the repo wasn't cloned
sudo git clone https://github.com/Alchemyst-ai/hiring.git /opt/hiring

# Install npm dependencies
cd /opt/hiring/may-2026/devops/quickstart/workers/caller-worker
npm install

# Run the worker manually to see errors in real time
export III_URL=ws://<engine_private_ip>:49134
npx tsx src/worker.ts

# Once working, restart the systemd service
sudo systemctl restart iii-caller
sudo journalctl -u iii-caller -f
```

### Gateway VM — manual Nginx fix

```bash
ssh -i ~/.ssh/id_rsa ec2-user@<gateway_ip>

# Test nginx config
sudo nginx -t

# If config is missing or broken, check /etc/nginx/conf.d/iii.conf
sudo cat /etc/nginx/conf.d/iii.conf

# Reload after any config fix
sudo systemctl reload nginx
sudo tail -f /var/log/nginx/error.log
```

### Verifying the RPC chain step by step

```bash
# 1. Check engine is listening (from any private VM)
curl http://<engine_private_ip>:3111/health

# 2. Check workers connected to engine (from engine VM)
sudo journalctl -u iii-engine | grep -i "worker\|connect\|register"

# 3. Hit the engine directly (bypassing Nginx) to isolate gateway issues
curl -X POST http://<engine_private_ip>:3111/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"messages":[{"role":"user","content":"hello"}]}' \
  --max-time 180

# 4. Hit via Nginx (the full path)
curl -X POST http://<gateway_public_ip>/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"messages":[{"role":"user","content":"hello"}]}' \
  --max-time 180
```

---

## What I Would Harden Before Production

1. **TLS everywhere** — terminate HTTPS at the gateway with a real certificate (ACM + ALB, or certbot). Currently traffic from the internet to the gateway is plain HTTP.
2. **Tighten security groups** — `ssh_allowed_cidr` should be locked to a specific IP, not `0.0.0.0/0`. The engine and worker SGs currently allow all internal VPC traffic; they should be scoped to specific ports (49134, 3111) and source security groups only.
3. **Secrets management** — any API keys or tokens should live in AWS Secrets Manager or Parameter Store, not in environment variables inside systemd unit files.
4. **Model caching** — currently the model is re-downloaded from HuggingFace on every fresh deployment. Store the GGUF file in S3 and pull from there on boot to avoid rate limits and cut cold-start time significantly.or install ollama and install the modal locally and make changes in the inference code
5. **Health checks + auto-recovery** — add a load balancer with health checks so the gateway routes around a crashed worker. Systemd `Restart=always` helps but isn't sufficient alone.
6. **Observability** — ship logs to CloudWatch, add metrics for inference latency and error rates, and set up alerts for service failures.
7. **IAM least privilege** — the SSM role currently attaches `AmazonSSMManagedInstanceCore` in full; scope it down to only the specific SSM actions actually needed.

---

## What I Would Do Differently for a 100x Larger Model

1. **GPU instances** — switch the inference VM to `g4dn.xlarge` (T4 GPU) or larger. For a model 100x bigger (~27B parameters), you'd likely need `g5.12xlarge` or `p3.8xlarge` for multi-GPU inference.
2. **Model parallelism** — a 27B model won't fit on a single GPU; use tensor parallelism across multiple GPUs with a framework like vLLM or Hugging Face TGI instead of raw `transformers`.
3. **Dedicated inference service** — replace the Python worker with vLLM or TGI, which handle continuous batching, KV-cache management, and quantization out of the box — critical for throughput at scale.
4. **Horizontal scaling** — run multiple inference workers behind the engine and let `iii` load-balance across them. With a large model, each inference VM is expensive, so auto-scaling based on queue depth makes sense.
5. **Spot instances** — inference workloads can tolerate interruption with proper checkpointing; spot instances cut GPU costs by 60–70%.
6. **Model stored on EFS or S3** — a 27B GGUF file is ~15–30 GB; pulling from S3 on boot (with a pre-baked AMI for dependency layers) is essential to keep cold-start times reasonable.
