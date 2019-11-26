#!/bin/bash

set -e

export CA_BUNDLE=$(kubectl get secret -n openshift-service-ca signing-key -ojsonpath='{.data.tls\.crt}')

manifest=$(cat <<'EOF'
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: kiyot-webhook
  namespace: kube-system
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
            - -tlsCertFile=/etc/webhook/certs/tls.crt
            - -tlsKeyFile=/etc/webhook/certs/tls.key
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
            secretName: kiyot-webhook-secret
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
        namespace: kube-system
        path: "/mutate"
      caBundle: ${CA_BUNDLE}
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
  namespace: kube-system
  labels:
    app: kiyot-webhook
  annotations:
    service.beta.openshift.io/serving-cert-secret-name: kiyot-webhook-secret
spec:
  ports:
  - port: 443
    targetPort: 443
  selector:
    app: kiyot-webhook
EOF
)
if command -v envsubst >/dev/null 2>&1; then
    echo "$manifest" | envsubst | kubectl apply -f -
else
    echo "$manifest" | sed -e "s|\${CA_BUNDLE}|${CA_BUNDLE}|g" | kubectl apply -f -
fi
