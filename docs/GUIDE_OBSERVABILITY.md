# Guía: Prometheus + Grafana — Ductifact

> **Prerequisito**: la API ya expone `/metrics` (Prometheus) y el middleware
> `MetricsMiddleware` registra `http_requests_total` y `http_request_duration_seconds`.
> Esta guía configura Prometheus para scrapear esas métricas y Grafana para visualizarlas.

---

## ¿Qué es la observabilidad y por qué importa?

Observabilidad es la capacidad de entender el estado interno de un sistema
a partir de sus salidas externas. En una API REST como Ductifact, eso se traduce
en tres pilares:

| Pilar       | Qué responde                          | Herramienta típica         |
|-------------|---------------------------------------|----------------------------|
| **Métricas**  | ¿Cuántas requests? ¿Cuánta latencia?  | Prometheus + Grafana       |
| **Logs**      | ¿Qué pasó exactamente en esta request?| Loki / ELK / CloudWatch    |
| **Trazas**    | ¿Cómo se propagó esta request entre servicios? | Jaeger / Tempo / OpenTelemetry |

Esta guía cubre el primer pilar: **métricas**. Es el más fácil de implementar
y el que más valor aporta desde el primer día.

### ¿Por qué Prometheus + Grafana?

- **Prometheus** es el estándar de facto para métricas en el ecosistema cloud-native
  (graduado en CNCF junto a Kubernetes). Almacena series temporales de forma eficiente.
- **Grafana** es la herramienta de visualización más popular. Se conecta a
  Prometheus (y muchas otras fuentes) para crear dashboards y alertas.
- Ambos son **open source**, ligeros, y funcionan perfectamente con Docker.

---

## Conceptos clave antes de empezar

### Modelo Pull vs Push

Prometheus usa un modelo **pull**: él va a buscar las métricas a tu aplicación
periódicamente (cada 15s por defecto), en vez de que tu app las envíe.

```
┌─────────┐   GET /metrics   ┌─────────────┐
│Prometheus│ ───────────────► │ Ductifact   │
│  (pull)  │ ◄─────────────── │   API       │
│          │   texto plano    │ :APP_PORT   │
└─────────┘   con métricas    └─────────────┘
      │
      │  consultas PromQL
      ▼
┌─────────┐
│ Grafana │  → dashboards + alertas
└─────────┘
```

**Ventajas del pull**: Prometheus decide cuándo y a quién scrapear, la app no
necesita conocer la existencia de Prometheus, y si la app se cae, Prometheus
lo detecta inmediatamente (el scrape falla → alerta).

### Tipos de métricas en Prometheus

Nuestra API ya expone dos tipos. Estos son los cuatro que existen:

| Tipo        | Descripción                                    | Ejemplo en Ductifact                           |
|-------------|------------------------------------------------|------------------------------------------------|
| **Counter** | Solo sube (o se resetea a 0). Cuenta eventos.  | `http_requests_total` — total de requests      |
| **Histogram** | Mide distribuciones (latencia). Agrupa valores en buckets. | `http_request_duration_seconds` — latencia  |
| **Gauge**     | Sube y baja. Mide valores actuales.            | `go_goroutines` — goroutines activas (auto)    |
| **Summary**   | Similar a histogram, calcula percentiles en el cliente. | Menos común, no lo usamos.               |

> **¿Por qué histogram y no summary?** Los histograms permiten agregar datos
> de múltiples instancias y calcular percentiles en el servidor (Prometheus).
> Los summaries no se pueden agregar, lo que limita su utilidad en entornos
> multi-instancia.

### ¿Qué es PromQL?

PromQL (Prometheus Query Language) es el lenguaje para consultar métricas.
Algunas funciones esenciales:

