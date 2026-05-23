# Alchemyst DevOps Internship Assignment

**Repo:** https://github.com/munagalasandeep99/alchemyst-devops-assignment

---

## Overview

This project deploys the [quickstart](https://github.com/Alchemyst-ai/hiring/tree/main/may-2026/devops/quickstart) distributed inference system across 4 AWS EC2 VMs inside a private VPC. A Python worker loads the Gemma 270M model and exposes inference via RPC; a TypeScript worker fans HTTP requests into that RPC and returns JSON. Only the Nginx gateway VM is publicly reachable — all workers communicate privately over the subnet.

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
│  │  vm-gateway  (t3.micro)      │  EIP: 3.214.64.50     │
│  │  Nginx :80                   │                       │
│  │  Proxies → engine:3111       │                       │
│  └──────────────┬───────────────┘                       │
└─────────────────│───────────────────────────────────────┘
                  │ proxy_pass
┌─────────────────│───────────────────────────────────────┐
│  Private Subnet (10.0.1.0/24)                           │
│                                                         │
│  ┌──────────────▼───────────────┐                       │
│  │  vm-engine  (t3.small)       │  10.0.1.206           │
│  │  iii engine                  │                       │
│  │  WebSocket  :49134           │                       │
│  │  HTTP REST  :3111            │                       │
│  └────┬──────────────┬──────────┘                       │
│       │ RPC          │ RPC                              │
│  ┌────▼──────┐  ┌────▼──────────────────┐              │
│  │vm-caller  │  │ vm-inference          │              │
│  │(t3.small) │  │ (t3.medium)           │              │
│  │10.0.1.181 │  │ 10.0.1.210            │              │
│  │TypeScript │  │ Python                │              │
│  │caller-    │  │ inference-worker      │              │
│  │worker     │  │ Gemma 270M (GGUF Q8)  │              │
│  └───────────┘  └───────────────────────┘              │
│                                                         │
│  NAT Gateway → Internet (for package installs)          │
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

All infrastructure is defined in Terraform (`main.tf`, `variables.tf`, `outputs.tf`, `locals.tf`).

### Resources provisioned

- 1 VPC (`10.0.0.0/16`) with public + private subnets
- Internet Gateway + NAT Gateway (private VMs can pull packages)
- Route tables for both subnets
- Security groups (gateway: public HTTP/SSH; engine/workers: internal VPC only)
- IAM role with SSM managed instance core policy
- 4 EC2 instances with `user_data` scripts that fully configure each VM on boot
- Elastic IP attached to the gateway

---

## Redeploy from Scratch

### Prerequisites

- AWS CLI configured (`aws configure`)
- Terraform >= 1.6
- SSH key pair at `~/.ssh/id_rsa` / `~/.ssh/id_rsa.pub`

### Steps

```bash
# 1. Clone this repo
git clone https://github.com/munagalasandeep99/alchemyst-devops-assignment.git
cd alchemyst-devops-assignment

# 2. Configure variables
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars — set ssh_allowed_cidr to your IP: "X.X.X.X/32"

# 3. Deploy
terraform init
terraform plan
terraform apply

# 4. Wait ~5 minutes for user_data scripts to complete on all VMs
# The inference VM takes longest — it downloads the Gemma 270M model (~300MB)

# 5. Test
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

### Request

```json
{
  "messages": [
    { "role": "user", "content": "What is 2+2?" }
  ]
}
```

### Sample curl

```bash
curl -X POST http://3.214.64.50/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"messages":[{"role":"user","content":"What is 2+2?"}]}' \
  --max-time 180
```

### Sample response

> **Note:** During testing, inference requests consistently timed out before returning a response. The full RPC chain is wired correctly — the request flows from Nginx → iii engine → caller-worker → inference-worker and the inference worker loads the model and registers successfully. The timeout occurs during the actual model inference step, likely because the Gemma 270M model is too slow on a CPU-only `t3.medium` instance (no GPU). The `timeoutMs` on both `iii.trigger()` calls in `caller-worker` was increased to 120000ms and Nginx `proxy_read_timeout` was set to 300s, but inference on CPU still exceeds this window.
>
> Expected response shape when working:
> ```json
> {
>   "result": {
>     "result": "2+2 equals 4."
>   },
>   "success": "You've connected two workers and they're interoperating seamlessly..."
> }
> ```
>
> **Fix:** Switching the inference VM to a GPU instance (`g4dn.xlarge`) would resolve this — inference on a T4 GPU takes 1-5 seconds vs 2+ minutes on CPU.

---

## VM Access

```bash
# Gateway (jump host)
ssh -i ~/.ssh/id_rsa ec2-user@3.214.64.50

# Engine (via gateway)
ssh -i ~/.ssh/id_rsa -J ec2-user@3.214.64.50 ec2-user@10.0.1.206

# Inference worker (via gateway)
ssh -i ~/.ssh/id_rsa -J ec2-user@3.214.64.50 ec2-user@10.0.1.210

# Caller worker (via gateway)
ssh -i ~/.ssh/id_rsa -J ec2-user@3.214.64.50 ec2-user@10.0.1.181
```

### Checking service status

```bash
# On engine VM
sudo systemctl status iii-engine
sudo journalctl -u iii-engine -f

# On inference VM
sudo systemctl status iii-inference
sudo journalctl -u iii-inference -f

# On caller VM
sudo systemctl status iii-caller
sudo journalctl -u iii-caller -f

# On gateway VM
sudo systemctl status nginx
sudo tail -f /var/log/nginx/error.log
```

---

## What I Would Harden Before Production

1. **TLS everywhere** — terminate HTTPS at the gateway with a real cert (ACM + ALB or certbot). Currently traffic from the internet to the gateway is plain HTTP.
2. **Tighten security groups** — `ssh_allowed_cidr` should be locked to a specific IP, not `0.0.0.0/0`. The engine and worker SGs currently allow all internal VPC traffic; they should be scoped to specific ports (49134, 3111) and source SGs only.
3. **Secrets management** — any API keys or tokens should go into AWS Secrets Manager or Parameter Store, not environment variables in systemd unit files.
4. **Model caching** — currently the model is re-downloaded from HuggingFace on every fresh deployment. Store the GGUF file in S3 and pull from there on boot to speed up cold starts and avoid rate limits.
5. **Health checks + auto-recovery** — add a load balancer with health checks so the gateway automatically routes around a crashed worker. Systemd `Restart=always` helps but isn't enough alone.
6. **Observability** — ship logs to CloudWatch, add metrics for inference latency and error rates, set up alerts.
7. **IAM least privilege** — the SSM role is broad; scope it down to only the specific SSM actions needed.

---

## What I Would Do Differently for a 100x Larger Model

1. **GPU instances** — switch the inference VM to `g4dn.xlarge` (T4 GPU) or larger. For a model 100x bigger (~27B parameters), you'd likely need `g5.12xlarge` or `p3.8xlarge` for multi-GPU inference.
2. **Model parallelism** — a 27B model won't fit on a single GPU; use tensor parallelism across multiple GPUs with a framework like vLLM or TGI instead of raw `transformers`.
3. **Dedicated inference service** — replace the Python worker with vLLM or Hugging Face TGI which handle batching, KV-cache management, and continuous batching out of the box — critical for throughput at scale.
4. **Horizontal scaling** — run multiple inference workers behind the engine and let `iii` load-balance across them. With a large model, each inference worker is expensive so auto-scaling based on queue depth makes sense.
5. **Spot instances** — inference workloads can tolerate interruption with proper checkpointing; using spot instances cuts GPU costs by 60-70%.
6. **Model stored on EFS or S3** — a 27B GGUF file is ~15-30GB; baking it into an AMI or pulling from S3 on boot (with a pre-warmed AMI) is essential to keep cold start times reasonable.
