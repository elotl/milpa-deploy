#!/bin/bash

set -e

usage() {
    cat <<EOF
Generate certificate suitable for use with a webhook service.

usage: ${0} [OPTIONS]

The following flags are required.

       --service          Service name of webhook.
       --namespace        Namespace where webhook service and secret reside.
       --secret           Secret name for CA certificate and server certificate/key pair.
       --no-wait-for-control-plane
                          Don't wait for control plane services.
       --valid-for-days   Specify number of days certificates will be valid for.
EOF
    exit 1
}

no_wait=false

while [[ $# -gt 0 ]]; do
    case ${1} in
        --service)
            service="$2"
            shift
            ;;
        --secret)
            secret="$2"
            shift
            ;;
        --namespace)
            namespace="$2"
            shift
            ;;
        --no-wait-for-control-plane)
            no_wait=true
            ;;
        --valid-for-days)
            valid_for_days="$2"
            shift
            ;;
        *)
            usage
            ;;
    esac
    shift
done

[ -z ${service} ] && service=kiyot-webhook-svc
[ -z ${secret} ] && secret=kiyot-webhook-certs
[ -z ${namespace} ] && namespace=kube-system && export namespace
[ -z ${valid_for_days} ] && valid_for_days=1825

if [ ! -x "$(command -v openssl)" ]; then
    echo "openssl not found"
    exit 1
fi

if [ -z "$HOME" ] && [ -z "$RANDFILE" ]; then
    export RANDFILE="/tmp/openssl.rand"
fi

completed=false
csrName=${service}.${namespace}
tmpdir=$(mktemp -d)
function cleanup {
    echo "cleaning up ${tmpdir}"
    rm -rf ${tmpdir}
    if $completed; then
        echo "SUCCESS"
    else
        echo "FAILURE: script did not complete, please check output for errors"
    fi
}
trap cleanup EXIT

echo "creating certs in tmpdir ${tmpdir}"

cat <<EOF >> ${tmpdir}/csr.conf
[req]
days = $valid_for_days
req_extensions = v3_req
distinguished_name = req_distinguished_name
[req_distinguished_name]
[ v3_req ]
basicConstraints = CA:FALSE
keyUsage = nonRepudiation, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names
[alt_names]
DNS.1 = ${service}
DNS.2 = ${service}.${namespace}
DNS.3 = ${service}.${namespace}.svc
EOF

openssl req -days $valid_for_days -nodes -x509 -newkey rsa:2048 -keyout ${tmpdir}/ca-key.pem -out ${tmpdir}/ca-cert.pem -subj "/C=US/ST=CA/L=San Francisco/O=Kubernetes/CN=Kiyot Webhook CA/emailAddress=info@elotl.co"

openssl genrsa -out ${tmpdir}/server-key.pem 2048
openssl req -days $valid_for_days -new -key ${tmpdir}/server-key.pem -subj "/CN=${service}.${namespace}.svc" -out ${tmpdir}/server.csr -config ${tmpdir}/csr.conf

openssl x509 -req -in ${tmpdir}/server.csr -CA ${tmpdir}/ca-cert.pem -CAkey ${tmpdir}/ca-key.pem -CAcreateserial -days $valid_for_days -out ${tmpdir}/server-cert.pem

# create the secret with CA cert and server cert/key
kubectl create secret generic ${secret} \
        --from-file=key.pem=${tmpdir}/server-key.pem \
        --from-file=cert.pem=${tmpdir}/server-cert.pem \
        --dry-run -o yaml |
    kubectl -n ${namespace} apply -f -

export CA_BUNDLE="$(openssl base64 -in ${tmpdir}/ca-cert.pem | tr -d '\n')"

manifest=$(cat <<'EOF'
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: kiyot-webhook
  namespace: ${namespace}
  labels:
    app: kiyot-webhook
spec:
  selector:
    matchLabels:
      app: kiyot-webhook
  replicas: 1
  template:
    metadata:
      labels:
        app: kiyot-webhook
    spec:
      containers:
        - name: kiyot-webhook
          image: elotl/kiyot-webhook
          imagePullPolicy: Always
          args:
            - -tlsCertFile=/etc/webhook/certs/cert.pem
            - -tlsKeyFile=/etc/webhook/certs/key.pem
            - -alsologtostderr
            - -v=4
            - 2>&1
          volumeMounts:
            - name: webhook-certs
              mountPath: /etc/webhook/certs
              readOnly: true
      volumes:
        - name: webhook-certs
          secret:
            secretName: kiyot-webhook-certs
---
apiVersion: admissionregistration.k8s.io/v1beta1
kind: MutatingWebhookConfiguration
metadata:
  name: kiyot-webhook-cfg
  labels:
    app: kiyot-webhook
webhooks:
  - name: kiyot-webhook.elotl.co
    clientConfig:
      service:
        name: kiyot-webhook-svc
        namespace: ${namespace}
        path: "/mutate"
      caBundle: "${CA_BUNDLE}"
    rules:
      - operations: [ "CREATE" ]
        apiGroups: [""]
        apiVersions: ["v1"]
        resources: ["pods"]
---
apiVersion: v1
kind: Service
metadata:
  name: kiyot-webhook-svc
  namespace: ${namespace}
  labels:
    app: kiyot-webhook
spec:
  ports:
  - port: 443
    targetPort: 443
  selector:
    app: kiyot-webhook
EOF
)

function wait_for_control_plane {
    local n=0
    while [[ $n -lt 300 ]]; do
        local found=0
        for systempod in kube-apiserver kube-controller-manager kube-scheduler; do
            kubectl get pods -n kube-system 2>/dev/null | tail -n+2 | awk '{print $1}' | grep "^$systempod" || break
            found=$((found+1))
        done
        n=$((n+1))
        if [[ $found -lt 3 ]]; then
            sleep 1
            continue
        fi
        break
    done
}

$no_wait || wait_for_control_plane

if command -v envsubst >/dev/null 2>&1; then
    echo "$manifest" | envsubst | kubectl apply -f -
else
    echo "$manifest" | sed -e "s|\${CA_BUNDLE}|${CA_BUNDLE}|g" | sed -e "s|\${namespace}|${namespace}|g" | kubectl apply -f -
fi

# Make sure any existing webhook pod is restarted.
kubectl -n "$namespace" delete pod -l app=kiyot-webhook || true

completed=true
