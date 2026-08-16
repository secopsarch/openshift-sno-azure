# nginx demo

A minimal application that proves end-to-end connectivity through
OpenShift: workload → service → ingress → DNS → internet.

---

## What this deploys

- `Deployment` — 1 replica of `nginx:1.27-alpine`
- `Service` — ClusterIP service on port 80
- `Route` — OpenShift Route that creates a DNS entry under `*.apps.*`

After deploying, the nginx default page is accessible at:

```
http://nginx-demo.apps.sno.ocp.lab1.arunkube.org
```

(Replace with your actual cluster domain.)

---

## Prerequisites

Cluster must be healthy:
```bash
oc get nodes           # 1 node, Ready
oc get co | grep -v "True.*False.*False"  # All operators healthy
```

---

## Deploy

```bash
# Create project
oc new-project sno-demo

# Apply all manifests
oc apply -f deployment.yaml
oc apply -f service.yaml
oc apply -f route.yaml

# Wait for pod to start
oc rollout status deployment/nginx-demo -n sno-demo

# Verify
oc get pods -n sno-demo
oc get svc -n sno-demo
oc get route -n sno-demo
```

---

## Test external access

```bash
# Get the route hostname
ROUTE_HOST=$(oc get route nginx-demo -n sno-demo -o jsonpath='{.spec.host}')
echo "Route: http://${ROUTE_HOST}"

# Test via curl
curl -I "http://${ROUTE_HOST}"
# Expected: HTTP/1.1 200 OK

# Full response body
curl "http://${ROUTE_HOST}" | head -20
# Expected: nginx welcome page HTML
```

---

## What success looks like

```
$ oc get pods -n sno-demo
NAME                          READY   STATUS    RESTARTS   AGE
nginx-demo-6d5f7d5b9f-xkqnj   1/1     Running   0          2m

$ oc get svc -n sno-demo
NAME         TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)   AGE
nginx-demo   ClusterIP   172.30.45.123   <none>        80/TCP    2m

$ oc get route -n sno-demo
NAME         HOST/PORT                                       PATH   SERVICES     PORT   TERMINATION   WILDCARD
nginx-demo   nginx-demo.apps.sno.ocp.lab1.arunkube.org             nginx-demo   http                 None

$ curl -I http://nginx-demo.apps.sno.ocp.lab1.arunkube.org
HTTP/1.1 200 OK
Server: nginx/1.27.x
...
```

---

## Remove

```bash
oc delete project sno-demo
```

This removes the namespace and all resources within it (Deployment, Service, Route).
