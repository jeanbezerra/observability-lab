# Exemplos opt-in do Gateway API

Estes manifestos **não são aplicados pelo instalador**. Eles servem como bases pequenas para os recursos exibidos no menu `Gateway (beta)` do Headlamp. Antes de aplicar, troque nomes, namespaces, portas e hostnames pelos da sua aplicação.

O instalador já cria:

- `GatewayClass/envoy-wsl`, aceita pelo Envoy Gateway;
- `Gateway/gateway-system/wsl-gateway`, com listener HTTP interno na porta `8080`;
- o dataplane Envoy como `Service` do tipo `ClusterIP`;
- CRDs `v1` do canal Standard para `Gateway`, `HTTPRoute`, `GRPCRoute`, `ReferenceGrant` e `BackendTLSPolicy`;
- CRD de extensão `gateway.envoyproxy.io/v1alpha1` para `BackendTrafficPolicy`.

## Ordem de uso

1. Crie seu `Deployment` e um `Service` `ClusterIP`.
2. Copie e edite `http-route.yaml` ou `grpc-route.yaml`.
3. Valide no servidor antes de persistir:

   ```bash
   kubectl apply --dry-run=server -f http-route.yaml
   ```

4. Aplique e confira as condições:

   ```bash
   kubectl apply -f http-route.yaml
   kubectl get httproute -A
   kubectl describe httproute app-http -n default
   ```

5. No Windows, abra e teste o túnel:

   ```bat
   windows\25-open-gateway-port.cmd Ubuntu-26.04 30080
   windows\45-test-gateway.cmd 30080
   ```

6. Ao terminar:

   ```bat
   windows\75-close-gateway-port.cmd Ubuntu-26.04 30080
   ```

Uma resposta `404` confirma que o Envoy respondeu, mas nenhuma rota combinou com a requisição. O exemplo `HTTPRoute` combina com o prefixo `/app`; teste-o no CMD com `curl.exe http://localhost:30080/app`.

## Para que serve cada arquivo

- `http-route.yaml`: encaminha HTTP por prefixo de caminho para um `Service`.
- `grpc-route.yaml`: encaminha chamadas gRPC para um `Service` compatível com HTTP/2.
- `reference-grant.yaml`: autoriza explicitamente uma rota do namespace `apps` a referenciar um `Service` no namespace `backend`.
- `backend-tls-policy.yaml`: exige TLS e valida o hostname do backend. O exemplo usa as CAs públicas do sistema; para CA privada, use uma referência a `ConfigMap` conforme a documentação do Gateway API.
- `backend-traffic-policy.yaml`: extensão do Envoy Gateway com circuit breaker aplicado a uma `HTTPRoute`.

`ReferenceGrant` deve existir no namespace do objeto referenciado, nunca no namespace da rota. `BackendTLSPolicy` e `BackendTrafficPolicy` também são criadas no namespace do alvo.

Não associe o Headlamp a esse Gateway. Neste laboratório ele usa login automático com `cluster-admin` e deve continuar acessível somente pelo túnel HTTPS administrativo separado.

