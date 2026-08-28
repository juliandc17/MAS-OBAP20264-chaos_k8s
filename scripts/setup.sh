#!/bin/bash
# ════════════════════════════════════════════════════════════════
#
# Instala y configura:
#   1. GKE cluster (si no existe)
#   2. Stack OTel (servicios + monitoring)
#   3. Chaos Mesh (CNCF)
#   4. LitmusChaos (CNCF)
#   5. Experimentos de chaos
#
# Uso:
#   chmod +x scripts/setup.sh
#   ./scripts/setup.sh           # instalación completa
#   ./scripts/setup.sh --chaos   # solo ejecutar experimentos
#   ./scripts/setup.sh --status  # ver estado del cluster
# ════════════════════════════════════════════════════════════════

set -euo pipefail

# ── Colores para output ────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

GCP_PROJECT="mas-obap20264-otellabs"
GCP_REGION="us-east1"
CLUSTER_NAME="otel-lab"
NAMESPACE="otel-lab"

log()  { echo -e "${BLUE}[$(date +%H:%M:%S)]${NC} $1"; }
ok()   { echo -e "${GREEN}✅ $1${NC}"; }
warn() { echo -e "${YELLOW}⚠️  $1${NC}"; }
err()  { echo -e "${RED}❌ $1${NC}"; exit 1; }

 # ════════════════════════════════════════════════════════════════
 # PASO 1 — Verificar prerequisitos
 # ════════════════════════════════════════════════════════════════
 check_prerequisites() {
   log "Verificando prerequisitos..."
   for tool in gcloud kubectl helm docker; do
     if ! command -v $tool &>/dev/null; then
       err "$tool no está instalado. Instálalo antes de continuar."
     fi
     ok "$tool disponible"
   done

   # Verificar autenticación GCP
   if ! gcloud auth list --filter=status:ACTIVE --format="value(account)" | grep -q "@"; then
     err "No hay cuenta activa de GCP. Ejecuta: gcloud auth login"
   fi
   ok "Autenticado en GCP: $(gcloud auth list --filter=status:ACTIVE --format='value(account)')"
 }

# ════════════════════════════════════════════════════════════════
# PASO 2 — Crear o conectar al cluster GKE
# ════════════════════════════════════════════════════════════════
setup_gke_cluster() {
  log "Verificando cluster GKE..."
  gcloud config set project $GCP_PROJECT

  if gcloud container clusters describe $CLUSTER_NAME \
     --region=$GCP_REGION &>/dev/null 2>&1; then
    warn "Cluster $CLUSTER_NAME ya existe — conectando..."
  else
    log "Creando cluster GKE $CLUSTER_NAME..."
    gcloud container clusters create $CLUSTER_NAME \
      --region=$GCP_REGION \
      --num-nodes=2 \
      --machine-type=e2-medium \
      --enable-autoscaling \
      --min-nodes=1 \
      --max-nodes=3 \
      --disk-size=30GB \
      --enable-network-policy \
      --workload-pool="${GCP_PROJECT}.svc.id.goog" \
      --labels="env=lab,app=otel-chaos"
    ok "Cluster creado"
  fi

  # Obtener credenciales
  gcloud container clusters get-credentials $CLUSTER_NAME \
    --region=$GCP_REGION --project=$GCP_PROJECT
  ok "kubectl configurado para $CLUSTER_NAME"
}

# ════════════════════════════════════════════════════════════════
# PASO 3 — Build y push de las imágenes a GCR
# ════════════════════════════════════════════════════════════════
build_and_push_images() {
  log "Construyendo y publicando imágenes Docker..."

  gcloud auth configure-docker gcr.io --quiet

  for svc in service-a service-b data-service; do
    if [ -d "$svc" ]; then
      log "Building $svc..."
      docker build -t gcr.io/$GCP_PROJECT/$svc:1.0.0 $svc/
      docker push gcr.io/$GCP_PROJECT/$svc:1.0.0
      ok "$svc publicado en GCR"
    else
      warn "Directorio $svc no encontrado — asumiendo imagen ya existe en GCR"
    fi
  done
}

