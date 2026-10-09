# Certificados de cada instalação

O projeto não distribui CAs de empresas ou ambientes. A confiança do Rancher é
definida usando a URL informada na instalação.

Use o trust store do sistema para CAs públicas. Para CA privada, forneça
`RANCHER_CA_FILE` com um arquivo PEM conferido, ou use a descoberta automática
e confirme o fingerprint com o administrador do servidor. Em execução sem
terminal, a descoberta exige `RANCHER_CA_FINGERPRINT` previamente conferido.

As CAs aprovadas automaticamente ficam fora do repositório, em
`BOOTSTRAP_STATE_DIR`, associadas à URL do Rancher. Uma mudança de URL não
reutiliza a confiança de outro servidor; uma rotação exige nova confirmação.
Não versione certificados ou perfis de um ambiente nesta pasta.

A CA do Headlamp é gerada na própria VM para seu IP/hostname e permanece
separada da CA do Rancher. Somente o certificado público do Headlamp deve ser
copiado aos clientes; as chaves privadas permanecem na VM.

Consulte [configuração genérica e registro](../README.md) para o fluxo completo.
