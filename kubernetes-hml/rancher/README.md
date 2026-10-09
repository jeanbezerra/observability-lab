# Registrar HML no Rancher externo

Esta variante instala Kubernetes com kubeadm e registra um cluster **Generic** em
um Rancher já existente em outra máquina. Não instala o servidor Rancher no cluster.
Workloads, projetos e RBAC podem ser administrados no Rancher; upgrades de Kubernetes,
nós e backups continuam sob responsabilidade do kubeadm. A referência verificada é
**Rancher v2.15.2**, cuja matriz certifica importação Kubernetes **1.34–1.36**.
Confira a versão real em **About** e a matriz da release antes de configurar outra versão.

No `cluster.env`, informe `RANCHER_URL=https://rancher.exemplo.interno` e
`RANCHER_VERSION=v2.15.2`. O nome precisa resolver e os Pods/agentes precisam alcançar
o Rancher por HTTPS, geralmente porta 443, inclusive com WebSocket no proxy externo.

1. No Rancher, abra **Cluster Management > Import Existing > Generic** e crie HML.
2. Configure a confiança dos agentes no servidor externo: com CA pública, use
   **Global Settings > agent-tls-mode > system-store**, ou configure `cacerts` também
   para usar `strict`. Com CA privada, use `strict` e publique a cadeia CA em `cacerts`
   conforme a instalação do Rancher. Não altere essa configuração global sem considerar
   os clusters já registrados.
3. A UI fornece uma URL única de importação. Salve seu conteúdo YAML em um arquivo
   local protegido na VM, por exemplo `/root/rancher-hml-import.yaml`, usando HTTPS
   validado. Para CA privada, `curl --cacert /root/rancher-ca.pem --output /root/rancher-hml-import.yaml`
   pode ser usado com a URL fornecida pela UI. Não use `--insecure` ou pipelines de execução.
   Proteja com `chmod 600 /root/rancher-hml-import.yaml`.
4. Configure `RANCHER_IMPORT_MANIFEST=/root/rancher-hml-import.yaml` no `cluster.env`.
   Para validar `/ping` com uma CA privada, informe também
   `RANCHER_CA_FILE=/root/rancher-ca.pem`.
5. Execute `sudo bash install-all.sh cluster.env` e confirme **Active** na UI do Rancher.

O YAML e a URL de importação contêm credenciais; mantenha-os fora do Git e dos logs.
A etapa 80 verifica o arquivo antes de aplicá-lo, confere `CATTLE_SERVER`, aguarda o
rollout e registra somente seu SHA-256. Não redireciona agentes de outro Rancher.
`RANCHER_CA_FILE` confere TLS no host da VM; ele **não** configura a confiança dos
agentes dentro dos containers. Um rollout pronto também não comprova conexão com o
Rancher: **Active** é a confirmação final no servidor externo.

Sem `RANCHER_IMPORT_MANIFEST`, a instalação valida `/ping` com TLS e informa
**PENDENTE** sem falhar quando o Rancher responde corretamente.
Se já existir um agente, verifica seu destino e rollout mesmo sem o arquivo. Nesse
caso, a variante conserva o registro existente e não executa uma nova importação.
O `--check` não consulta `/ping`; usa somente a API do cluster e o hash local.

O Flannel padrão preservado da variante WSL não aplica `NetworkPolicy`. Habilite
isolamento de projetos somente após adicionar um controlador de políticas compatível.

Para verificar regressões da etapa de registro sem rede, API ou privilégios de root,
execute `bash tests/rancher-registration.sh` a partir de `kubernetes-hml`.

Referências oficiais:

- [Matriz Rancher v2.15.2](https://www.suse.com/suse-rancher/support-matrix/all-supported-versions/rancher-v2-15-2/).
- [Registro e capacidades dos clusters Generic](https://ranchermanager.docs.rancher.com/how-to-guides/new-user-guides/kubernetes-clusters-in-rancher-setup/register-existing-clusters).
- [Agent TLS Enforcement](https://ranchermanager.docs.rancher.com/getting-started/installation-and-upgrade/installation-references/tls-settings).
- [CA privada e atualização dos agentes](https://ranchermanager.docs.rancher.com/getting-started/installation-and-upgrade/resources/update-rancher-certificate).
- [Políticas de rede no Flannel](https://github.com/flannel-io/flannel/blob/master/Documentation/netpol.md).
