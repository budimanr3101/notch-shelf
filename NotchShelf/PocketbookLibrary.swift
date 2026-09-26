import AppKit
import SwiftUI

struct PocketbookV3Book: Identifiable, Equatable {
    let id: String
    let title: String
    let icon: String
    let searchPlaceholder: String
    let isBuiltin: Bool
}

enum PocketbookV3ContentType: String {
    case code
    case text
    case checklist
    case link
}

struct PocketbookV3Entry: Identifiable, Equatable {
    let id: String
    let bookID: String
    let category: String
    let title: String
    let subtitle: String
    let keywords: String
    let content: String
    let type: PocketbookV3ContentType
    let language: String?

    var code: Bool { return type == .code }
}

enum PocketbookBuiltinID {
    static let kubernetes = "kubernetes"
    static let aws = "aws"
    static let bash = "bash"
    static let kubectl = "kubectl"
}

enum PocketbookV3BuiltinLibrary {
    static let books: [PocketbookV3Book] = [
        PocketbookV3Book(id: PocketbookBuiltinID.kubernetes, title: "Kubernetes", icon: "shippingbox.fill", searchPlaceholder: "Search Kubernetes…", isBuiltin: true),
        PocketbookV3Book(id: PocketbookBuiltinID.aws, title: "AWS", icon: "cloud.fill", searchPlaceholder: "Search AWS…", isBuiltin: true),
        PocketbookV3Book(id: PocketbookBuiltinID.bash, title: "Bash", icon: "terminal.fill", searchPlaceholder: "Search Bash…", isBuiltin: true),
        PocketbookV3Book(id: PocketbookBuiltinID.kubectl, title: "kubectl", icon: "command", searchPlaceholder: "Search kubectl…", isBuiltin: true),
    ]

    private static func e(
        _ id: String,
        _ bookID: String,
        _ category: String,
        _ title: String,
        _ subtitle: String,
        _ keywords: String,
        _ content: String,
        type: PocketbookV3ContentType = .code,
        language: String? = nil
    ) -> PocketbookV3Entry {
        return PocketbookV3Entry(
            id: id, bookID: bookID, category: category, title: title,
            subtitle: subtitle, keywords: keywords, content: content,
            type: type, language: language
        )
    }

    static func entries(for bookID: String) -> [PocketbookV3Entry] {
        switch bookID {
        case PocketbookBuiltinID.kubernetes: return kubernetes
        case PocketbookBuiltinID.aws: return aws
        case PocketbookBuiltinID.bash: return bash
        case PocketbookBuiltinID.kubectl: return kubectl
        default: return []
        }
    }

    static let kubernetes: [PocketbookV3Entry] = [
        e("deployment", PocketbookBuiltinID.kubernetes, "YAML", "Deployment YAML", "Stateless workload boilerplate", "deployment apps replicas selector resources", """
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-app
spec:
  replicas: 3
  selector:
    matchLabels:
      app: my-app
  template:
    metadata:
      labels:
        app: my-app
    spec:
      containers:
        - name: my-app
          image: your-image:tag
          ports:
            - containerPort: 80
""", language: "yaml"),
        e("service", PocketbookBuiltinID.kubernetes, "YAML", "Service YAML", "ClusterIP service boilerplate", "service clusterip targetport", """
apiVersion: v1
kind: Service
metadata:
  name: my-app
spec:
  selector:
    app: my-app
  ports:
    - port: 80
      targetPort: 80
  type: ClusterIP
""", language: "yaml"),
        e("ingress", PocketbookBuiltinID.kubernetes, "YAML", "Ingress YAML", "networking.k8s.io/v1 boilerplate", "ingress host path backend", """
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: my-app
spec:
  rules:
    - host: app.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: my-app
                port:
                  number: 80
""", language: "yaml"),
        e("configmap", PocketbookBuiltinID.kubernetes, "YAML", "ConfigMap YAML", "Non-secret configuration", "configmap env configuration", """
apiVersion: v1
kind: ConfigMap
metadata:
  name: my-app-config
data:
  APP_ENV: production
  LOG_LEVEL: info
""", language: "yaml"),
        e("pdb", PocketbookBuiltinID.kubernetes, "YAML", "PodDisruptionBudget", "Protect voluntary availability", "pdb disruption drain minavailable", """
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: my-app-pdb
spec:
  minAvailable: 2
  selector:
    matchLabels:
      app: my-app
""", language: "yaml"),
        e("probes", PocketbookBuiltinID.kubernetes, "Concepts", "Probes", "Readiness, liveness and startup", "probe readiness liveness startup", """
readinessProbe controls whether a Pod receives Service traffic.

livenessProbe detects a stuck container and can trigger a restart.

startupProbe protects slow-starting apps until startup succeeds.
""", type: .text),
        e("requests-limits", PocketbookBuiltinID.kubernetes, "Concepts", "Requests vs Limits", "Scheduler reservation vs runtime ceiling", "cpu memory requests limits oom", """
Requests influence scheduling and represent expected resource needs.

Limits set runtime ceilings. CPU can be throttled and memory overages can cause OOMKilled.
""", type: .text),
        e("workloads", PocketbookBuiltinID.kubernetes, "Concepts", "Deployment vs StatefulSet", "Stateless vs stable identity", "deployment statefulset identity storage", """
Deployment: default for stateless, interchangeable Pods.

StatefulSet: stable Pod identity, ordered lifecycle, commonly paired with persistent volumes.
""", type: .text),
    ]

