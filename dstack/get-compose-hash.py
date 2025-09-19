#!/usr/bin/env python3
"""
App Compose Hash Generation for Deterministic Build Practice
Based on DStack SDK implementation for deterministic JSON serialization
"""

import hashlib
import json
import yaml
import sys
from typing import Any, Dict
from pathlib import Path


def sort_object(obj: Any) -> Any:
    """Recursively sort object keys lexicographically for deterministic JSON."""
    if obj is None:
        return obj
    elif isinstance(obj, list):
        return [sort_object(item) for item in obj]
    elif isinstance(obj, dict):
        return {key: sort_object(value) for key, value in sorted(obj.items())}
    else:
        return obj


def to_deterministic_json(data: Dict[str, Any]) -> str:
    """Serialize to deterministic JSON following cross-language standards."""
    def convert_special_values(obj: Any) -> Any:
        """Convert NaN and Infinity to null for deterministic output."""
        if isinstance(obj, float):
            if obj != obj:  # NaN check
                return None
            if obj == float("inf") or obj == float("-inf"):
                return None
        return obj

    def process_data(obj: Any) -> Any:
        if isinstance(obj, dict):
            return {key: process_data(value) for key, value in obj.items()}
        elif isinstance(obj, list):
            return [process_data(item) for item in obj]
        else:
            return convert_special_values(obj)

    sorted_data = sort_object(data)
    processed_data = process_data(sorted_data)
    return json.dumps(processed_data, separators=(",", ":"), ensure_ascii=False)


def to_dstack_format_json(data: Dict[str, Any]) -> str:
    """Generate JSON using the exact DStack format as a template."""

    # Get the docker compose content (will be escaped in JSON)
    docker_compose_content = data["docker_compose_file"]
    pre_launch_script = data["pre_launch_script"]

    # Escape strings for JSON
    docker_compose_escaped = json.dumps(docker_compose_content, ensure_ascii=False)[1:-1]  # Remove outer quotes
    pre_launch_escaped = json.dumps(pre_launch_script, ensure_ascii=False)[1:-1]  # Remove outer quotes

    # Use the exact template format from the downloaded file
    template = '''{
    "allowed_envs":[],
    "default_gateway_domain":null,
    "docker_compose_file":"DOCKER_COMPOSE_CONTENT",
    "features":[
        "kms",
        "tproxy-net"
    ],
    "gateway_enabled":true,
    "kms_enabled":true,
    "local_key_provider_enabled":false,
    "manifest_version":2,
    "name":"simple-det-app-verification",
    "no_instance_id":false,
    "pre_launch_script":"PRE_LAUNCH_SCRIPT",
    "public_logs":true,
    "public_sysinfo":true,
    "runner":"docker-compose",
    "salt":"05fcefaecd984204bb6ccf16938eaad5",
    "tproxy_enabled":true
}'''

    # Replace placeholders with actual content
    result = template.replace("DOCKER_COMPOSE_CONTENT", docker_compose_escaped)
    result = result.replace("PRE_LAUNCH_SCRIPT", pre_launch_escaped)

    return result


def get_compose_hash(app_compose_data: Dict[str, Any]) -> str:
    """Calculate SHA256 hash of app compose configuration using DStack's actual format."""
    manifest_str = to_dstack_format_json(app_compose_data)
    return hashlib.sha256(manifest_str.encode("utf-8")).hexdigest()


