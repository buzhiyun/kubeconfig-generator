#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_DIR="${SCRIPT_DIR}/templates"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

usage() {
    cat <<EOF
Usage: $(basename "$0") -u <username> [-n <namespace>] {-r <role> | -c <yaml>} [-o <output>] [-d <duration>]
       $(basename "$0") -u <username> --clean [-n <namespace>]

Generate a kubeconfig file with RBAC for a new k8s user (ServiceAccount).

Required:
  -u  Username (ServiceAccount name)

RBAC (choose one):
  -r  Preset role: readonly | developer | operator | admin
  -c  Custom RBAC YAML file path

Options:
  -n  Namespace scope (omit for cluster-wide permissions)
  -o  Output kubeconfig file path (default: <username>-kubeconfig)
  -d  Token duration, e.g. 1h, 24h, 720h (default: 8760h / 1 year)

Cleanup:
  --clean  Remove ServiceAccount and RBAC resources for the given user

Examples:
  # Namespace-scoped readonly user
  $(basename "$0") -u alice -n default -r readonly

  # Cluster-wide operator
  $(basename "$0") -u bob -r operator

  # Custom RBAC with long-lived token
  $(basename "$0") -u cicd -n cicd-ns -c custom-role.yaml -d 8760h

  # Cleanup
  $(basename "$0") -u alice -n default --clean
EOF
    exit 0
}

# ── Defaults ──
USERNAME=""
NAMESPACE=""
ROLE=""
CUSTOM_YAML=""
OUTPUT=""
DURATION="8760h"
CLEAN=false

# ── Parse args ──
while [[ $# -gt 0 ]]; do
    case "$1" in
        -u) USERNAME="$2"; shift 2 ;;
        -n) NAMESPACE="$2"; shift 2 ;;
        -r) ROLE="$2"; shift 2 ;;
        -c) CUSTOM_YAML="$2"; shift 2 ;;
        -o) OUTPUT="$2"; shift 2 ;;
        -d) DURATION="$2"; shift 2 ;;
        --clean) CLEAN=true; shift ;;
        -h|--help) usage ;;
        *) error "Unknown option: $1" ;;
    esac
done

# ── Validate ──
[[ -z "${USERNAME}" ]] && error "Username (-u) is required"
command -v kubectl &>/dev/null || error "kubectl not found in PATH"

if [[ "${CLEAN}" == true ]]; then
    # ── Cleanup mode ──
    NS_FLAG=""
    if [[ -n "${NAMESPACE}" ]]; then
        NS_FLAG="-n ${NAMESPACE}"
    fi

    info "Cleaning up resources for user '${USERNAME}'..."

    # Delete ServiceAccount
    if kubectl ${NS_FLAG} get serviceaccount "${USERNAME}" &>/dev/null; then
        kubectl ${NS_FLAG} delete serviceaccount "${USERNAME}" && info "Deleted ServiceAccount: ${USERNAME}"
    else
        warn "ServiceAccount '${USERNAME}' not found"
    fi

    # Delete associated secret (legacy token secrets)
    kubectl ${NS_FLAG} get secret -o name 2>/dev/null | { grep "${USERNAME}" || true; } | while read -r secret; do
        kubectl ${NS_FLAG} delete "${secret}" && info "Deleted ${secret}"
    done

    # Delete RoleBindings
    for binding_type in rolebinding clusterrolebinding; do
        kubectl get "${binding_type}" -o name 2>/dev/null | { grep "${USERNAME}" || true; } | while read -r binding; do
            kubectl delete "${binding}" && info "Deleted ${binding}"
        done
    done

    # Delete Roles
    for role_type in role clusterrole; do
        kubectl get "${role_type}" -o name 2>/dev/null | { grep "${USERNAME}" || true; } | while read -r binding; do
            kubectl delete "${binding}" && info "Deleted ${binding}"
        done
    done

    info "Cleanup complete."
    exit 0
fi

# RBAC parameter validation
if [[ -z "${ROLE}" && -z "${CUSTOM_YAML}" ]]; then
    error "Either -r <role> or -c <custom-yaml> is required"
fi
if [[ -n "${ROLE}" && -n "${CUSTOM_YAML}" ]]; then
    error "Cannot use both -r and -c, choose one"
fi
if [[ -n "${ROLE}" ]]; then
    [[ ! -f "${TEMPLATE_DIR}/${ROLE}.yaml" ]] && error "Unknown role '${ROLE}'. Available: $(ls "${TEMPLATE_DIR}" | sed 's/\.yaml$//' | tr '\n' ' ')"
fi
if [[ -n "${CUSTOM_YAML}" ]]; then
    [[ ! -f "${CUSTOM_YAML}" ]] && error "Custom YAML file not found: ${CUSTOM_YAML}"
fi

OUTPUT="${OUTPUT:-${USERNAME}-kubeconfig}"
SA_NAMESPACE="${NAMESPACE:-default}"

# ── Determine scope ──
if [[ -n "${NAMESPACE}" ]]; then
    ROLE_KIND="Role"
    BINDING_KIND="RoleBinding"
    NAMESPACE_BLOCK="namespace: ${NAMESPACE}"
    NS_FLAG="-n ${NAMESPACE}"
    SCOPE_DESC="namespace '${NAMESPACE}'"
