#!/usr/bin/env bash

# shellcheck source=lib/common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

require_root
export DEBIAN_FRONTEND=noninteractive

kubernetes_packages=(kubelet kubeadm kubectl kubernetes-cni cri-tools)
kubernetes_repo_file="/etc/apt/sources.list.d/kubernetes.list"
kubernetes_repo_disabled_file="${kubernetes_repo_file}.disabled"
kubernetes_repo_line="deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${KUBERNETES_MINOR}/deb/ /"

kubernetes_packages_ready() {
  local command_name package_name
  for command_name in kubelet kubeadm kubectl crictl; do
    command -v "${command_name}" >/dev/null 2>&1 || {
      check_pending "comando ausente: ${command_name}."
      return 1
    }
  done
  for command_name in kubelet kubeadm kubectl crictl; do
    [[ "$(command_minor_version "${command_name}")" == "${KUBERNETES_MINOR}" ]] || {
      check_pending "${command_name} não está na versão ${KUBERNETES_MINOR}."
      return 1
    }
  done
  for package_name in "${kubernetes_packages[@]}"; do
    package_is_installed "${package_name}" || {
      check_pending "pacote Kubernetes ausente: ${package_name}."
      return 1
    }
  done
}

kubernetes_state_ok() {
  local package_name
  kubernetes_packages_ready || return 1
  for package_name in "${kubernetes_packages[@]}"; do
    apt-mark showhold | grep -Fxq "${package_name}" || {
      check_pending "pacote ${package_name} não está marcado como hold."
      return 1
    }
  done
  if artifact_mode_is_offline; then
    [[ ! -e "${kubernetes_repo_file}" ]] || {
      check_pending "repositório Kubernetes remoto ainda está habilitado no modo offline."
      return 1
    }
  else
    grep -Fqx "${kubernetes_repo_line}" "${kubernetes_repo_file}" 2>/dev/null || {
        check_pending "repositório Kubernetes ${KUBERNETES_MINOR} não está configurado."
        return 1
      }
    [[ -r /etc/apt/keyrings/kubernetes-apt-keyring.gpg ]] || {
      check_pending "chave do repositório Kubernetes não existe."
      return 1
    }
  fi
  grep -Fqx 'runtime-endpoint: unix:///run/containerd/containerd.sock' /etc/crictl.yaml 2>/dev/null || {
    check_pending "endpoint do crictl não está configurado."
    return 1
  }
  grep -Fqx "timeout: ${KUBERNETES_REQUEST_TIMEOUT_SECONDS}" /etc/crictl.yaml 2>/dev/null || {
    check_pending "timeout do crictl não corresponde a ${KUBERNETES_REQUEST_TIMEOUT_SECONDS}s."
    return 1
  }
  [[ "$(stat -c '%U:%G:%a' /etc/crictl.yaml 2>/dev/null)" == "root:root:644" ]] || {
    check_pending "permissões de /etc/crictl.yaml estão incorretas."
    return 1
  }
  systemctl is-enabled --quiet kubelet || {
    check_pending "kubelet não está habilitado no boot."
    return 1
  }
}

if check_requested "${1:-}"; then
  if kubernetes_state_ok; then
    exit 0
  fi
  exit 1
fi

for command_name in kubelet kubeadm kubectl; do
  if command -v "${command_name}" >/dev/null 2>&1 \
    && [[ "$(command_minor_version "${command_name}")" != "${KUBERNETES_MINOR}" ]]; then
    if [[ -r "${KUBECONFIG_ADMIN}" ]] \
      && kubectl --kubeconfig "${KUBECONFIG_ADMIN}" \
        --request-timeout="${KUBERNETES_REQUEST_TIMEOUT_SECONDS}s" get --raw=/readyz >/dev/null 2>&1; then
      die "${command_name} pertence a outro minor em um cluster ativo. Faça o upgrade Kubernetes de forma controlada antes de mudar KUBERNETES_MINOR para ${KUBERNETES_MINOR}."
    fi
    warn "instalação Kubernetes incompleta e incompatível detectada; os pacotes serão reinstalados pelo canal ${KUBERNETES_MINOR}."
    apt-mark unhold "${kubernetes_packages[@]}" >/dev/null 2>&1 || true
    removable_packages=()
    for package_name in "${kubernetes_packages[@]}"; do
      package_is_installed "${package_name}" && removable_packages+=("${package_name}")
    done
    if (( ${#removable_packages[@]} > 0 )); then
      apt-get remove -y "${removable_packages[@]}"
    fi
    break
  fi
done

if command -v crictl >/dev/null 2>&1 \
  && [[ "$(command_minor_version crictl)" != "${KUBERNETES_MINOR}" ]]; then
  warn "cri-tools não corresponde a ${KUBERNETES_MINOR}; somente esse utilitário será reinstalado."
  apt-mark unhold cri-tools >/dev/null 2>&1 || true
  package_is_installed cri-tools && apt-get remove -y cri-tools
fi

if artifact_mode_is_offline; then
  if [[ -e "${kubernetes_repo_file}" ]]; then
    mv -f -- "${kubernetes_repo_file}" "${kubernetes_repo_disabled_file}"
    log "Repositório remoto Kubernetes desabilitado em ${kubernetes_repo_disabled_file}."
  fi
  log "Modo offline: a chave e o repositório pkgs.k8s.io não serão consultados."
else
  log "Configurando o repositório oficial Kubernetes ${KUBERNETES_MINOR}."
  install -d -o root -g root -m 0755 /etc/apt/keyrings
  key_file="$(mktemp)"
  trap 'rm -f -- "${key_file}"' EXIT

  download_artifact \
    "https://pkgs.k8s.io/core:/stable:/${KUBERNETES_MINOR}/deb/Release.key" \
    "artifacts/kubernetes-${KUBERNETES_MINOR}-Release.key" "${key_file}"
  gpg --dearmor --yes --output /etc/apt/keyrings/kubernetes-apt-keyring.gpg "${key_file}"
  chmod 0644 /etc/apt/keyrings/kubernetes-apt-keyring.gpg

  printf '%s\n' "${kubernetes_repo_line}" >"${kubernetes_repo_file}"
  chmod 0644 "${kubernetes_repo_file}"
fi

if kubernetes_packages_ready; then
  log "Pacotes Kubernetes ${KUBERNETES_MINOR} já estão instalados corretamente; APT não será chamado."
else
  if artifact_mode_is_offline; then
    log "Tentando concluir localmente pacotes que foram instalados manualmente com dpkg."
    dpkg --configure -a || true
  fi
  if kubernetes_packages_ready; then
    log "Pacotes manuais configurados com sucesso; APT não será chamado."
  else
    apt-mark unhold "${kubernetes_packages[@]}" >/dev/null 2>&1 || true
    apt_install_with_cache kubernetes -y --reinstall --allow-change-held-packages \
      "${kubernetes_packages[@]}"
  fi
fi
apt-mark hold "${kubernetes_packages[@]}" >/dev/null
systemctl enable kubelet

cat >/etc/crictl.yaml <<EOF
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: ${KUBERNETES_REQUEST_TIMEOUT_SECONDS}
debug: false
EOF
chmod 0644 /etc/crictl.yaml

kubernetes_state_ok || die "os componentes Kubernetes foram instalados, mas a verificação do estado falhou."
log "Kubernetes instalado: $(kubeadm version -o short)."
