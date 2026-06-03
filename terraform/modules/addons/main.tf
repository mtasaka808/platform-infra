locals {
  # Istio uses a specific namespace that must exist before the chart installs
  istio_namespace     = "istio-system"
  monitoring_namespace = "monitoring"
  logging_namespace   = "logging"
  tracing_namespace   = "tracing"
  karpenter_namespace = "karpenter"
  security_namespace  = "security"
  velero_namespace    = "velero"
}

# ── cert-manager ─────────────────────────────────────────────────────────────
resource "helm_release" "cert_manager" {
  name             = "cert-manager"
  repository       = "https://charts.jetstack.io"
  chart            = "cert-manager"
  version          = var.cert_manager_version
  namespace        = "cert-manager"
  create_namespace = true
  wait             = true

  set {
    name  = "installCRDs"
    value = "true"
  }
  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = var.cert_manager_role_arn
  }
}

# ── Istio ─────────────────────────────────────────────────────────────────────
resource "kubernetes_namespace" "istio_system" {
  metadata {
    name   = local.istio_namespace
    labels = { "istio-injection" = "disabled" }
  }
}

resource "helm_release" "istio_base" {
  depends_on       = [kubernetes_namespace.istio_system]
  name             = "istio-base"
  repository       = "https://istio-release.storage.googleapis.com/charts"
  chart            = "base"
  version          = var.istio_version
  namespace        = local.istio_namespace
  wait             = true
}

resource "helm_release" "istiod" {
  depends_on = [helm_release.istio_base]
  name       = "istiod"
  repository = "https://istio-release.storage.googleapis.com/charts"
  chart      = "istiod"
  version    = var.istio_version
  namespace  = local.istio_namespace
  wait       = true

  values = [yamlencode({
    pilot = {
      resources = {
        requests = { cpu = "100m", memory = "256Mi" }
        limits   = { cpu = "500m", memory = "512Mi" }
      }
    }
    meshConfig = {
      accessLogFile        = "/dev/stdout"
      enableTracing        = true
      defaultConfig = {
        tracing = {
          sampling = 100  # 100% in non-prod; set to 1-10 for prod
          zipkin   = { address = "tempo-distributor.${local.tracing_namespace}:9411" }
        }
      }
    }
  })]
}

resource "helm_release" "istio_ingress" {
  depends_on       = [helm_release.istiod]
  name             = "istio-ingressgateway"
  repository       = "https://istio-release.storage.googleapis.com/charts"
  chart            = "gateway"
  version          = var.istio_version
  namespace        = local.istio_namespace
  create_namespace = false
  wait             = true

  values = [yamlencode({
    service = {
      type = "LoadBalancer"
      annotations = {
        "service.beta.kubernetes.io/aws-load-balancer-type"   = "external"
        "service.beta.kubernetes.io/aws-load-balancer-scheme" = "internet-facing"
        "service.beta.kubernetes.io/aws-load-balancer-nlb-target-type" = "ip"
      }
    }
  })]
}

# ── Kiali ─────────────────────────────────────────────────────────────────────
resource "helm_release" "kiali_operator" {
  depends_on       = [helm_release.istiod]
  name             = "kiali-operator"
  repository       = "https://kiali.org/helm-charts"
  chart            = "kiali-operator"
  version          = var.kiali_version
  namespace        = "kiali-operator"
  create_namespace = true
  wait             = true
}

resource "kubectl_manifest" "kiali_cr" {
  depends_on = [helm_release.kiali_operator]
  yaml_body  = yamlencode({
    apiVersion = "kiali.io/v1alpha1"
    kind       = "Kiali"
    metadata = {
      name      = "kiali"
      namespace = local.istio_namespace
    }
    spec = {
      auth               = { strategy = "anonymous" }
      deployment         = { namespace = local.istio_namespace }
      external_services  = {
        prometheus = { url = "http://kube-prometheus-stack-prometheus.${local.monitoring_namespace}:9090" }
        tracing    = {
          enabled     = true
          internal_url = "http://tempo-query-frontend.${local.tracing_namespace}:16686"
          use_grpc    = false
        }
        grafana = {
          enabled = true
          internal_url = "http://kube-prometheus-stack-grafana.${local.monitoring_namespace}"
        }
      }
    }
  })
}

# ── kube-prometheus-stack (Prometheus + Grafana + AlertManager) ───────────────
resource "helm_release" "prometheus_stack" {
  name             = "kube-prometheus-stack"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  version          = var.prometheus_stack_version
  namespace        = local.monitoring_namespace
  create_namespace = true
  wait             = true
  timeout          = 600

  values = [yamlencode({
    grafana = {
      adminPassword = var.grafana_admin_password
      persistence   = { enabled = true, size = "10Gi" }
      sidecar        = { dashboards = { enabled = true, label = "grafana_dashboard" } }
      additionalDataSources = [
        {
          name    = "Loki"
          type    = "loki"
          url     = "http://loki-gateway.${local.logging_namespace}"
          access  = "proxy"
        },
        {
          name    = "Tempo"
          type    = "tempo"
          url     = "http://tempo-query-frontend.${local.tracing_namespace}:3100"
          access  = "proxy"
          jsonData = { tracesToLogsV2 = { datasourceUid = "loki" } }
        }
      ]
    }
    prometheus = {
      prometheusSpec = {
        retention    = "15d"
        storageSpec  = { volumeClaimTemplate = { spec = { resources = { requests = { storage = "50Gi" } } } } }
        serviceMonitorSelectorNilUsesHelmValues = false  # scrape all ServiceMonitors
        podMonitorSelectorNilUsesHelmValues     = false
      }
    }
    alertmanager = {
      alertmanagerSpec = {
        storage = { volumeClaimTemplate = { spec = { resources = { requests = { storage = "2Gi" } } } } }
      }
    }
  })]
}