else
    ROLE_KIND="ClusterRole"
    BINDING_KIND="ClusterRoleBinding"
    NAMESPACE_BLOCK=""
    NS_FLAG=""
    SCOPE_DESC="cluster-wide"
fi

info "Generating kubeconfig for '${USERNAME}' (${SCOPE_DESC})"

# ── 1. Create ServiceAccount ──
if kubectl ${NS_FLAG} get serviceaccount "${USERNAME}" &>/dev/null; then
    warn "ServiceAccount '${USERNAME}' already exists, reusing..."
else
    kubectl ${NS_FLAG} create serviceaccount "${USERNAME}"
    info "Created ServiceAccount: ${USERNAME}"
fi

# ── 2. Configure RBAC ──
if [[ -n "${ROLE}" ]]; then
    info "Applying preset role: ${ROLE}"
    TEMPLATE_CONTENT=$(cat "${TEMPLATE_DIR}/${ROLE}.yaml")

    # Replace placeholders
    RENDERED=$(echo "${TEMPLATE_CONTENT}" \
        | sed "s|{{ROLE_KIND}}|${ROLE_KIND}|g" \
        | sed "s|{{BINDING_KIND}}|${BINDING_KIND}|g" \
        | sed "s|{{NAMESPACE_BLOCK}}|${NAMESPACE_BLOCK}|g" \
        | sed "s|{{USERNAME}}|${USERNAME}|g" \
        | sed "s|{{SA_NAMESPACE}}|${SA_NAMESPACE}|g" \
    )

    echo "${RENDERED}" | kubectl apply -f -
    info "Applied RBAC: ${ROLE} (${SCOPE_DESC})"
elif [[ -n "${CUSTOM_YAML}" ]]; then
    info "Applying custom RBAC from: ${CUSTOM_YAML}"
    kubectl apply -f "${CUSTOM_YAML}"
    info "Applied custom RBAC"
fi

# ── 3. Get ServiceAccount token ──
info "Generating token (duration: ${DURATION})..."
TOKEN=""
if kubectl create token --help 2>/dev/null | grep -q "duration"; then
    TOKEN=$(kubectl ${NS_FLAG} create token "${USERNAME}" --duration="${DURATION}")
fi

# Fallback: create a long-lived secret for the SA (for k8s < 1.24 or if token command fails)
if [[ -z "${TOKEN}" ]]; then
    SECRET_NAME="${USERNAME}-token"
    if ! kubectl ${NS_FLAG} get secret "${SECRET_NAME}" &>/dev/null; then
        cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: ${SECRET_NAME}
  namespace: ${SA_NAMESPACE}
  annotations:
    kubernetes.io/service-account.name: ${USERNAME}
type: kubernetes.io/service-account-token
EOF
        # Wait for token to be populated
        info "Waiting for token secret to be populated..."
        for i in $(seq 1 30); do
            TOKEN=$(kubectl ${NS_FLAG} get secret "${SECRET_NAME}" -o jsonpath='{.data.token}' 2>/dev/null | base64 -d 2>/dev/null || true)
            [[ -n "${TOKEN}" ]] && break
            sleep 1
        done
    else
        TOKEN=$(kubectl ${NS_FLAG} get secret "${SECRET_NAME}" -o jsonpath='{.data.token}' | base64 -d)
    fi
fi

[[ -z "${TOKEN}" ]] && error "Failed to obtain token for ServiceAccount '${USERNAME}'"
info "Token generated successfully"

# ── 4. Build kubeconfig ──
CURRENT_CONTEXT=$(kubectl config current-context)
CLUSTER_NAME=$(kubectl config view --minify -o jsonpath='{.clusters[0].name}')
SERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
CA_DATA=$(kubectl config view --minify --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')

[[ -z "${SERVER}" ]] && error "Failed to get API server address"
[[ -z "${CA_DATA}" ]] && error "Failed to get cluster CA certificate"

CONTEXT_NAME="${USERNAME}@${CLUSTER_NAME}"

cat > "${OUTPUT}" <<EOF
apiVersion: v1
kind: Config
clusters:
- cluster:
    certificate-authority-data: ${CA_DATA}
    server: ${SERVER}
  name: ${CLUSTER_NAME}
contexts:
- context:
    cluster: ${CLUSTER_NAME}
    namespace: ${SA_NAMESPACE}
    user: ${USERNAME}
  name: ${CONTEXT_NAME}
current-context: ${CONTEXT_NAME}
users:
- name: ${USERNAME}
  user:
    token: ${TOKEN}
EOF

chmod 600 "${OUTPUT}"

echo ""
info "Kubeconfig generated: ${OUTPUT}"
info "User: ${USERNAME} | Scope: ${SCOPE_DESC} | Role: ${ROLE:-custom}"
echo ""
echo "  export KUBECONFIG=${OUTPUT}"
echo "  kubectl get pods"
echo ""
echo "To clean up this user's resources later:"
echo "  $(basename "$0") -u ${USERNAME} ${NAMESPACE:+-n ${NAMESPACE}} --clean"
