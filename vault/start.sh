#!/bin/bash


currentip=`ifconfig eth0 | grep "inet addr" | cut -d ':' -f 2 | cut -d ' ' -f 1`

# wait for all running
while [ 1 ]
do
  sleep 1
  echo "... waiting for  $i"
  count=0
  for (( c=0; c<$TOTAL_NODES; c++ ))
  do
    node_ip=$(ping -c1 vault$c | sed -nE 's/^PING[^(]+\(([^)]+)\).*/\1/p')
    if [ node_ip != "" ]; then
        ((count=count+1))
    fi
  done
  if [ $count == $TOTAL_NODES ]; then
      echo "all running"
      break
  fi
done

RETRY_JOIN=""
for (( c=0; c<$TOTAL_NODES; c++ ))
do
  if [ "${NODE_NAME}" != "vault$c" ]; then
    #node_ip=$(ping -c1 vault$c | sed -nE 's/^PING[^(]+\(([^)]+)\).*/\1/p')
    RETRY_JOIN+="
      retry_join {
          leader_api_addr = \"http://vault$c:8200\"
      }
    "
  fi
done

# first node, or reboot first node after cluster creation
if [ "$NODE_NAME" != "vault0" ] || [ -f "/etc/vault-token/vault-unseal-token" ]; then
cat << EOF > /vault/config/config.hcl
listener "tcp" {
  address = "0.0.0.0:8200"
  tls_disable = 1
}
ui = true
storage "raft" {
  path    = "/vault/file/"
  node_id = "$NODE_NAME"
  $RETRY_JOIN
}
api_addr = "http://$currentip:8200"
cluster_addr = "http://$currentip:8201"
disable_mlock = true
EOF

else

cat << EOF > /vault/config/config.hcl
listener "tcp" {
  tls_disable = true
  address = "0.0.0.0:8200"
}
ui = true
storage "raft" {
  path    = "/vault/file/"
  node_id = "$NODE_NAME"
}
api_addr = "http://$currentip:8200"
cluster_addr = "http://$currentip:8201"
disable_mlock = true
EOF
fi

echo "[INFO] START VAULT $NODE_NAME"
vault server -config=/vault/config/config.hcl > /vault/logs/vault.log 2>&1 &
sleep 5
if [ "$NODE_NAME" == "vault0" ]; then
  echo "[INFO] INIT VAULT OPERATION"
  vault operator init -key-shares=1 -key-threshold=1 >> /vault/logs/operator.log
  VAULT_TOKEN=$(cat /vault/logs/operator.log | grep 'Initial Root Token:' | tail -n 1 | awk '{ print $NF }')
  VAULT_UNSEAL_TOKEN=$(cat /vault/logs/operator.log|grep "Unseal"|awk '{print $4}')
  echo "[INFO] VAULT ROOT TOKEN: $VAULT_TOKEN"
  echo "[INFO] VAULT UNSEAL TOKEN: $VAULT_UNSEAL_TOKEN"
  echo "[INFO] UNSEAL VAULT OPERATION $NODE_NAME"
  vault operator unseal $VAULT_UNSEAL_TOKEN
cat << EOF > /etc/vault-token/vault-root-token
$VAULT_TOKEN
EOF
cat << EOF > /etc/vault-token/vault-unseal-token
$VAULT_UNSEAL_TOKEN
EOF

else

  waitfor=60
  echo "==> Backend will wait $waitfor secconds for VAULT TOKENS"
  i=1
  while [ 1 ]
  do
    sleep 1
    echo "... waiting $i"
    i=$[$i+1]
    if [ -f /etc/vault-token/vault-root-token  ]; then
      echo "==> VAULT server available"
      break
    fi
    if [ $waitfor -lt $i ]; then
      echo "==> VAULT server not available"
      break
    fi
  done

  sleep 10
  export VAULT_TOKEN=$(cat /etc/vault-token/vault-root-token)
  export VAULT_UNSEAL_TOKEN=$(cat /etc/vault-token/vault-unseal-token)
  echo "[INFO] UNSEAL VAULT OPERATION $NODE_NAME"
  vault operator unseal $VAULT_UNSEAL_TOKEN
fi

tail -f /vault/logs/vault.log
