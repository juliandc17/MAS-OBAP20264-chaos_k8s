# Chaos Engineering con Chaos Mesh + LitmusChaos
## Migración del laboratorio Docker Compose → GKE

---

## Qué cambió técnicamente

### Antes (Docker Compose — Módulo D)

```python
# chaos_experiments.py — fault DENTRO de la aplicación
CHAOS_LATENCY_MS = int(os.getenv("CHAOS_LATENCY_MS", "0"))

def apply_chaos():
    if CHAOS_LATENCY_MS > 0:
        time.sleep(CHAOS_LATENCY_MS / 1000)   # ← código de la app
```

```python
# data-service/main.py — error DENTRO de la aplicación
if random.random() < CHAOS_ERROR_RATE:
    raise HTTPException(status_code=500)       # ← código de la app
```

### Después (GKE — Chaos Mesh + LitmusChaos)

```yaml
# Chaos Mesh — fault en el KERNEL DE RED
# La app NO tiene ningún time.sleep() ni random()
kind: NetworkChaos
spec:
  action: delay
  delay:
    latency: "200ms"     # ← tc qdisc en el kernel del nodo
```

```yaml
# LitmusChaos — steady state hypothesis formal
probe:
  - name: alert-fired-during-chaos
    type: promProbe        # ← verifica que Prometheus alertó
    mode: DuringChaos      # ← mide el MTTD automáticamente
```

---

## Estructura del proyecto

```
chaos-k8s/
├── base/
│   ├── 00-namespace-rbac.yaml     # Namespace, RBAC, ServiceAccounts
│   ├── 01-configmaps.yaml         # OTel Collector config, DB init SQL
│   └── 02-deployments.yaml        # Todos los Deployments, Services, HPA
│
├── chaos-mesh/
│   ├── experiment-1-network-latency.yaml  # NetworkChaos 200ms en service-b
│   └── experiment-2-http-error.yaml       # HTTPChaos + PodChaos + StressChaos
│
├── litmus/
│   ├── chaosengine-experiment-1.yaml      # ChaosEngine con probes de red
│   └── chaosengine-experiment-2.yaml      # ChaosEngine con pod failure
│
├── monitoring/
│   └── prometheus-config.yaml             # Prometheus + reglas AIOps para GKE
│
└── scripts/
    └── setup.sh                           # Instalación y ejecución completa
```

---

## Prerrequisitos

```bash
# 1. Herramientas necesarias
gcloud --version    # Google Cloud SDK
kubectl version     # Kubernetes CLI
helm version        # Helm 3.x
docker --version    # Docker Desktop

# 2. Autenticación GCP
gcloud auth login
gcloud auth application-default login
gcloud config set project mas-obap20264-otellabs
```

---

## Instalación completa (primera vez)

```bash
chmod +x scripts/setup.sh
./scripts/setup.sh
```

El script ejecuta en orden:
1. Crea el cluster GKE `otel-lab-chaos` en us-east1
2. Construye y publica las imágenes en GCR
3. Despliega el stack OTel base
4. Instala Chaos Mesh via Helm
5. Instala LitmusChaos operator
6. Genera tráfico baseline
7. Ejecuta los 2 experimentos de chaos
8. Muestra el estado final

---

## Ejecutar solo los experimentos (stack ya desplegado)

```bash
./scripts/setup.sh --chaos
```

---

## Experimento 1 — Chaos Mesh: NetworkChaos 200ms en service-b

**Qué hace:** Inyecta 200ms de latencia real a nivel de red en todos los pods de service-b usando `tc qdisc` del kernel Linux.

**Por qué es diferente al laboratorio Docker:**
- No modifica el código de service-b
- La latencia es real de red — OTel la mide como latencia de HTTP, no de CPU
- Rollback automático cuando termina el TTL (5 minutos)
- Blast radius controlado: solo pods con label `app=service-b`

```bash
# Aplicar manualmente
kubectl apply -f k8s/chaos-mesh/experiment-1-network-latency.yaml

# Ver estado
kubectl get networkchaos -n otel-lab

# Eliminar (rollback)
kubectl delete -f k8s/chaos-mesh/experiment-1-network-latency.yaml
```

