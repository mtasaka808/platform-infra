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

  # S3 bucket created after addons module runs; reference via local
  # In dev: uses local filesystem for quick setup; set loki_s3_bucket to switch to S3
  values = [yamlencode({
    loki = {
      auth_enabled = false
      commonConfig = { replication_factor = 1 }
      storage = local.loki_bucket != "" ? {
        type = "s3"
        s3   = { region = var.aws_region; bucketnames = local.loki_bucket }
      } : { type = "filesystem" }
    }
    singleBinary = {
      replicas    = 1
      persistence = { enabled = true, size = "20Gi" }
    }
    gateway = { enabled = true }
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
      otlp   = { grpc = { enabled = true }, http = { enabled = true } }
      zipkin = { enabled = true }
      jaeger = { thriftHttp = { enabled = true } }
    }
    storage = local.tempo_bucket != "" ? {
      trace = {
        backend = "s3"
        s3 = { bucket = local.tempo_bucket; region = var.aws_region }
      }
    } : { trace = { backend = "local" } }
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

# Baseline policies — applied after Kyverno is ready
resource "kubectl_manifest" "kyverno_disallow_privileged" {
  depends_on = [helm_release.kyverno]
  yaml_body  = yamlencode({
    apiVersion = "kyverno.io/v1"
    kind       = "ClusterPolicy"
    metadata   = { name = "disallow-privileged-containers" }
    spec = {
      validationFailureAction = "Enforce"
      rules = [{
        name  = "check-privileged"
        match = { resources = { kinds = ["Pod"] } }
        validate = {
          message = "Privileged containers are not allowed."
          pattern = {
            spec = {
              containers = [{ "=(securityContext)" = { "=(privileged)" = "false | null" } }]
            }
          }
        }
      }]
    }
  })
}

resource "kubectl_manifest" "kyverno_require_non_root" {
  depends_on = [helm_release.kyverno]
  yaml_body  = yamlencode({
    apiVersion = "kyverno.io/v1"
    kind       = "ClusterPolicy"
    metadata   = { name = "require-non-root-user" }
    spec = {
      validationFailureAction = "Enforce"
      rules = [{
        name  = "check-runasnonroot"
        match = { resources = { kinds = ["Pod"] } }
        validate = {
          message = "Containers must not run as root. Set runAsNonRoot=true."
          pattern = {
            spec = {
              "=(securityContext)" = { runAsNonRoot = true }
            }
          }
        }
      }]
    }
  })
}

resource "kubectl_manifest" "kyverno_require_resource_limits" {
  depends_on = [helm_release.kyverno]
  yaml_body  = yamlencode({
    apiVersion = "kyverno.io/v1"
    kind       = "ClusterPolicy"
    metadata   = { name = "require-resource-limits" }
    spec = {
      validationFailureAction = "Warn"   # Warn first; switch to Enforce once all services comply
      rules = [{
        name  = "check-limits"
        match = { resources = { kinds = ["Pod"] } }
        validate = {
          message = "CPU and memory limits are required for all containers."
          pattern = {
            spec = {
              containers = [{
                resources = {
                  limits = {
                    cpu    = "?*"
                    memory = "?*"
                  }
                }
              }]
            }
          }
        }
      }]
    }
  })
}

resource "kubectl_manifest" "kyverno_disallow_latest_tag" {
  depends_on = [helm_release.kyverno]
  yaml_body  = yamlencode({
    apiVersion = "kyverno.io/v1"
    kind       = "ClusterPolicy"
    metadata   = { name = "disallow-latest-tag" }
    spec = {
      validationFailureAction = "Enforce"
      rules = [{
        name  = "check-image-tag"
        match = { resources = { kinds = ["Pod"] } }
        validate = {
          message = "Image tag 'latest' is not allowed. Pin to a specific tag."
          pattern = {
            spec = {
              containers = [{ image = "!*:latest" }]
            }
          }
        }
      }]
    }
  })
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

# ── CDM application namespaces with Istio sidecar injection ──────────────────
locals {
  cdm_namespaces = ["cdm-dev", "cdm-test", "cdm-prod"]
}

resource "kubernetes_namespace" "cdm" {
  for_each = toset(local.cdm_namespaces)
  depends_on = [helm_release.istiod]
  metadata {
    name = each.key
    labels = {
      "istio-injection" = "enabled"
    }
  }
}

# ── Karpenter NodePool + EC2NodeClass ─────────────────────────────────────────
resource "kubectl_manifest" "karpenter_node_class" {
  depends_on = [helm_release.karpenter]
  yaml_body  = yamlencode({
    apiVersion = "karpenter.k8s.aws/v1"
    kind       = "EC2NodeClass"
    metadata   = { name = "default" }
    spec = {
      amiSelectorTerms   = [{ alias = "al2023@latest" }]
      role               = var.karpenter_node_role_name
      subnetSelectorTerms = [{
        tags = { "karpenter.sh/discovery" = var.cluster_name }
      }]
      securityGroupSelectorTerms = [{
        tags = { "karpenter.sh/discovery" = var.cluster_name }
      }]
      blockDeviceMappings = [{
        deviceName = "/dev/xvda"
        ebs = {
          volumeSize          = "50Gi"
          volumeType          = "gp3"
          encrypted           = true
          deleteOnTermination = true
        }
      }]
      tags = { "karpenter.sh/discovery" = var.cluster_name }
    }
  })
}

resource "kubectl_manifest" "karpenter_node_pool" {
  depends_on = [kubectl_manifest.karpenter_node_class]
  yaml_body  = yamlencode({
    apiVersion = "karpenter.sh/v1"
    kind       = "NodePool"
    metadata   = { name = "default" }
    spec = {
      template = {
        spec = {
          nodeClassRef = {
            group = "karpenter.k8s.aws"
            kind  = "EC2NodeClass"
            name  = "default"
          }
          requirements = [
            { key = "karpenter.sh/capacity-type"; operator = "In";  values = ["spot", "on-demand"] },
            { key = "kubernetes.io/arch";         operator = "In";  values = ["amd64"] },
            { key = "karpenter.k8s.aws/instance-category"; operator = "In"; values = ["c", "m", "r"] },
            { key = "karpenter.k8s.aws/instance-generation"; operator = "Gt"; values = ["2"] },
          ]
        }
      }
      limits    = { cpu = "200" }
      disruption = {
        consolidationPolicy = "WhenEmptyOrUnderutilized"
        consolidateAfter    = "1m"
      }
    }
  })
}

# ── Istio Gateway (single shared ingress for all CDM services) ────────────────
resource "kubectl_manifest" "istio_gateway" {
  depends_on = [helm_release.istio_ingress]
  yaml_body  = yamlencode({
    apiVersion = "networking.istio.io/v1"
    kind       = "Gateway"
    metadata   = { name = "cdm-gateway"; namespace = local.istio_namespace }
    spec = {
      selector = { istio = "ingressgateway" }
      servers  = [
        {
          port     = { number = 80; name = "http"; protocol = "HTTP" }
          hosts    = ["*.${var.base_domain}"]
          tls      = { httpsRedirect = true }
        },
        {
          port     = { number = 443; name = "https"; protocol = "HTTPS" }
          hosts    = ["*.${var.base_domain}"]
          tls      = { mode = "SIMPLE"; credentialName = "cdm-tls-cert" }
        }
      ]
    }
  })
}

# VirtualService per external-facing service
locals {
  cdm_virtual_services = {
    shell            = { host = "portal.${var.base_domain}";    service = "shell";            port = 8080; namespace = "cdm-${var.environment}" }
    grants-mgmt-api  = { host = "api.${var.base_domain}";       service = "grants-mgmt-api";  port = 6099; namespace = "cdm-${var.environment}" }
    dsams-legacy     = { host = "dsams.${var.base_domain}";     service = "dsams-legacy";     port = 8090; namespace = "cdm-${var.environment}" }
    dsams-acl        = { host = "acl.${var.base_domain}";       service = "dsams-acl";        port = 8091; namespace = "cdm-${var.environment}" }
    data-platform    = { host = "analytics.${var.base_domain}"; service = "cdm-data-platform"; port = 8092; namespace = "cdm-${var.environment}" }
  }
}

resource "kubectl_manifest" "virtual_services" {
  for_each   = local.cdm_virtual_services
  depends_on = [kubectl_manifest.istio_gateway]
  yaml_body  = yamlencode({
    apiVersion = "networking.istio.io/v1"
    kind       = "VirtualService"
    metadata   = { name = each.key; namespace = local.istio_namespace }
    spec = {
      hosts    = [each.value.host]
      gateways = ["${local.istio_namespace}/cdm-gateway"]
      http     = [{
        route = [{
          destination = {
            host = "${each.value.service}.${each.value.namespace}.svc.cluster.local"
            port = { number = each.value.port }
          }
        }]
        timeout = "30s"
        retries = { attempts = 3; perTryTimeout = "10s"; retryOn = "5xx,reset,connect-failure" }
      }]
    }
  })
}

# ── Loki S3 backend (production) ──────────────────────────────────────────────
resource "aws_s3_bucket" "loki" {
  count         = var.loki_s3_bucket != "" ? 0 : 1
  bucket        = "${var.cluster_name}-loki-chunks"
  force_destroy = var.environment != "prod"
}

resource "aws_s3_bucket_server_side_encryption_configuration" "loki" {
  count  = var.loki_s3_bucket != "" ? 0 : 1
  bucket = aws_s3_bucket.loki[0].id
  rule { apply_server_side_encryption_by_default { sse_algorithm = "aws:kms" } }
}

locals {
  loki_bucket = var.loki_s3_bucket != "" ? var.loki_s3_bucket : (length(aws_s3_bucket.loki) > 0 ? aws_s3_bucket.loki[0].id : "")
}

# ── Tempo S3 backend (production) ─────────────────────────────────────────────
resource "aws_s3_bucket" "tempo" {
  count         = var.tempo_s3_bucket != "" ? 0 : 1
  bucket        = "${var.cluster_name}-tempo-traces"
  force_destroy = var.environment != "prod"
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tempo" {
  count  = var.tempo_s3_bucket != "" ? 0 : 1
  bucket = aws_s3_bucket.tempo[0].id
  rule { apply_server_side_encryption_by_default { sse_algorithm = "aws:kms" } }
}

locals {
  tempo_bucket = var.tempo_s3_bucket != "" ? var.tempo_s3_bucket : (length(aws_s3_bucket.tempo) > 0 ? aws_s3_bucket.tempo[0].id : "")
}

# ── AlertManager PrometheusRule — CDM platform signals ───────────────────────
resource "kubectl_manifest" "cdm_alerts" {
  depends_on = [helm_release.prometheus_stack]
  yaml_body  = yamlencode({
    apiVersion = "monitoring.coreos.com/v1"
    kind       = "PrometheusRule"
    metadata   = {
      name      = "cdm-platform-alerts"
      namespace = local.monitoring_namespace
      labels    = { release = "kube-prometheus-stack" }
    }
    spec = {
      groups = [
        {
          name = "cdm.api"
          rules = [
            {
              alert = "GrantsApiHighErrorRate"
              expr  = "sum(rate(istio_requests_total{destination_service=~\"grants-mgmt-api.*\",response_code=~\"5..\"}[5m])) / sum(rate(istio_requests_total{destination_service=~\"grants-mgmt-api.*\"}[5m])) > 0.05"
              for   = "5m"
              labels   = { severity = "critical"; team = "cdm-platform" }
              annotations = {
                summary     = "grants-mgmt-api error rate > 5%"
                description = "Error rate is {{ $value | humanizePercentage }} over the last 5 minutes."
              }
            },
            {
              alert = "GrantsApiHighLatency"
              expr  = "histogram_quantile(0.99, sum(rate(istio_request_duration_milliseconds_bucket{destination_service=~\"grants-mgmt-api.*\"}[5m])) by (le)) > 2000"
              for   = "10m"
              labels = { severity = "warning"; team = "cdm-platform" }
              annotations = {
                summary     = "grants-mgmt-api P99 latency > 2s"
                description = "P99 latency is {{ $value }}ms."
              }
            }
          ]
        },
        {
          name = "cdm.pods"
          rules = [
            {
              alert = "PodCrashLooping"
              expr  = "rate(kube_pod_container_status_restarts_total{namespace=~\"cdm-.*\"}[15m]) * 60 * 15 > 5"
              for   = "5m"
              labels = { severity = "critical"; team = "cdm-platform" }
              annotations = {
                summary     = "Pod {{ $labels.pod }} is crash-looping"
                description = "{{ $labels.pod }} in {{ $labels.namespace }} has restarted {{ $value }} times."
              }
            },
            {
              alert = "PodNotReady"
              expr  = "sum by (pod, namespace) (kube_pod_status_phase{namespace=~\"cdm-.*\", phase=~\"Pending|Unknown\"}) > 0"
              for   = "15m"
              labels = { severity = "warning"; team = "cdm-platform" }
              annotations = {
                summary     = "Pod {{ $labels.pod }} not ready for 15m"
                description = "Pod {{ $labels.pod }} in {{ $labels.namespace }} has been {{ $labels.phase }} for 15 minutes."
              }
            }
          ]
        },
        {
          name = "cdm.storage"
          rules = [{
            alert = "PVCUsageHigh"
            expr  = "kubelet_volume_stats_used_bytes{namespace=~\"cdm-.*\"} / kubelet_volume_stats_capacity_bytes{namespace=~\"cdm-.*\"} > 0.8"
            for   = "5m"
            labels = { severity = "warning"; team = "cdm-platform" }
            annotations = {
              summary     = "PVC {{ $labels.persistentvolumeclaim }} > 80% full"
              description = "{{ $value | humanizePercentage }} used in {{ $labels.namespace }}/{{ $labels.persistentvolumeclaim }}."
            }
          }]
        },
        {
          name = "cdm.messaging"
          rules = [{
            alert = "RabbitMQQueueDepthHigh"
            expr  = "sum by (queue) (rabbitmq_queue_messages{queue=~\"app\\.grants\\..*\"}) > 1000"
            for   = "10m"
            labels = { severity = "warning"; team = "cdm-platform" }
            annotations = {
              summary     = "RabbitMQ queue {{ $labels.queue }} depth > 1000"
              description = "{{ $value }} messages pending. ACL bridge or data platform may be behind."
            }
          }]
        }
      ]
    }
  })
}

# ── Grafana CDM dashboard ConfigMap (inline JSON — no Helm templating) ────────
resource "kubernetes_config_map" "cdm_grafana_dashboard" {
  depends_on = [helm_release.prometheus_stack]
  metadata {
    name      = "cdm-platform-dashboard"
    namespace = local.monitoring_namespace
    labels    = { grafana_dashboard = "1" }
  }
  data = {
    "cdm-platform.json" = file("${path.module}/dashboards/cdm-platform.json")
  }
}