    static let kubectl: [PocketbookV3Entry] = [
        e("pods", PocketbookBuiltinID.kubectl, "Workloads", "Pods", "Get, wide, YAML and describe", "pods get describe wide", """
kubectl get pods
kubectl get pods -o wide
kubectl get pod <pod> -o yaml
kubectl describe pod <pod>
kubectl get pods -A
""", language: "bash"),
        e("logs", PocketbookBuiltinID.kubectl, "Debug", "Logs", "Follow, previous and container logs", "logs follow previous", """
kubectl logs <pod>
kubectl logs -f <pod>
kubectl logs <pod> -c <container>
kubectl logs <pod> --previous
""", language: "bash"),
        e("exec", PocketbookBuiltinID.kubectl, "Debug", "Exec", "Interactive shell and one-shot command", "exec shell bash sh", """
kubectl exec -it <pod> -- /bin/sh
kubectl exec -it <pod> -- /bin/bash
kubectl exec <pod> -- env
""", language: "bash"),
        e("events", PocketbookBuiltinID.kubectl, "Debug", "Events", "Inspect recent cluster events", "events warning troubleshoot", """
kubectl get events --sort-by=.lastTimestamp
kubectl get events -A --sort-by=.lastTimestamp
kubectl get events --field-selector type=Warning
""", language: "bash"),
        e("rollout", PocketbookBuiltinID.kubectl, "Workloads", "Deployment Rollout", "Status, restart, history and undo", "rollout restart undo history", """
kubectl rollout status deployment/<name>
kubectl rollout restart deployment/<name>
kubectl rollout history deployment/<name>
kubectl rollout undo deployment/<name>
""", language: "bash"),
        e("context", PocketbookBuiltinID.kubectl, "Context", "Context & Namespace", "Switch kubeconfig context and namespace", "context namespace config", """
kubectl config current-context
kubectl config get-contexts
kubectl config use-context <context>
kubectl config set-context --current --namespace=<namespace>
""", language: "bash"),
        e("port-forward", PocketbookBuiltinID.kubectl, "Network", "Port Forward", "Expose a Pod or Service locally", "port forward localhost", """
kubectl port-forward pod/<pod> 8080:80
kubectl port-forward service/<service> 8080:80
""", language: "bash"),
        e("apply", PocketbookBuiltinID.kubectl, "Apply", "Diff, Dry Run & Apply", "Safer manifest workflow", "apply diff dry-run server", """
kubectl diff -f manifest.yaml
kubectl apply --dry-run=server -f manifest.yaml
kubectl apply -f manifest.yaml
""", language: "bash"),
        e("nodes", PocketbookBuiltinID.kubectl, "Cluster", "Nodes", "Capacity, labels and taints", "nodes labels taints", """
kubectl get nodes -o wide
kubectl describe node <node>
kubectl get nodes --show-labels
kubectl top nodes
""", language: "bash"),
    ]