**Qué verificar en Grafana:**
- Panel 2: Latencia p99 de service-b debe subir > 200ms
- Panel 6: Spans en vuelo aumentan
- Panel 7: Burn rate sube si la latencia causa timeouts

---

## Experimento 2 — LitmusChaos: Pod Failure en data-service

**Qué hace:** LitmusChaos elimina pods de data-service periódicamente y verifica automáticamente que:
1. El sistema estaba saludable ANTES del chaos (steady state)
2. Prometheus detectó el fallo DURANTE el chaos (MTTD < 2 min)
3. El sistema se recuperó DESPUÉS del chaos

```bash
# Aplicar el ChaosEngine
kubectl apply -f k8s/litmus/chaosengine-experiment-2.yaml

# Ver estado del experimento
kubectl get chaosengine -n otel-lab

# Ver resultado con veredicto Pass/Fail
kubectl get chaosresult -n otel-lab
kubectl describe chaosresult otel-lab-pod-failure-pod-delete -n otel-lab
```

**El ChaosResult muestra:**
```yaml
status:
  experimentStatus:
    verdict: Pass     # o Fail si alguna probe falló
    probeSuccessPercentage: "100"
  probeStatuses:
    - name: alert-fired-during-chaos
      status:
        verdict: Passed
        description: "AIOpsCorrelatedAnomaly activa en 47s — MTTD OK"
```

---

## Acceder a los dashboards

```bash
# Jaeger — flame graphs de trazas durante el chaos
kubectl port-forward -n otel-lab svc/jaeger-svc 16686:16686 &
# Abrir: http://localhost:16686

# Prometheus — queries durante el chaos
kubectl port-forward -n otel-lab svc/prometheus-svc 9091:9090 &
# Abrir: http://localhost:9091

# Chaos Mesh Dashboard — estado visual de los experiments
kubectl port-forward -n chaos-mesh svc/chaos-dashboard 2333:2333 &
# Abrir: http://localhost:2333

# LitmusChaos ChaosCenter — resultados y probes
kubectl port-forward -n litmus svc/litmus-frontend-service 9092:9091 &
# Abrir: http://localhost:9092 (admin/litmus)
```

---

## Diferencias técnicas clave

| Aspecto | Docker Compose (antes) | GKE + Chaos Mesh + Litmus (ahora) |
|---|---|---|
| Dónde vive el fault | Código de la app (Python) | Kernel de red (tc qdisc) |
| La app sabe del chaos | Sí (lee variable de entorno) | No — es completamente transparente |
| Tipo de latencia | `time.sleep()` — CPU time | Latencia real de red — medida por OTel |
| Rollback | Restart del contenedor | TTL automático en el CRD |
| Steady state | No existe | ChaosEngine valida antes y después |
| MTTD medido | Script Python con polling | Prometheus probe en el ChaosEngine |
| Veredicto formal | JSON generado manualmente | ChaosResult CRD con Pass/Fail |
| Blast radius | Todo el contenedor | Selector de labels K8s |
| Programación | Manual | Schedule CRD (cron) |

---

## Limpiar el laboratorio

```bash
# Eliminar experiments activos
kubectl delete networkchaos,httpchaos,podchaos --all -n otel-lab
kubectl delete chaosengine --all -n otel-lab

# Desinstalar Chaos Mesh
helm uninstall chaos-mesh -n chaos-mesh

# Desinstalar LitmusChaos
kubectl delete -f https://litmuschaos.github.io/litmus/litmus-operator-v3.8.0.yaml

# Eliminar el cluster GKE (¡cuidado!)
gcloud container clusters delete otel-lab-chaos \
  --region=us-east1 --project=mas-obap20264-otellabs
```

---

## Referencias

- Chaos Mesh docs: https://chaos-mesh.org/docs/
- LitmusChaos docs: https://docs.litmuschaos.io/
- LitmusChaos Hub: https://hub.litmuschaos.io/
- Principles of Chaos Engineering: https://principlesofchaos.org/
- CNCF Chaos Engineering landscape: https://landscape.cncf.io/?group=chaos-engineering
