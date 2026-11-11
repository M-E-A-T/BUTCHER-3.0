#!/bin/bash
# Ensure SSH key exists + install SSH keys with sshpass

# Password comes from the environment (SSH_PASSWORD=... ./setup_all_hosts.sh)
# or is prompted for; never hardcode it here.
PASSWORD="${SSH_PASSWORD:-}"
if [ -z "$PASSWORD" ]; then
    read -r -s -p "SSH password for hosts: " PASSWORD
    echo
fi

# generate key if none exists
if [ ! -f "$HOME/.ssh/id_ed25519" ] && [ ! -f "$HOME/.ssh/id_rsa" ]; then
    echo "=== No SSH identities found. Generating one... ==="
    ssh-keygen -t ed25519 -N "" -f "$HOME/.ssh/id_ed25519"
    echo "=== Key generated successfully ==="
else
    echo "=== SSH identity already exists ==="
fi

hosts=(
#"7.7.7.210 meat10"
#"7.7.7.218 meat18"
#"7.7.7.216 meat16"
#"7.7.7.227 meat27"
#"7.7.7.217 meat17"
#"7.7.7.220 meat20"
#"7.7.7.209 meat09"
#"7.7.7.228 meat28"
#"7.7.7.222 meat22"
#"7.7.7.226 meat26"
#"7.7.7.219 meat19"
#"7.7.7.208 meat08"
#"7.7.7.221 meat-21"
#"7.7.7.203 meat03"
#"7.7.7.210 meat10"
#"10.10.10.218 meat18"
#"10.10.10.209 meat09"
"10.10.10.203 meat03"
#"10.10.10.216 meat16"
#"10.10.10.227 meat27"
#"10.10.10.217 meat17"
#"10.10.10.220 meat20"
#"10.10.10.209 meat09"
#"10.10.10.210 meat10"
#"10.10.10.228 meat28"
#"10.10.10.222 meat22"
#"10.10.10.226 meat26"
#"10.10.10.219 meat19"
#"10.10.10.208 meat08"
#"10.10.10.221 meat-21"
#"10.10.10.203 meat03"
#"172.16.0.24 meat24"
#"172.16.0.14 meat14"
#"172.16.0.11 meat11"
#"10.10.10.224 meat24"
#"10.10.10.214 meat14"
#"10.10.10.211 meat11"

)

echo "=== Installing SSH keys with auto-password ==="

for entry in "${hosts[@]}"; do
    ip=$(echo $entry | awk '{print $1}')
    user=$(echo $entry | awk '{print $2}')

    echo "----- $ip ($user) -----"

    # Remove old fingerprint
    ssh-keygen -R "$ip" >/dev/null 2>&1

    # Push SSH key
    sshpass -p "$PASSWORD" ssh-copy-id \
        -o StrictHostKeyChecking=no \
        "$user@$ip"

    # Test login
    sshpass -p "$PASSWORD" ssh \
        -o StrictHostKeyChecking=no \
        "$user@$ip" "echo OK" 2>/dev/null

    if [ $? -eq 0 ]; then
        echo "[OK] Successfully installed key on $ip"
    else
        echo "[FAIL] Could not log into $ip"
    fi

    echo ""
done

echo "=== Done ==="