| Función              | Qué hace                                                 | Ejemplo                                        |
|----------------------|----------------------------------------------------------|------------------------------------------------|
| `rate(counter[5m])`  | Velocidad por segundo de un counter en los últimos 5min  | `rate(http_requests_total[5m])` → req/s        |
| `sum(...) by (label)`| Agrupa y suma por una etiqueta                           | `sum(rate(...)) by (method)` → req/s por GET, POST... |
| `histogram_quantile` | Calcula percentiles a partir de un histogram             | `histogram_quantile(0.95, ...)` → latencia p95 |
| `increase(c[1h])`   | Incremento total de un counter en un periodo             | `increase(http_requests_total[24h])` → total 24h |

> **Tip**: `rate()` se usa siempre con counters. Nunca leas un counter
> directamente (su valor absoluto no tiene sentido, siempre va subiendo).

---

## Índice

1. [Estructura de ficheros](#1-estructura-de-ficheros)
2. [Configurar Prometheus](#2-configurar-prometheus)
3. [Configurar Grafana](#3-configurar-grafana)
4. [Docker Compose (dev)](#4-docker-compose-dev)
5. [Docker Compose (prod / staging)](#5-docker-compose-prod--staging)
6. [Arrancar y verificar](#6-arrancar-y-verificar)
7. [Crear dashboard en Grafana](#7-crear-dashboard-en-grafana)
8. [Alertas básicas](#8-alertas-básicas)
9. [Makefile targets](#9-makefile-targets)

---

## 1. Estructura de ficheros

Todo vive en el repositorio `infra/`, separado del código de la aplicación.
Esto sigue el principio de **separación de concerns**: el backend solo se
preocupa de exponer `/metrics`, y la infraestructura se encarga de recoger,
almacenar y visualizar esas métricas.

```
infra/
  observability/
    prometheus/
      prometheus.yml          # Config de Prometheus
      alerts.yml              # Reglas de alerta (opcional)
    grafana/
      provisioning/
        datasources/
          prometheus.yml      # Datasource automático
        dashboards/
          dashboard.yml       # Provider de dashboards
      dashboards/
        ductifact-api.json    # Dashboard pre-configurado
  docker-compose.prod.yml     # (ya existente — se añaden servicios)
  docker-compose.staging.yml  # (ya existente — se añaden servicios)
```

Crear la estructura:

```bash
cd infra
mkdir -p observability/prometheus \
         observability/grafana/provisioning/datasources \
         observability/grafana/provisioning/dashboards \
         observability/grafana/dashboards
```

## 2. Configurar Prometheus

El fichero `prometheus.yml` es el corazón de Prometheus. Le dice:
- **A quién scrapear** (`scrape_configs`) — qué endpoints visitar para recoger métricas.
- **Con qué frecuencia** (`scrape_interval`) — cada cuántos segundos.
- **Qué reglas evaluar** (`rule_files`) — alertas y recording rules.

Crear `infra/observability/prometheus/prometheus.yml`:

```yaml
global:
  scrape_interval: 15s        # Cada cuánto scrapear métricas
  evaluation_interval: 15s    # Cada cuánto evaluar reglas de alerta

# (Opcional) Fichero de reglas de alerta
rule_files:
  - "alerts.yml"

scrape_configs:
  # ── Ductifact API ──────────────────────────────────────
  - job_name: "ductifact-api"
    metrics_path: /metrics
    static_configs:
      - targets: ["app:${APP_PORT}"]   # Docker service name
        labels:
          environment: "production"

  # ── Prometheus self-monitoring ─────────────────────────
  - job_name: "prometheus"
    static_configs:
      - targets: ["localhost:9090"]
```

> **Nota**: `app` es el service name del backend en el compose. Prometheus
> usa la red interna de Docker para comunicarse, por eso no necesitamos IPs.
> Si el puerto varía por entorno, ajustar `targets` o usar `file_sd_configs`.

### ¿Qué pasa cuando Prometheus scrapea?

1. Cada 15 segundos, Prometheus hace `GET http://app:APP_PORT/metrics`
2. La respuesta es texto plano con formato OpenMetrics, algo como:
   ```
   # HELP http_requests_total Total number of HTTP requests.
   # TYPE http_requests_total counter
   http_requests_total{method="GET",path="/v1/users/:id",status="200"} 42
   http_requests_total{method="POST",path="/v1/auth/login",status="401"} 3
   
   # HELP http_request_duration_seconds Duration of HTTP requests in seconds.
   # TYPE http_request_duration_seconds histogram
   http_request_duration_seconds_bucket{method="GET",path="/health",status="200",le="0.005"} 150
   http_request_duration_seconds_bucket{method="GET",path="/health",status="200",le="0.01"} 150
   ...
   ```
3. Prometheus almacena cada línea como un **data point** con timestamp en su TSDB
   (Time Series Database), una base de datos optimizada para series temporales.
4. Estos datos se retienen 15 días (dev) o 30 días (prod) según la config.

### Alertas opcionales

Las alerting rules se evalúan periódicamente por Prometheus. Cuando una
condición se cumple durante el tiempo definido en `for`, Prometheus marca
la alerta como **firing** y la envía a Alertmanager (si está configurado).

Crear `infra/observability/prometheus/alerts.yml`:

```yaml
groups:
  - name: ductifact
    rules:
      # Alta tasa de errores 5xx (>5% en 5 min)
      - alert: HighErrorRate
        expr: |
          sum(rate(http_requests_total{status=~"5.."}[5m]))
          /
          sum(rate(http_requests_total[5m]))
          > 0.05
        for: 2m
        labels:
          severity: critical
        annotations:
          summary: "Alta tasa de errores 5xx ({{ $value | humanizePercentage }})"

      # Latencia alta (p95 > 1s en 5 min)
      - alert: HighLatency
        expr: |
          histogram_quantile(0.95, sum(rate(http_request_duration_seconds_bucket[5m])) by (le))
          > 1
        for: 2m
        labels:
          severity: warning
        annotations:
          summary: "Latencia p95 por encima de 1s ({{ $value }}s)"

      # API caída (0 requests en 2 min)
      - alert: APIDown
        expr: |
          sum(rate(http_requests_total[2m])) == 0
        for: 2m
        labels:
          severity: critical
        annotations:
          summary: "La API no está recibiendo requests"
```

## 3. Configurar Grafana

Grafana por sí solo no almacena métricas — es una capa de visualización que
consulta fuentes de datos (datasources). En nuestro caso, consulta a Prometheus.

Grafana soporta **provisioning**: configurar datasources y dashboards
automáticamente mediante ficheros YAML/JSON que se cargan al arrancar el
contenedor. Esto es clave para **infraestructura como código** — el estado
de Grafana se define en ficheros versionados, no en clicks manuales en la UI.

### Datasource automático

Este fichero le dice a Grafana: "al arrancar, configura automáticamente
Prometheus como fuente de datos, apuntando a `http://prometheus:9090`".

Crear `infra/observability/grafana/provisioning/datasources/prometheus.yml`:

```yaml
apiVersion: 1

datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true
    editable: false
```

### Dashboard provider

El dashboard provider le dice a Grafana dónde buscar ficheros JSON de
dashboards para cargarlos automáticamente. Es un nivel de indirección:
"busca dashboards JSON en esta carpeta del contenedor".

Crear `infra/observability/grafana/provisioning/dashboards/dashboard.yml`:

```yaml
apiVersion: 1

providers:
  - name: "Ductifact"
    orgId: 1
    folder: ""
    type: file
    disableDeletion: false
    editable: true
    options:
      path: /var/lib/grafana/dashboards
      foldersFromFilesStructure: false
```

### Dashboard pre-configurado

Este JSON define los paneles que verás en Grafana. Cada panel tiene:
- **`type`**: tipo de visualización (`timeseries`, `stat`, `gauge`, etc.)
- **`targets`**: una o más queries PromQL que alimentan el panel
- **`gridPos`**: posición y tamaño en el grid del dashboard
- **`fieldConfig`**: unidades, umbrales de color, etc.

> **Tip**: puedes crear dashboards en la UI de Grafana y luego exportar
> el JSON (Dashboard → Share → Export → Save to file) para versionarlo aquí.

Crear `infra/observability/grafana/dashboards/ductifact-api.json`:

```json
{
  "annotations": { "list": [] },
  "editable": true,
  "fiscalYearStartMonth": 0,
  "graphTooltip": 1,
  "links": [],
  "panels": [
    {
      "title": "Request Rate (req/s)",
      "type": "timeseries",
      "gridPos": { "h": 8, "w": 12, "x": 0, "y": 0 },
      "targets": [
        {
          "expr": "sum(rate(http_requests_total[5m])) by (method)",
          "legendFormat": "{{ method }}",
          "refId": "A"
        }
      ],
      "fieldConfig": {
        "defaults": { "unit": "reqps" },
        "overrides": []
      }
    },
    {
      "title": "Error Rate (5xx %)",
      "type": "stat",
      "gridPos": { "h": 8, "w": 6, "x": 12, "y": 0 },
      "targets": [
        {
          "expr": "sum(rate(http_requests_total{status=~\"5..\"}[5m])) / sum(rate(http_requests_total[5m])) * 100",
          "legendFormat": "error %",
          "refId": "A"
        }
      ],
      "fieldConfig": {
        "defaults": { "unit": "percent", "thresholds": { "steps": [
          { "color": "green", "value": null },
          { "color": "yellow", "value": 1 },
          { "color": "red", "value": 5 }
        ]}},
        "overrides": []
      }
    },
    {
      "title": "Total Requests",
      "type": "stat",
      "gridPos": { "h": 8, "w": 6, "x": 18, "y": 0 },
      "targets": [
        {
          "expr": "sum(increase(http_requests_total[24h]))",
          "legendFormat": "24h total",
          "refId": "A"
        }
      ],
      "fieldConfig": {
        "defaults": { "unit": "short" },
        "overrides": []
      }
    },
    {
      "title": "Latency p50 / p95 / p99",
      "type": "timeseries",
      "gridPos": { "h": 8, "w": 12, "x": 0, "y": 8 },
      "targets": [
        {
          "expr": "histogram_quantile(0.50, sum(rate(http_request_duration_seconds_bucket[5m])) by (le))",
          "legendFormat": "p50",
          "refId": "A"
        },
        {
          "expr": "histogram_quantile(0.95, sum(rate(http_request_duration_seconds_bucket[5m])) by (le))",
          "legendFormat": "p95",
          "refId": "B"
        },
        {
          "expr": "histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket[5m])) by (le))",
          "legendFormat": "p99",
          "refId": "C"
        }
      ],
      "fieldConfig": {
        "defaults": { "unit": "s" },
        "overrides": []
      }
    },
    {
      "title": "Requests by Status Code",
      "type": "timeseries",
      "gridPos": { "h": 8, "w": 12, "x": 12, "y": 8 },
      "targets": [
        {
          "expr": "sum(rate(http_requests_total[5m])) by (status)",
          "legendFormat": "{{ status }}",
          "refId": "A"
        }
      ],
      "fieldConfig": {
        "defaults": { "unit": "reqps" },
        "overrides": []
      }
    },
    {
      "title": "Requests by Endpoint",
      "type": "timeseries",
      "gridPos": { "h": 8, "w": 24, "x": 0, "y": 16 },
      "targets": [
        {
          "expr": "sum(rate(http_requests_total[5m])) by (path)",
          "legendFormat": "{{ path }}",
          "refId": "A"
        }
      ],
      "fieldConfig": {
        "defaults": { "unit": "reqps" },
        "overrides": []
      }
    }
  ],
  "schemaVersion": 39,
  "tags": ["ductifact", "api", "go"],
  "templating": { "list": [] },
  "time": { "from": "now-1h", "to": "now" },
  "title": "Ductifact API",
  "uid": "ductifact-api"
}
```

## 4. Docker Compose (dev)

Para desarrollo local, añadir a `backend/docker-compose.yml` los servicios
de monitoring.

Usamos **Docker Compose profiles** (`profiles: [ monitoring ]`) para que
Prometheus y Grafana **no arranquen por defecto** con `docker compose up`.
Solo se levantan cuando explícitamente lo pides con `--profile monitoring`.
Así no consumen recursos si solo estás desarrollando features.

```yaml
services:
  # ... (postgres y app existentes) ...

  prometheus:
    image: prom/prometheus:v3.3.0
    container_name: ductifact_dev_prometheus
    restart: unless-stopped
    profiles: [ monitoring ]
    ports:
      - "9090:9090"
    volumes:
      - ../infra/observability/prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - ../infra/observability/prometheus/alerts.yml:/etc/prometheus/alerts.yml:ro
      - prometheus_data:/prometheus
    command:
      - "--config.file=/etc/prometheus/prometheus.yml"
      - "--storage.tsdb.retention.time=15d"

  grafana:
    image: grafana/grafana:11.6.0
    container_name: ductifact_dev_grafana
    restart: unless-stopped
    profiles: [ monitoring ]
    ports:
      - "3000:3000"
    environment:
      - GF_SECURITY_ADMIN_USER=admin
      - GF_SECURITY_ADMIN_PASSWORD=admin
      - GF_USERS_ALLOW_SIGN_UP=false
    volumes:
      - ../infra/observability/grafana/provisioning:/etc/grafana/provisioning:ro
      - ../infra/observability/grafana/dashboards:/var/lib/grafana/dashboards:ro
      - grafana_data:/var/lib/grafana
    depends_on:
      - prometheus

volumes:
  # ... (postgres_data existente) ...
  prometheus_data:
  grafana_data:
```

> Los volúmenes montan desde `../infra/observability/` — los ficheros de
> configuración viven en `infra/`, compartidos entre dev y prod.
> El sufijo `:ro` (read-only) es una buena práctica de seguridad: el contenedor
> puede leer la config pero no modificarla.

## 5. Docker Compose (prod / staging)

Añadir a `infra/docker-compose.prod.yml`:

```yaml
services:
  # ... (postgres y app existentes) ...

  # ── Prometheus ─────────────────────────────────────────────
  prometheus:
    image: prom/prometheus:v3.3.0
    container_name: ductifact_prod_prometheus
    restart: unless-stopped
    volumes:
      - ./observability/prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - ./observability/prometheus/alerts.yml:/etc/prometheus/alerts.yml:ro
      - prod_prometheus_data:/prometheus
    command:
      - "--config.file=/etc/prometheus/prometheus.yml"
      - "--storage.tsdb.retention.time=30d"
    networks:
      - prod_internal

  # ── Grafana ────────────────────────────────────────────────
  grafana:
    image: grafana/grafana:11.6.0
    container_name: ductifact_prod_grafana
    restart: unless-stopped
    ports:
      - "127.0.0.1:3000:3000"       # Solo accesible via Caddy/tunnel
    environment:
      - GF_SECURITY_ADMIN_USER=${GRAFANA_USER}
      - GF_SECURITY_ADMIN_PASSWORD=${GRAFANA_PASSWORD}
      - GF_USERS_ALLOW_SIGN_UP=false
      - GF_SERVER_ROOT_URL=https://grafana.tudominio.com
    volumes:
      - ./observability/grafana/provisioning:/etc/grafana/provisioning:ro
      - ./observability/grafana/dashboards:/var/lib/grafana/dashboards:ro
      - prod_grafana_data:/var/lib/grafana
    depends_on:
      - prometheus
    networks:
      - prod_internal

volumes:
  # ... (prod_postgres_data existente) ...
  prod_prometheus_data:
  prod_grafana_data:
```

> Mismo patrón para `docker-compose.staging.yml` cambiando prefijos a `staging_`.

> **Seguridad**: en prod, Grafana escucha solo en `127.0.0.1` y se expone
> al exterior via Caddy con HTTPS + autenticación.

> **¿Por qué `127.0.0.1:3000:3000` y no `3000:3000`?**
> Sin el bind a `127.0.0.1`, Docker expone el puerto en todas las interfaces
> de red (0.0.0.0), haciéndolo accesible desde internet directamente,
> saltándose el firewall del host. Con `127.0.0.1` solo es accesible
> localmente, y el acceso externo pasa por Caddy (HTTPS + auth).

## 6. Arrancar y verificar

### Dev (desde `backend/`)

```bash
# Arrancar solo monitoring (requiere app + postgres ya corriendo)
docker compose --profile monitoring up -d

# O todo junto
docker compose --profile smoke --profile monitoring up -d
```

### Prod (desde `infra/`)

```bash
docker compose -f docker-compose.prod.yml up -d
```

### Verificar

| Servicio   | URL                                    | Esperado                  |
|------------|----------------------------------------|---------------------------|
| API        | `http://localhost:${APP_PORT}/metrics`  | Texto plano con métricas  |
| Prometheus | `http://localhost:9090`                 | UI de Prometheus          |
| Grafana    | `http://localhost:3000`                 | Login (admin/admin)       |

### Checklist Prometheus

1. Abrir `http://localhost:9090/targets`
2. Verificar que `ductifact-api` aparece como **UP**
3. En la barra de queries, probar: `http_requests_total`

### Checklist Grafana

1. Abrir `http://localhost:3000` → login `admin` / `admin`
2. Ir a **Dashboards** → buscar **Ductifact API**
3. El dashboard debería cargar automáticamente con datos

## 7. Crear dashboard en Grafana

El dashboard provisionado incluye estos paneles. Cada uno muestra una
perspectiva diferente de la salud de la API — juntos forman el "golden
signals" pattern (los 4 indicadores dorados de Google SRE):

1. **Throughput** (Request Rate) — ¿cuántas peticiones estamos sirviendo?
2. **Errors** (Error Rate) — ¿qué porcentaje fallan?
3. **Latency** (p50/p95/p99) — ¿cuánto tardan las respuestas?
4. **Saturation** — ¿estamos al límite? (se añade si monitorizamos CPU/memory)

| Panel                    | Tipo       | Query base                                            |
|--------------------------|------------|-------------------------------------------------------|
| Request Rate (req/s)     | Timeseries | `sum(rate(http_requests_total[5m])) by (method)`      |
| Error Rate (5xx %)       | Stat       | `5xx / total * 100`                                   |
| Total Requests (24h)     | Stat       | `sum(increase(http_requests_total[24h]))`             |
| Latency p50/p95/p99      | Timeseries | `histogram_quantile(0.xx, ...)`                       |
| Requests by Status Code  | Timeseries | `sum(rate(...)) by (status)`                          |
| Requests by Endpoint     | Timeseries | `sum(rate(...)) by (path)`                            |

### Queries útiles adicionales

Estas queries usan PromQL. Algunas claves para entenderlas:
- `rate(metric[5m])` — calcula la velocidad por segundo usando los últimos 5 min de datos
- `sum(...) by (label)` — agrupa los resultados por una etiqueta
- `histogram_quantile(0.95, ...)` — de un histogram, extrae el valor en el percentil 95
- `topk(5, ...)` — devuelve los 5 valores más altos

```promql
# Requests por segundo por endpoint
sum(rate(http_requests_total[5m])) by (path)

# Latencia p99 por endpoint
histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket[5m])) by (le, path))

# Top 5 endpoints más lentos
topk(5, histogram_quantile(0.95, sum(rate(http_request_duration_seconds_bucket[5m])) by (le, path)))

# Ratio de errores por endpoint
sum(rate(http_requests_total{status=~"5.."}[5m])) by (path)
/
sum(rate(http_requests_total[5m])) by (path)
```

## 8. Alertas básicas

Las alertas definidas en `alerts.yml` (paso 2) se evalúan en Prometheus,
pero Prometheus solo **detecta** que algo va mal — no envía emails ni
mensajes. Para eso necesitas un sistema de notificaciones:

- **Grafana Alerts**: más fácil de configurar (UI visual), ideal para empezar.
- **Alertmanager**: componente oficial de Prometheus, más potente
  (deduplicación, silenciado, agrupación, routing), mejor para producción.

### Opción A: Grafana Alerts (recomendado para empezar)

1. En Grafana → **Alerting** → **Alert rules**
2. Crear regla basada en cualquier query del dashboard
3. Configurar canal de notificación (email, Slack, Discord, etc.)

### Opción B: Alertmanager (escala mejor)

Añadir el servicio al compose correspondiente:

```yaml
alertmanager:
  image: prom/alertmanager:v0.28.1
  container_name: ductifact_alertmanager
  restart: unless-stopped
  ports:
    - "9093:9093"
  volumes:
    - ./observability/alertmanager/alertmanager.yml:/etc/alertmanager/alertmanager.yml:ro
  networks:
    - prod_internal
```

Y añadir en `infra/observability/prometheus/prometheus.yml`:

```yaml
alerting:
  alertmanagers:
    - static_configs:
        - targets: ["alertmanager:9093"]
```

## 9. Makefile targets

Añadir al `backend/Makefile` (para dev):

```makefile
# ── Monitoring ─────────────────────────────────────────────
.PHONY: monitoring-start monitoring-stop monitoring-logs

monitoring-start: ## Start Prometheus + Grafana
	docker compose --profile monitoring up -d

monitoring-stop: ## Stop Prometheus + Grafana
	docker compose --profile monitoring down

monitoring-logs: ## Tail monitoring logs
	docker compose --profile monitoring logs -f
```

---

## Resumen de pasos rápidos

```bash
# 1. Crear estructura de ficheros (desde infra/)
cd infra
mkdir -p observability/prometheus \
         observability/grafana/provisioning/datasources \
         observability/grafana/provisioning/dashboards \
         observability/grafana/dashboards

# 2. Copiar los ficheros de config descritos arriba

# 3. Añadir servicios prometheus + grafana a los docker-compose

# 4. Arrancar (desde backend/ para dev)
cd ../backend
make monitoring-start

# 5. Verificar
open http://localhost:9090/targets    # Prometheus
open http://localhost:3000            # Grafana (admin/admin)
```

> **Siguiente paso**: una vez validado en dev, desplegar con
> `docker compose -f docker-compose.prod.yml up -d` desde `infra/`
> con credenciales seguras vía `.env`.

---

## Glosario rápido

| Término             | Definición                                                                |
|----------------------|---------------------------------------------------------------------------|
| **Scrape**           | La acción de Prometheus de hacer GET a `/metrics` para recoger datos     |
| **Target**           | Un endpoint que Prometheus scrapea (ej: `app:8080`)                     |
| **Job**              | Grupo lógico de targets con la misma función (ej: `ductifact-api`)      |
| **Label**            | Metadata clave-valor en una métrica (`method="GET"`, `status="200"`)     |
| **TSDB**             | Time Series DataBase — cómo Prometheus almacena datos internamente      |
| **Recording rule**   | Query PromQL pre-calculada que se guarda como nueva métrica (optimización)|
| **Alerting rule**    | Condición PromQL que, si se cumple, genera una alerta                   |
| **Provisioning**     | Configuración automática de Grafana via ficheros (datasources, dashboards)|
| **Golden signals**   | Los 4 indicadores clave de Google SRE: latency, traffic, errors, saturation |
| **Cardinality**      | Número de combinaciones únicas de labels — alta cardinality = problemas de memoria |