# ── Loki (log aggregation) ────────────────────────────────────────────────────
resource "helm_release" "loki" {
  name             = "loki"
  repository       = "https://grafana.github.io/helm-charts"
  chart            = "loki"
  version          = var.loki_version
  namespace        = local.logging_namespace
  create_namespace = true
  wait             = true

  values = [yamlencode({
    loki = {
      auth_enabled = false
      commonConfig = { replication_factor = 1 }
      storage      = { type = "filesystem" }
    }
    singleBinary = {
      replicas = 1
      persistence = { enabled = true, size = "20Gi" }
    }
    gateway  = { enabled = true }
  })]
}

resource "helm_release" "promtail" {
  depends_on       = [helm_release.loki]
  name             = "promtail"
  repository       = "https://grafana.github.io/helm-charts"
  chart            = "promtail"
  version          = var.promtail_version
  namespace        = local.logging_namespace
  create_namespace = false
  wait             = true

  values = [yamlencode({
    config = {
      clients = [{ url = "http://loki-gateway.${local.logging_namespace}/loki/api/v1/push" }]
    }
  })]
}

# ── Tempo (distributed tracing) ───────────────────────────────────────────────
resource "helm_release" "tempo" {
  name             = "tempo"
  repository       = "https://grafana.github.io/helm-charts"
  chart            = "tempo-distributed"
  version          = var.tempo_version
  namespace        = local.tracing_namespace
  create_namespace = true
  wait             = true

  values = [yamlencode({
    traces = {
      otlp  = { grpc = { enabled = true }, http = { enabled = true } }
      zipkin = { enabled = true }
      jaeger = { thriftHttp = { enabled = true } }
    }
    storage = { trace = { backend = "local" } }
  })]
}

# ── OpenTelemetry Operator ────────────────────────────────────────────────────
resource "helm_release" "otel_operator" {
  depends_on       = [helm_release.cert_manager]
  name             = "opentelemetry-operator"
  repository       = "https://open-telemetry.github.io/opentelemetry-helm-charts"
  chart            = "opentelemetry-operator"
  version          = var.otel_operator_version
  namespace        = local.tracing_namespace
  create_namespace = false
  wait             = true

  set {
    name  = "manager.collectorImage.repository"
    value = "otel/opentelemetry-collector-contrib"
  }
}

# ── Karpenter (node autoprovisioning) ─────────────────────────────────────────
resource "helm_release" "karpenter" {
  name             = "karpenter"
  repository       = "oci://public.ecr.aws/karpenter"
  chart            = "karpenter"
  version          = var.karpenter_version
  namespace        = local.karpenter_namespace
  create_namespace = true
  wait             = true

  values = [yamlencode({
    settings = {
      clusterName = var.cluster_name
      clusterEndpoint = var.cluster_endpoint
      interruptionQueue = var.karpenter_queue_name
    }
    serviceAccount = {
      annotations = {
        "eks.amazonaws.com/role-arn" = var.karpenter_role_arn
      }
    }
  })]
}

# ── Falco (runtime security) ──────────────────────────────────────────────────
resource "helm_release" "falco" {
  name             = "falco"
  repository       = "https://falcosecurity.github.io/charts"
  chart            = "falco"
  version          = var.falco_version
  namespace        = local.security_namespace
  create_namespace = true
  wait             = true

  values = [yamlencode({
    driver  = { kind = "modern_ebpf" }
    falcosidekick = {
      enabled = true
      webui   = { enabled = true }
    }
  })]
}

# ── Kyverno (policy enforcement) ──────────────────────────────────────────────
resource "helm_release" "kyverno" {
  name             = "kyverno"
  repository       = "https://kyverno.github.io/kyverno"
  chart            = "kyverno"
  version          = var.kyverno_version
  namespace        = local.security_namespace
  create_namespace = false
  wait             = true
}

# ── Velero (backup) ───────────────────────────────────────────────────────────
resource "helm_release" "velero" {
  name             = "velero"
  repository       = "https://vmware-tanzu.github.io/helm-charts"
  chart            = "velero"
  version          = var.velero_version
  namespace        = local.velero_namespace
  create_namespace = true
  wait             = true

  values = [yamlencode({
    initContainers = [{
      name            = "velero-plugin-for-aws"
      image           = "velero/velero-plugin-for-aws:v1.10.0"
      imagePullPolicy = "IfNotPresent"
      volumeMounts    = [{ mountPath = "/target", name = "plugins" }]
    }]
    configuration = {
      backupStorageLocation = [{
        name     = "default"
        provider = "aws"
        bucket   = var.velero_bucket
        config   = { region = var.aws_region }
      }]
      volumeSnapshotLocation = [{
        name     = "default"
        provider = "aws"
        config   = { region = var.aws_region }
      }]
    }
    serviceAccount = {
      server = {
        annotations = { "eks.amazonaws.com/role-arn" = var.velero_role_arn }
      }
    }
    schedules = {
      daily-backup = {
        schedule = "0 2 * * *"
        template = { ttl = "720h" }  # 30 days
      }
    }
  })]
}