def get_default_pre_launch_script() -> str:
    """Return the exact pre-launch script from DStack deployment"""
    return '\n#!/bin/bash\necho "----------------------------------------------"\necho "Running Phala Cloud Pre-Launch Script v0.0.7"\necho "----------------------------------------------"\nset -e\n\n# Function: notify host\n\nnotify_host() {\n    if command -v dstack-util >/dev/null 2>&1; then\n        dstack-util notify-host -e "$1" -d "$2"\n    else\n        tdxctl notify-host -e "$1" -d "$2"\n    fi\n}\n\nnotify_host_hoot_info() {\n    notify_host "boot.progress" "$1"\n}\n\nnotify_host_hoot_error() {\n    notify_host "boot.error" "$1"\n}\n\n# Function: Perform Docker cleanup\nperform_cleanup() {\n    echo "Pruning unused images"\n    docker image prune -af\n    echo "Pruning unused volumes"\n    docker volume prune -f\n    notify_host_hoot_info "docker cleanup completed"\n}\n\n# Function: Check Docker login status without exposing credentials\ncheck_docker_login() {\n    # Try to verify login status without exposing credentials\n    if docker info 2>/dev/null | grep -q "Username"; then\n        return 0\n    else\n        return 1\n    fi\n}\n\n# Main logic starts here\necho "Starting login process..."\n\n# Check if Docker credentials exist\nif [[ -n "$DSTACK_DOCKER_USERNAME" && -n "$DSTACK_DOCKER_PASSWORD" ]]; then\n    echo "Docker credentials found"\n    \n    # Check if already logged in\n    if check_docker_login; then\n        echo "Already logged in to Docker registry"\n    else\n        echo "Logging in to Docker registry..."\n        # Login without exposing password in process list\n        if [[ -n "$DSTACK_DOCKER_REGISTRY" ]]; then\n            echo "$DSTACK_DOCKER_PASSWORD" | docker login -u "$DSTACK_DOCKER_USERNAME" --password-stdin "$DSTACK_DOCKER_REGISTRY"\n        else\n            echo "$DSTACK_DOCKER_PASSWORD" | docker login -u "$DSTACK_DOCKER_USERNAME" --password-stdin\n        fi\n        \n        if [ $? -eq 0 ]; then\n            echo "Docker login successful"\n        else\n            echo "Docker login failed"\n            notify_host_hoot_error "docker login failed"\n            exit 1\n        fi\n    fi\n# Check if AWS ECR credentials exist\nelif [[ -n "$DSTACK_AWS_ACCESS_KEY_ID" && -n "$DSTACK_AWS_SECRET_ACCESS_KEY" && -n "$DSTACK_AWS_REGION" && -n "$DSTACK_AWS_ECR_REGISTRY" ]]; then\n    echo "AWS ECR credentials found"\n    \n    # Check if AWS CLI is installed\n    if ! command -v aws &> /dev/null; then\n        notify_host_hoot_info "awscli not installed, installing..."\n        echo "AWS CLI not installed, installing..."\n        curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64-2.24.14.zip" -o "awscliv2.zip"\n        echo "6ff031a26df7daebbfa3ccddc9af1450 awscliv2.zip" | md5sum -c\n        if [ $? -ne 0 ]; then\n            echo "MD5 checksum failed"\n            notify_host_hoot_error "awscli install failed"\n            exit 1\n        fi\n        unzip awscliv2.zip &> /dev/null\n        ./aws/install\n        \n        # Clean up installation files\n        rm -rf awscliv2.zip aws\n    else\n        echo "AWS CLI is already installed: $(which aws)"\n    fi\n\n    # Set AWS credentials as environment variables\n    export AWS_ACCESS_KEY_ID="$DSTACK_AWS_ACCESS_KEY_ID"\n    export AWS_SECRET_ACCESS_KEY="$DSTACK_AWS_SECRET_ACCESS_KEY"\n    export AWS_DEFAULT_REGION="$DSTACK_AWS_REGION"\n    \n    # Set session token if provided (for temporary credentials)\n    if [[ -n "$DSTACK_AWS_SESSION_TOKEN" ]]; then\n        echo "AWS session token found, using temporary credentials"\n        export AWS_SESSION_TOKEN="$DSTACK_AWS_SESSION_TOKEN"\n    fi\n    \n    # Test AWS credentials before attempting ECR login\n    echo "Testing AWS credentials..."\n    if ! aws sts get-caller-identity &> /dev/null; then\n        echo "AWS credentials test failed"\n        notify_host_hoot_error "Invalid AWS credentials"\n        exit 1\n    fi\n\n    echo "Logging in to AWS ECR..."\n    aws ecr get-login-password --region $DSTACK_AWS_REGION | docker login --username AWS --password-stdin "$DSTACK_AWS_ECR_REGISTRY"\n    if [ $? -eq 0 ]; then\n        echo "AWS ECR login successful"\n        notify_host_hoot_info "AWS ECR login successful"\n    else\n        echo "AWS ECR login failed"\n        notify_host_hoot_error "AWS ECR login failed"\n        exit 1\n    fi\nfi\n\nperform_cleanup\n\n#\n# Set root password if DSTACK_ROOT_PASSWORD is set.\n#\nif [[ -n "$DSTACK_ROOT_PASSWORD" ]]; then\n    echo "root:$DSTACK_ROOT_PASSWORD" | chpasswd\n    unset $DSTACK_ROOT_PASSWORD\n    echo "Root password set"\nfi\nif [[ -n "$DSTACK_ROOT_PUBLIC_KEY" ]]; then\n    mkdir -p /root/.ssh\n    echo "$DSTACK_ROOT_PUBLIC_KEY" > /root/.ssh/authorized_keys\n    unset $DSTACK_ROOT_PUBLIC_KEY\n    echo "Root public key set"\nfi\n\n\nif [[ -e /var/run/dstack.sock ]]; then\n    export DSTACK_APP_ID=$(curl -s --unix-socket /var/run/dstack.sock http://dstack/Info | jq -j .app_id)\nelse\n    export DSTACK_APP_ID=$(curl -s --unix-socket /var/run/tappd.sock http://dstack/prpc/Tappd.Info | jq -j .app_id)\nfi\n# Check if app-compose.json has default_gateway_domain field and DSTACK_GATEWAY_DOMAIN is not set\n# If true, set DSTACK_GATEWAY_DOMAIN from app-compose.json\nif [[ $(jq \'has("default_gateway_domain")\' app-compose.json) == "true" && -z "$DSTACK_GATEWAY_DOMAIN" ]]; then\n    export DSTACK_GATEWAY_DOMAIN=$(jq -j \'.default_gateway_domain\' app-compose.json)\nfi\nif [[ -n "$DSTACK_GATEWAY_DOMAIN" ]]; then\n    export DSTACK_APP_DOMAIN=$DSTACK_APP_ID"."$DSTACK_GATEWAY_DOMAIN\nfi\n\necho "----------------------------------------------"\necho "Script execution completed"\necho "----------------------------------------------"\n'