    static let aws: [PocketbookV3Entry] = [
        e("identity", PocketbookBuiltinID.aws, "CLI", "Who am I?", "Verify account and principal", "sts identity account arn caller", """
aws sts get-caller-identity
aws sts get-caller-identity --profile <profile>
""", language: "bash"),
        e("profiles", PocketbookBuiltinID.aws, "CLI", "Profiles & Region", "Inspect active AWS CLI configuration", "profile region configure", """
aws configure list
aws configure list-profiles
aws configure get region --profile <profile>
""", language: "bash"),
        e("sso", PocketbookBuiltinID.aws, "CLI", "AWS SSO", "Login and verify identity", "sso login profile", """
aws sso login --profile <profile>
aws sts get-caller-identity --profile <profile>
""", language: "bash"),
        e("ec2", PocketbookBuiltinID.aws, "EC2", "EC2 Instances", "List instances with useful fields", "ec2 instances state ip", """
aws ec2 describe-instances \
  --query 'Reservations[].Instances[].{ID:InstanceId,State:State.Name,IP:PrivateIpAddress}' \
  --output table
""", language: "bash"),
        e("s3", PocketbookBuiltinID.aws, "S3", "S3 Quick Commands", "List, copy and sync", "s3 ls cp sync bucket", """
aws s3 ls
aws s3 ls s3://<bucket>/<prefix>/
aws s3 cp <file> s3://<bucket>/<key>
aws s3 sync <dir>/ s3://<bucket>/<prefix>/ --dryrun
""", language: "bash"),
        e("eks-kubeconfig", PocketbookBuiltinID.aws, "EKS", "EKS Update Kubeconfig", "Connect kubectl to an EKS cluster", "eks kubeconfig kubectl profile", """
aws eks update-kubeconfig \
  --name <cluster> \
  --region <region> \
  --profile <profile>
""", language: "bash"),
        e("ssm", PocketbookBuiltinID.aws, "SSM", "Session Manager", "Open a shell without SSH", "ssm session instance", """
aws ssm start-session --target <instance-id>
aws ssm describe-instance-information --output table
""", language: "bash"),
        e("logs", PocketbookBuiltinID.aws, "CloudWatch", "CloudWatch Logs", "Tail a log group from CLI", "logs tail follow cloudwatch", """
aws logs tail <log-group> --since 15m
aws logs tail <log-group> --since 15m --follow
""", language: "bash"),
        e("iam", PocketbookBuiltinID.aws, "Concepts", "IAM Role vs Policy", "Identity and permissions", "iam role policy trust permissions", """
IAM Role is an identity that can be assumed and has a trust policy.

IAM Policy is a permissions document describing allowed or denied actions on resources.
""", type: .text),
    ]

    static let bash: [PocketbookV3Entry] = [
        e("find", PocketbookBuiltinID.bash, "Files", "Find Files", "Search by name, type and age", "find files name mtime", """
find . -type f -name '*.log'
find . -type f -mtime -1
find . -type d -name 'node_modules'
""", language: "bash"),
        e("grep", PocketbookBuiltinID.bash, "Text", "grep", "Recursive and contextual search", "grep recursive context regex", """
grep -R "pattern" .
grep -Rni "pattern" .
grep -C 3 "pattern" file.log
""", language: "bash"),
        e("disk", PocketbookBuiltinID.bash, "System", "Disk Usage", "Find large directories and files", "disk df du size", """
df -h
du -sh ./* | sort -h
du -ah . | sort -h | tail -20
""", language: "bash"),
        e("process", PocketbookBuiltinID.bash, "Process", "Processes", "Find and inspect running processes", "process ps pgrep kill", """
ps aux | grep <name>
pgrep -fl <name>
kill -TERM <pid>
""", language: "bash"),
        e("ports", PocketbookBuiltinID.bash, "Network", "Listening Ports", "See which process owns a port", "port lsof listen", """
lsof -nP -iTCP -sTCP:LISTEN
lsof -nP -iTCP:<port> -sTCP:LISTEN
""", language: "bash"),
        e("curl", PocketbookBuiltinID.bash, "Network", "curl", "Headers and quick HTTP checks", "curl http headers status", """
curl -I https://example.com
curl -sS https://example.com
curl -o /dev/null -sS -w '%{http_code} %{time_total}\n' https://example.com
""", language: "bash"),
        e("redirect", PocketbookBuiltinID.bash, "Shell", "Redirection", "stdout, stderr and pipes", "redirect stdout stderr pipe tee", """
command > output.txt
command >> output.txt
command 2> error.txt
command > output.txt 2>&1
command | tee output.txt
""", language: "bash"),
        e("strict-mode", PocketbookBuiltinID.bash, "Concepts", "Safer Script Header", "Fail earlier in automation scripts", "set pipefail nounset errexit", """
#!/usr/bin/env bash
set -euo pipefail
""", language: "bash"),
    ]
}