# ════════════════════════════════════════════════════════════════
# PASO 4 — Desplegar el stack OTel base
# ════════════════════════════════════════════════════════════════
deploy_otel_stack() {
  log "Desplegando stack OTel en GKE..."

  # Namespace y RBAC
  kubectl apply -fbase/00-namespace-rbac.yaml
  ok "Namespace y RBAC aplicados"

  # ConfigMaps
  kubectl apply -fbase/01-configmaps.yaml
  ok "ConfigMaps aplicados"

  # Deployments
  kubectl apply -fbase/02-deployments.yaml
  ok "Deployments aplicados"

  # Esperar a que los pods estén listos
  log "Esperando pods del stack OTel (timeout: 5min)..."
  kubectl wait --for=condition=ready pod \
    -l "chaos.exclude!=true" \
    -n $NAMESPACE \
    --timeout=300s
  ok "Stack OTel listo"

  # Mostrar servicios externos
  log "Servicios externos (IPs pueden tardar 2-3 min en asignarse):"
  kubectl get svc -n $NAMESPACE | grep LoadBalancer
}

# ════════════════════════════════════════════════════════════════
# PASO 5 — Instalar Chaos Mesh (CNCF)
# ════════════════════════════════════════════════════════════════
install_chaos_mesh() {
  log "Instalando Chaos Mesh..."

  # Agregar repo de Helm
  helm repo add chaos-mesh https://charts.chaos-mesh.org
  helm repo update

  # Instalar en namespace chaos-mesh
  # GKE usa containerd como container runtime desde K8s 1.24
  if helm status chaos-mesh -n chaos-mesh &>/dev/null 2>&1; then
    warn "Chaos Mesh ya está instalado — actualizando..."
    helm upgrade chaos-mesh chaos-mesh/chaos-mesh \
      --namespace chaos-mesh \
      --set chaosDaemon.runtime=containerd \
      --set chaosDaemon.socketPath=/run/containerd/containerd.sock \
      --set dashboard.securityMode=false \
      --set features.httpChaos.enabled=true
  else
    helm install chaos-mesh chaos-mesh/chaos-mesh \
      --namespace chaos-mesh \
      --create-namespace \
      --set chaosDaemon.runtime=containerd \
      --set chaosDaemon.socketPath=/run/containerd/containerd.sock \
      --set dashboard.securityMode=false \
      --set features.httpChaos.enabled=true \
      --wait --timeout=5m
  fi

  ok "Chaos Mesh instalado"

  # Verificar CRDs
  log "CRDs de Chaos Mesh instalados:"
  kubectl get crd | grep chaos-mesh.org | awk '{print "  " $1}'

  # Mostrar dashboard de Chaos Mesh
  echo ""
  echo -e "${CYAN}Para acceder al dashboard de Chaos Mesh:${NC}"
  echo "  kubectl port-forward -n chaos-mesh svc/chaos-dashboard 2333:2333 &"
  echo "  Abrir: http://localhost:2333"
}

# ════════════════════════════════════════════════════════════════
# PASO 6 — Instalar LitmusChaos (CNCF)
# ════════════════════════════════════════════════════════════════
install_litmus_chaos() {
  log "Instalando LitmusChaos operator..."

  # Instalar el operador de LitmusChaos 3.x
  LITMUS_VERSION="3.8.0"
  kubectl apply -f \
    "https://litmuschaos.github.io/litmus/litmus-operator-v${LITMUS_VERSION}.yaml" \
    --server-side 2>/dev/null || \
  kubectl apply -f \
    "https://litmuschaos.github.io/litmus/litmus-operator-v${LITMUS_VERSION}.yaml"

  ok "Operador de LitmusChaos aplicado"

  # Esperar al operador
  log "Esperando al operador de LitmusChaos (timeout: 3min)..."
  kubectl wait --for=condition=ready pod \
    -l "app.kubernetes.io/name=litmus" \
    -n litmus \
    --timeout=180s || warn "Timeout esperando LitmusChaos — verificar manualmente"

  # Instalar los ChaosExperiments en el namespace otel-lab
  log "Instalando ChaosExperiments de red en namespace otel-lab..."

  # Pod Network Latency
  kubectl apply -f \
    "https://hub.litmuschaos.io/api/chaos/3.x.x?file=charts/generic/pod-network-latency/experiment.yaml" \
    -n $NAMESPACE || \
  warn "No se pudo descargar pod-network-latency — verificar conectividad"

  # Pod Delete
  kubectl apply -f \
    "https://hub.litmuschaos.io/api/chaos/3.x.x?file=charts/generic/pod-delete/experiment.yaml" \
    -n $NAMESPACE || \
  warn "No se pudo descargar pod-delete — verificar conectividad"

  ok "LitmusChaos instalado"

  # Verificar CRDs
  log "CRDs de LitmusChaos instalados:"
  kubectl get crd | grep litmuschaos.io | awk '{print "  " $1}'

  echo ""
  echo -e "${CYAN}Para acceder al ChaosCenter de LitmusChaos:${NC}"
  echo "  kubectl port-forward -n litmus svc/litmus-frontend-service 9091:9091 &"
  echo "  Abrir: http://localhost:9091"
  echo "  Usuario: admin / Password: litmus"
}
# install_litmus_chaos() {
#   log "Instalando LitmusChaos completo (operador + ChaosCenter)..."