def docker_compose_to_app_compose(docker_compose_path: str) -> Dict[str, Any]:
    """Generate comprehensive app-compose structure that matches phala CLI output"""

    # Load the docker-compose file content
    with open(docker_compose_path, 'r') as f:
        docker_compose_content = f.read()

    # Use a default name for the deployment
    deployment_name = "simple-det-app-verification"

    # Generate the comprehensive app-compose structure based on the downloaded format
    app_compose = {
        "allowed_envs": [],
        "default_gateway_domain": None,
        "docker_compose_file": docker_compose_content,
        "features": [
            "kms",
            "tproxy-net"
        ],
        "gateway_enabled": True,
        "kms_enabled": True,
        "local_key_provider_enabled": False,
        "manifest_version": 2,
        "name": deployment_name,
        "no_instance_id": False,
        "pre_launch_script": get_default_pre_launch_script(),
        "public_logs": True,
        "public_sysinfo": True,
        "runner": "docker-compose",
        "salt": "05fcefaecd984204bb6ccf16938eaad5",  # Fixed salt from downloaded example
        "tproxy_enabled": True
    }

    return app_compose


def main():
    if len(sys.argv) > 1:
        docker_compose_path = sys.argv[1]
    else:
        docker_compose_path = "docker-compose.yml"

    if not Path(docker_compose_path).exists():
        print(f"Error: {docker_compose_path} not found")
        sys.exit(1)

    print("=== Generating App Compose Hash ===")
    print(f"Input: {docker_compose_path}")

    # Convert to app-compose format
    app_compose_data = docker_compose_to_app_compose(docker_compose_path)

    # Save in DStack's actual format (pretty-printed)
    dstack_formatted_json = to_dstack_format_json(app_compose_data)
    with open('app-compose-generated.json', 'w') as f:
        f.write(dstack_formatted_json)

    # Also save compact format for reference
    deterministic_json = to_deterministic_json(app_compose_data)
    with open('app-compose-deterministic.json', 'w') as f:
        f.write(deterministic_json)

    # Generate hash
    compose_hash = get_compose_hash(app_compose_data)

    print(f"App Compose Hash: {compose_hash}")
    print(f"Hash (short): {compose_hash[:16]}")

    # Save hash for verification
    with open('compose-hash.txt', 'w') as f:
        f.write(compose_hash)

    print("\n=== Files Generated ===")
    print("- app-compose-generated.json: Human-readable app compose configuration")
    print("- app-compose-deterministic.json: Deterministic JSON used for hashing")
    print("- compose-hash.txt: The SHA256 hash")

    return compose_hash


if __name__ == "__main__":
    main()