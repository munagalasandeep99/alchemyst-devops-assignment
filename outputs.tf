###############################################################################
# Outputs
###############################################################################

output "gateway_public_ip" {
  description = "Public IP of the API gateway – your single external endpoint"
  value       = aws_eip.gateway.public_ip
}

output "api_endpoint" {
  description = "Base URL for the inference JSON API"
  value       = "http://${aws_eip.gateway.public_ip}/v1/chat/completions"
}

output "engine_private_ip" {
  description = "Private IP of the iii engine VM"
  value       = aws_instance.engine.private_ip
}

output "inference_private_ip" {
  description = "Private IP of the inference-worker VM"
  value       = aws_instance.inference.private_ip
}

output "caller_private_ip" {
  description = "Private IP of the caller-worker VM"
  value       = aws_instance.caller.private_ip
}

output "ssh_gateway" {
  description = "SSH command for the gateway (jump host)"
  value       = "ssh -i ~/.ssh/id_rsa ec2-user@${aws_eip.gateway.public_ip}"
}

output "ssh_engine_via_gateway" {
  description = "SSH to engine via gateway jump"
  value       = "ssh -J ec2-user@${aws_eip.gateway.public_ip} ec2-user@${aws_instance.engine.private_ip}"
}

output "ssh_inference_via_gateway" {
  description = "SSH to inference-worker via gateway jump"
  value       = "ssh -J ec2-user@${aws_eip.gateway.public_ip} ec2-user@${aws_instance.inference.private_ip}"
}

output "ssh_caller_via_gateway" {
  description = "SSH to caller-worker via gateway jump"
  value       = "ssh -J ec2-user@${aws_eip.gateway.public_ip} ec2-user@${aws_instance.caller.private_ip}"
}
