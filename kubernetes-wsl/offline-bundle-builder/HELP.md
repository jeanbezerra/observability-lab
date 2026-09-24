# Gerador do bundle offline

Esta pasta concentra o fluxo de criação e publicação do cache usado pelo
`kubernetes-wsl` em notebooks com acesso restrito aos repositórios de pacotes.
O bundle contém pacotes `.deb`, chave do repositório Kubernetes, Helm, manifesto
do Flannel e charts do Envoy Gateway. Imagens de contêiner não são incluídas.

## Estrutura

| Arquivo/diretório | Finalidade |
|---|---|
| `prepare-offline-bundle.sh` | baixa, verifica e empacota os artefatos |
| `bundle.env.example` | modelo dos overrides de versões, checksums e diretórios |
| `bundle.env` | configuração local opcional, ignorada pelo Git |
| `published-bundle.env` | nome, arquitetura e URL do bundle atualmente publicado |
| `dist/` | `.tar.gz` e `.sha256` gerados, ignorados pelo Git |
| `../offline-cache/` | cache expandido consumido pelos scripts de instalação |

O gerador parte das versões de `../.env.example`. Quando `bundle.env` existe,
seus valores substituem esses padrões. Ele nunca carrega o `../cluster.env`,
evitando que configurações do cluster local alterem uma publicação por acidente.

## Pré-requisitos

- Ubuntu 26.04 na mesma arquitetura que será distribuída (`amd64` ou `arm64`);
- execução como `root`/`sudo`;
- `apt-get`, `curl`, `sha256sum` e `tar`;
- acesso aos repositórios Ubuntu, `pkgs.k8s.io`, `get.helm.sh`, GitHub e
  `docker.io` para os charts OCI;
- espaço livre para os `.deb`, o cache expandido e o arquivo compactado.

As fontes APT habilitadas na máquina geradora são copiadas para um estado
temporário. Portanto, gere em Ubuntu 26.04 limpo e não use repositórios de outra
release ou arquitetura.

## 1. Usar as versões atuais

Nenhuma configuração adicional é necessária:

```bash
cd ~/kubernetes-wsl
sudo bash offline-bundle-builder/prepare-offline-bundle.sh
```

Se `offline-cache/ARQUITETURA` já existir, o script o preserva. Para substituir
somente o cache da arquitetura atual:

```bash
sudo bash offline-bundle-builder/prepare-offline-bundle.sh --force
```

`--force` não remove caches de outras arquiteturas, bundles publicados ou o
`cluster.env`.

## 2. Preparar novas versões

Crie a configuração local:

```bash
cd ~/kubernetes-wsl/offline-bundle-builder
cp bundle.env.example bundle.env
nano bundle.env
```

Atualize em conjunto:

- minor do Kubernetes;
- versão e SHA-256 do Flannel;
- versão e SHA-256 do Helm para cada arquitetura suportada;
- versões da Gateway API e do Envoy Gateway;
- SHA-256 dos dois charts OCI do Envoy Gateway.

Os checksums são obrigatórios e o gerador falha antes de publicar conteúdo
incompatível. Obtenha-os das releases oficiais ou baixe o artefato em uma área
temporária e execute:

```bash
sha256sum NOME_DO_ARQUIVO
```

Ao promover a nova matriz para o projeto, replique os mesmos valores em
`../.env.example` e nos padrões de `../scripts/lib/common.sh`. Um bundle cuja
matriz difere do `cluster.env` será corretamente rejeitado pelo preflight.

## 3. Saídas e validação

Após uma geração bem-sucedida:

```text
../offline-cache/amd64/                         cache expandido
dist/kubernetes-wsl-artifacts-...tar.gz         bundle publicável
dist/kubernetes-wsl-artifacts-...tar.gz.sha256  checksum publicável
```

Valide novamente antes de publicar:

```bash
cd ~/kubernetes-wsl/offline-bundle-builder/dist
sha256sum --check kubernetes-wsl-artifacts-*.tar.gz.sha256
tar -tzf kubernetes-wsl-artifacts-*.tar.gz | less
```

O arquivo deve conter apenas um diretório de arquitetura e, dentro dele,
`bundle.env`, `apt/`, `artifacts/` e `charts/`, todos com seus `SHA256SUMS`.

## 4. Publicar e ativar

Publique o `.tar.gz` e o `.sha256` no mesmo diretório HTTP/S3. Exemplo com AWS
CLI, ajustando o destino à conta responsável:

```bash
aws s3 cp dist/kubernetes-wsl-artifacts-ubuntu-26.04-v1.36-amd64.tar.gz \
  s3://BUCKET/CAMINHO/
aws s3 cp dist/kubernetes-wsl-artifacts-ubuntu-26.04-v1.36-amd64.tar.gz.sha256 \
  s3://BUCKET/CAMINHO/
```

Somente depois de confirmar que os dois objetos estão acessíveis, atualize
`published-bundle.env` com o nome, arquitetura e URL-base publicados. Esse
arquivo é lido por `../setup-offline-cache.sh`; centralizar os metadados aqui
evita alterar o downloader a cada release.

Teste o download em uma instalação descartável ou após mover temporariamente o
cache existente:

```bash
cd ~/kubernetes-wsl
bash setup-offline-cache.sh
```

O downloader valida o SHA-256, rejeita caminhos fora da arquitetura esperada e
confere todos os grupos internos antes de ativar o cache.

## Diagnóstico rápido

- **checksum divergente**: confirme que versão e arquitetura correspondem ao
  campo atualizado em `bundle.env`;
- **nenhum `.deb` baixado**: revise as fontes APT e a conectividade da máquina
  geradora;
- **chart OCI não encontrado**: confirme a versão do Envoy Gateway e acesso ao
  Docker Hub;
- **cache incompatível no preflight**: compare o `bundle.env` interno com o
  `cluster.env` usado na instalação;
- **cache já existe**: preserve-o ou repita conscientemente com `--force`.

Não coloque credenciais de proxy, AWS ou tokens em `bundle.env`. Use os
mecanismos de credenciais do sistema e revise o `.tar.gz` antes de compartilhá-lo.
