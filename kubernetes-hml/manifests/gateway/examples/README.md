# Exemplos de Gateway API para HML

Os exemplos apontam para `gateway-system/hml-gateway`. Se você alterou esses valores em `cluster.env`, ajuste os `parentRefs`. Os nomes de namespaces, Services, portas e hosts de aplicação são exemplos e também precisam corresponder aos seus workloads.

- `http-route.yaml`: HTTPRoute para o listener `http`.
- `grpc-route.yaml`: GRPCRoute para o mesmo listener.
- `reference-grant.yaml`: autorização explícita de referência a backend de outro namespace.
- `backend-tls-policy.yaml`: validação TLS entre Envoy e backend.
- `backend-traffic-policy.yaml`: timeouts, retries e demais políticas do Envoy.

Esses exemplos não são instalados automaticamente. Para testar uma rota com hostname, use `curl -H 'Host: HOST_DA_ROTA' http://IP_DA_VM:30080/`. O Service externo do Gateway tem NodePort 30080; o Service gerenciado pelo Envoy permanece ClusterIP. HTTPS do Headlamp é publicado separadamente em 30443.
