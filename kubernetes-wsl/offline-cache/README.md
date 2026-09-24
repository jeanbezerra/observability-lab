# Cache de contingência

Esta pasta recebe bundles gerados por `prepare-offline-bundle.sh`. Os arquivos
binários e pacotes são ignorados pelo Git; somente este README é versionado.

O cache contém:

- pacotes `.deb` e dependências para o host, containerd e Kubernetes;
- chave do repositório Kubernetes;
- arquivo oficial do Helm;
- manifesto oficial do Flannel;
- charts oficiais do Envoy Gateway.

Imagens de contêiner não são armazenadas. `kubeadm`, Flannel, Headlamp e
Envoy continuam baixando suas imagens pelos registries durante a instalação.

Cada diretório possui `SHA256SUMS`. O preflight e os instaladores recusam um
cache incompleto, corrompido, de outra arquitetura ou de versões diferentes.