#   # Instalar via Helm — incluye operador + ChaosCenter + MongoDB
#   helm repo add litmuschaos https://litmuschaos.github.io/litmus-helm/
#   helm repo update

#   if helm status litmuschaos -n litmus &>/dev/null 2>&1; then
#     warn "LitmusChaos ya está instalado — actualizando..."
#     helm upgrade litmuschaos litmuschaos/litmus \
#       --namespace litmus \
#       --set portal.frontend.service.type=ClusterIP \
#       --wait --timeout=5m
#   else
#     helm install litmuschaos litmuschaos/litmus \
#       --namespace litmus \
#       --create-namespace \
#       --set portal.frontend.service.type=ClusterIP \
#       --wait --timeout=5m
#   fi

#   ok "LitmusChaos instalado"

#   # Esperar pods listos
#   log "Esperando pods de LitmusChaos (timeout: 5min)..."
#   kubectl wait --for=condition=ready pod \
#     -l "app.kubernetes.io/instance=litmuschaos" \
#     -n litmus \
#     --timeout=300s || warn "Timeout — verificar con: kubectl get pods -n litmus"

#   # Instalar ChaosExperiments en namespace otel-lab
#   log "Instalando ChaosExperiments en namespace otel-lab..."
#   kubectl apply -f \
#     "https://hub.litmuschaos.io/api/chaos/3.x.x?file=charts/generic/pod-network-latency/experiment.yaml" \
#     -n otel-lab 2>/dev/null || \
#   warn "No se pudo descargar pod-network-latency"

#   kubectl apply -f \
#     "https://hub.litmuschaos.io/api/chaos/3.x.x?file=charts/generic/pod-delete/experiment.yaml" \
#     -n otel-lab 2>/dev/null || \
#   warn "No se pudo descargar pod-delete"

#   ok "LitmusChaos completo instalado"

#   # Verificar services disponibles
#   log "Services de LitmusChaos:"
#   kubectl get svc -n litmus

#   echo ""
#   echo -e "${CYAN}Para acceder al ChaosCenter:${NC}"
#   echo "  kubectl port-forward -n litmus svc/litmuschaos-frontend-service 9092:9091 &"
#   echo "  Abrir: http://localhost:9092"
#   echo "  Usuario: admin / Password: litmus"
# }

