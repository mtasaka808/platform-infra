output "istio_ingress_hostname" {
  description = "NLB hostname for the Istio ingress gateway — use as CNAME for your domains"
  value       = "retrieve with: kubectl get svc istio-ingressgateway -n istio-system -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'"
}

output "grafana_url" {
  description = "Grafana UI (port-forward or expose via Istio Gateway)"
  value       = "kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80"
}

output "kiali_url" {
  description = "Kiali UI"
  value       = "kubectl port-forward -n istio-system svc/kiali 20001:20001"
}

output "tempo_url" {
  description = "Tempo query frontend"
  value       = "kubectl port-forward -n tracing svc/tempo-query-frontend 3100:3100"
}
