#!/usr/bin/env python3
"""
Verify that our local docker-compose generates the same app-compose hash as deployed,
using the salt from the deployed version.
"""

import json
import sys
from pathlib import Path

# Import our hash generation functions
import importlib.util
spec = importlib.util.spec_from_file_location("get_compose_hash", "./get-compose-hash.py")
get_compose_hash_module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(get_compose_hash_module)

docker_compose_to_app_compose = get_compose_hash_module.docker_compose_to_app_compose
to_dstack_format_json = get_compose_hash_module.to_dstack_format_json

def verify_deployed_hash(docker_compose_path: str, deployed_app_compose_path: str):
    """
    Verify our local compose generates same hash as deployed when using deployed salt.
    """

    # Load deployed app-compose to get the salt
    with open(deployed_app_compose_path, 'r') as f:
        deployed_app_compose = json.load(f)

    deployed_salt = deployed_app_compose.get("salt")

    # Calculate deployed hash
    import hashlib
    with open(deployed_app_compose_path, 'rb') as f:
        deployed_hash = hashlib.sha256(f.read()).hexdigest()

    print(f"Deployed salt: {deployed_salt}")
    print(f"Deployed hash: {deployed_hash}")

    # Generate our app-compose with the deployed salt
    our_app_compose = docker_compose_to_app_compose(docker_compose_path)
    our_app_compose["salt"] = deployed_salt  # Use deployed salt

    # Generate the formatted JSON using the exact template but with deployed salt
    docker_compose_content = our_app_compose["docker_compose_file"]
    pre_launch_script = our_app_compose["pre_launch_script"]

    # Escape strings for JSON
    docker_compose_escaped = json.dumps(docker_compose_content, ensure_ascii=False)[1:-1]  # Remove outer quotes
    pre_launch_escaped = json.dumps(pre_launch_script, ensure_ascii=False)[1:-1]  # Remove outer quotes

    # Use the exact template format but with deployed salt
    our_formatted_json = f'''{{
    "allowed_envs":[],
    "default_gateway_domain":null,
    "docker_compose_file":"{docker_compose_escaped}",
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
    "pre_launch_script":"{pre_launch_escaped}",
    "public_logs":true,
    "public_sysinfo":true,
    "runner":"docker-compose",
    "salt":"{deployed_salt}",
    "tproxy_enabled":true
}}'''

    # Save for inspection
    with open('our-app-compose-with-deployed-salt.json', 'w') as f:
        f.write(our_formatted_json)

    import hashlib
    our_hash = hashlib.sha256(our_formatted_json.encode('utf-8')).hexdigest()

    print(f"Our hash (with deployed salt): {our_hash}")

    if our_hash == deployed_hash:
        print("✅ HASH MATCH - Our compose generates same hash as deployed!")
        return True
    else:
        print("❌ HASH MISMATCH - Need to investigate differences")
        print("\nSaved files for inspection:")
        print("- our-app-compose-with-deployed-salt.json")
        print(f"- {deployed_app_compose_path}")
        return False

if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("Usage: python3 verify-deployed-hash.py <docker-compose-deploy.yml> <deployed-app-compose.json>")
        sys.exit(1)

    docker_compose_path = sys.argv[1]
    deployed_app_compose_path = sys.argv[2]

    success = verify_deployed_hash(docker_compose_path, deployed_app_compose_path)
    sys.exit(0 if success else 1)