# ════════════════════════════════════════════════════════════════
# PASO 7 — Generar tráfico baseline antes del chaos
# ════════════════════════════════════════════════════════════════
generate_baseline_traffic() {
  log "Generando tráfico baseline (2 minutos)..."

  # Obtener IP de service-a
  SERVICE_A_IP=$(kubectl get svc service-a-svc -n $NAMESPACE \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")

  if [ -z "$SERVICE_A_IP" ]; then
    warn "IP de service-a no disponible aún. Usando port-forward..."
    kubectl port-forward -n $NAMESPACE svc/service-a-svc 8000:8000 &
    PF_PID=$!
    SERVICE_A_IP="localhost"
    sleep 3
  fi

  log "Enviando 200 requests a service-a ($SERVICE_A_IP:8000)..."
  for i in $(seq 1 200); do
    ORDER="ord-00$(( (i % 5) + 1 ))"
    curl -s "http://$SERVICE_A_IP:8000/order/$ORDER" > /dev/null &
    if (( i % 20 == 0 )); then
      wait
      echo -ne "\r  Requests enviados: $i/200"
    fi
  done
  wait
  echo ""
  ok "Tráfico baseline generado"

  # Matar port-forward si se creó
  [ -n "${PF_PID:-}" ] && kill $PF_PID 2>/dev/null || true
}

# ════════════════════════════════════════════════════════════════
# PASO 8 — Ejecutar experimentos de Chaos Mesh
# ════════════════════════════════════════════════════════════════
run_chaos_mesh_experiments() {
  log "Ejecutando Experimento 1 con Chaos Mesh (NetworkChaos)..."

  echo ""
  echo -e "${CYAN}════════════════════════════════════════${NC}"
  echo -e "${CYAN}  EXPERIMENTO 1: Latencia 200ms en service-b${NC}"
  echo -e "${CYAN}  Herramienta: Chaos Mesh NetworkChaos${NC}"
  echo -e "${CYAN}════════════════════════════════════════${NC}"
  echo ""

  CHAOS_START=$(date +%s)
  kubectl apply -f chaos-mesh/experiment-1-network-latency.yaml
  ok "NetworkChaos aplicado"

  log "Monitoreando detección de anomalía (objetivo: < 2 min)..."
  echo "  Verificando en Prometheus: histogram_quantile(0.99, ...) > 250ms"
  echo ""

  # Polling de Prometheus para medir MTTD
  PROMETHEUS_IP=$(kubectl get svc prometheus-svc -n $NAMESPACE \
    -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo "")

  if [ -z "$PROMETHEUS_IP" ]; then
    kubectl port-forward -n $NAMESPACE svc/prometheus-svc 9091:9090 &
    PF_PID=$!
    PROMETHEUS_URL="http://localhost:9091"
    sleep 3
  else
    PROMETHEUS_URL="http://$PROMETHEUS_IP:9090"
  fi

  DETECTED=false
  ELAPSED=0
  while [ $ELAPSED -lt 180 ]; do
    LATENCY=$(curl -s "$PROMETHEUS_URL/api/v1/query" \
      --data-urlencode 'query=histogram_quantile(0.99, rate(otelcol_http_request_duration_seconds_bucket{job="service-b"}[1m]))' \
      2>/dev/null | python3 -c "
import sys, json
try:
  d = json.load(sys.stdin)
  r = d['data']['result']
  print(r[0]['value'][1] if r else '0')
except: print('0')
" 2>/dev/null || echo "0")

    ELAPSED=$(( $(date +%s) - CHAOS_START ))
    echo -e "  [${ELAPSED}s] p99 latencia service-b: ${LATENCY}s"

    if python3 -c "exit(0 if float('${LATENCY:-0}') > 0.25 else 1)" 2>/dev/null; then
      MTTD=$ELAPSED
      DETECTED=true
      break
    fi
    sleep 10
  done

  echo ""
  if $DETECTED; then
    ok "ANOMALÍA DETECTADA — MTTD: ${MTTD}s"
    if [ $MTTD -lt 120 ]; then
      ok "OBJETIVO CUMPLIDO: MTTD (${MTTD}s) < 2 minutos"
    else
      warn "OBJETIVO NO CUMPLIDO: MTTD (${MTTD}s) > 2 minutos"
    fi
  else
    warn "ANOMALÍA NO DETECTADA en 3 minutos — revisar pipeline de alertas"
  fi

  # Esperar fin del chaos (5 min TTL)
  log "Esperando fin del chaos (TTL: 5 min desde T0)..."
  REMAINING=$(( 300 - ($(date +%s) - CHAOS_START) ))
  [ $REMAINING -gt 0 ] && sleep $REMAINING

  # Eliminar el chaos (rollback)
  kubectl delete -f chaos-mesh/experiment-1-network-latency.yaml 2>/dev/null || true
  ok "Chaos Mesh: NetworkChaos eliminado (rollback automático)"

  [ -n "${PF_PID:-}" ] && kill $PF_PID 2>/dev/null || true
}

# ════════════════════════════════════════════════════════════════
# PASO 9 — Ejecutar experimentos de LitmusChaos
# ════════════════════════════════════════════════════════════════
run_litmus_experiments() {
  log "Ejecutando Experimento 2 con LitmusChaos (Pod Delete)..."

  echo ""
  echo -e "${CYAN}════════════════════════════════════════${NC}"
  echo -e "${CYAN}  EXPERIMENTO 2: Pod Failure en data-service${NC}"
  echo -e "${CYAN}  Herramienta: LitmusChaos ChaosEngine${NC}"
  echo -e "${CYAN}════════════════════════════════════════${NC}"
  echo ""

  kubectl apply -f k8s/litmus/chaosengine-experiment-2.yaml
  ok "ChaosEngine aplicado"

  # Esperar resultado del ChaosEngine
  log "Esperando resultado del ChaosEngine (timeout: 5 min)..."
  TIMEOUT=300
  ELAPSED=0
  while [ $ELAPSED -lt $TIMEOUT ]; do
    VERDICT=$(kubectl get chaosresult \
      otel-lab-pod-failure-pod-delete \
      -n $NAMESPACE \
      -o jsonpath='{.status.experimentStatus.verdict}' 2>/dev/null || echo "")

    if [ -n "$VERDICT" ] && [ "$VERDICT" != "Awaited" ]; then
      break
    fi
    sleep 10
    ELAPSED=$(( ELAPSED + 10 ))
    echo -ne "\r  Esperando veredicto... ${ELAPSED}s/${TIMEOUT}s"
  done
  echo ""

  # Mostrar resultado
  echo ""
  log "Resultado del ChaosEngine LitmusChaos:"
  kubectl get chaosresult -n $NAMESPACE -o wide 2>/dev/null || \
    warn "ChaosResult no disponible aún"

  kubectl describe chaosresult \
    otel-lab-pod-failure-pod-delete \
    -n $NAMESPACE 2>/dev/null | grep -A 20 "Experiment Status" || true

  ok "Experimento 2 completado con LitmusChaos"
}

# ════════════════════════════════════════════════════════════════
# PASO 10 — Ver estado y resultados
# ════════════════════════════════════════════════════════════════
show_status() {
  echo ""
  echo -e "${CYAN}════════════════════════════════════════════════════════${NC}"
  echo -e "${CYAN}  ESTADO DEL LABORATORIO CHAOS ENGINEERING${NC}"
  echo -e "${CYAN}════════════════════════════════════════════════════════${NC}"

  echo ""
  log "Pods en namespace otel-lab:"
  kubectl get pods -n $NAMESPACE -o wide

  echo ""
  log "Estado de Chaos Mesh:"
  kubectl get networkchaos,httpchaos,podchaos,stresschaos -n $NAMESPACE 2>/dev/null || \
    echo "  No hay experiments activos de Chaos Mesh"

  echo ""
  log "Estado de LitmusChaos:"
  kubectl get chaosengine,chaosresult -n $NAMESPACE 2>/dev/null || \
    echo "  No hay experiments activos de LitmusChaos"

  echo ""
  log "URLs de acceso (después de port-forward):"
  echo "  Jaeger UI:          kubectl port-forward -n otel-lab svc/jaeger-svc 16686:16686"
  echo "  Grafana:            kubectl port-forward -n otel-lab svc/grafana-svc 3000:3000"
  echo "  Prometheus:         kubectl port-forward -n otel-lab svc/prometheus-svc 9091:9090"
  echo "  Chaos Mesh:         kubectl port-forward -n chaos-mesh svc/chaos-dashboard 2333:2333"
  echo "  LitmusChaos:        kubectl port-forward -n litmus svc/litmus-frontend-service 9091:9091"
  echo "  OTel Collector zPages: kubectl port-forward -n otel-lab svc/otel-collector-svc 55679:55679"
}

# ════════════════════════════════════════════════════════════════
# MAIN
# ════════════════════════════════════════════════════════════════
main() {
  echo ""
  echo -e "${CYAN}╔══════════════════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}║  OTel Lab — Chaos Engineering con Chaos Mesh + Litmus ║${NC}"
  echo -e "${CYAN}║  Proyecto: $GCP_PROJECT                         ║${NC}"
  echo -e "${CYAN}╚══════════════════════════════════════════════════════╝${NC}"
  echo ""

  case "${1:-}" in
    --chaos)
      # Solo ejecutar experimentos (stack ya desplegado)
      generate_baseline_traffic
      run_chaos_mesh_experiments
      run_litmus_experiments
      show_status
      ;;
    --status)
      show_status
      ;;
    --install-chaos-tools)
      # Solo instalar las herramientas de chaos
      install_chaos_mesh
      install_litmus_chaos
      ;;
    *)
      # Instalación completa
      check_prerequisites
      setup_gke_cluster
      build_and_push_images
      deploy_otel_stack
      install_chaos_mesh
      install_litmus_chaos
      generate_baseline_traffic
      run_chaos_mesh_experiments
      run_litmus_experiments
      show_status
      ;;
  esac

  echo ""
  ok "Script completado. Revisar resultados en ChaosCenter y ChaosResult CRDs."
}

main "$@"
