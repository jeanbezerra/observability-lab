# Cache de artefatos HML

`setup-offline-cache.sh` importa o bundle publicado e valida SHA-256. O cache por arquitetura é ignorado pelo Git. `ARTIFACT_MODE=offline` instala artefatos deste cache sem consultar repositórios de pacotes; imagens e Rancher permanecem externos.

O bundle WSL já publicado conserva seu nome original. Ele corresponde ao Ubuntu 26.04 e às versões desta variante; para uma VM sem `python3`, gere um bundle com `../offline-bundle-builder/prepare-offline-bundle.sh` ou instale previamente o pacote. Não copie `cluster.env`, chaves ou credenciais para o cache.
