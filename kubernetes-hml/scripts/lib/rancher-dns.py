#!/usr/bin/env python3
"""Descobre upstreams DNS do ambiente e planeja patches mínimos do CoreDNS."""

import hashlib
import ipaddress
import json
from pathlib import Path
import re
import queue
import secrets
import socket
import struct
import sys
import threading
import time
from urllib.parse import urlsplit


BEGIN = "# BEGIN kubernetes-hml rancher-dns"
END = "# END kubernetes-hml rancher-dns"
ANNOTATION = "bootstrap.k8s.io/rancher-dns-sha256"


def reject(message):
    raise ValueError(message)


def servers_from(value):
    servers = []
    for item in value.split():
        try:
            address = ipaddress.ip_address(item)
        except ValueError:
            reject("RANCHER_DNS_SERVERS deve conter somente IPv4/IPv6 separados por espaço.")
        if getattr(address, "scope_id", None) is not None:
            reject("DNS IPv6 deve ser um endereço alcançável sem identificador de interface.")
        effective = getattr(address, "ipv4_mapped", None) or address
        if (effective.is_unspecified or effective.is_multicast or effective.is_loopback
                or (address.version == 6 and address.is_link_local)
                or (effective.version == 4 and int(effective) == 0xFFFFFFFF)):
            reject("RANCHER_DNS_SERVERS contém um endereço que não pode ser usado como DNS dos Pods.")
        if str(address) not in servers:
            servers.append(str(address))
    if not servers or len(servers) > 15:
        reject("Informe de 1 a 15 servidores IPv4/IPv6 em RANCHER_DNS_SERVERS.")
    return servers


def hostname_from(url):
    parsed = urlsplit(url)
    hostname = parsed.hostname or ""
    if (parsed.scheme != "https" or parsed.username or parsed.password or parsed.query
            or parsed.fragment or parsed.path not in ("", "/") or not hostname):
        reject("RANCHER_URL deve ser uma URL HTTPS do Rancher, sem credenciais, caminho ou query.")
    try:
        port = parsed.port
    except ValueError:
        reject("Porta HTTPS do Rancher inválida.")
    if port is not None and not 1 <= port <= 65535:
        reject("Porta HTTPS do Rancher inválida.")
    try:
        ipaddress.ip_address(hostname)
    except ValueError:
        if len(hostname) > 253 or any(
            not re.fullmatch(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?", label)
            for label in hostname.split(".")
        ):
            reject("Hostname do Rancher inválido para o bloco DNS.")
    else:
        reject("RANCHER_DNS_SERVERS exige RANCHER_URL com hostname DNS; uma URL com IP não precisa de DNS.")
    return hostname.lower()


def url_uses_ip(url):
    """IP literal não requer consulta ou alteração de DNS."""
    parsed = urlsplit(url)
    try:
        ipaddress.ip_address(parsed.hostname or "")
    except ValueError:
        hostname_from(url)
        return False
    return True


def resolver_candidates(paths=None):
    # systemd-resolved publica os upstreams reais neste arquivo; 127.0.0.53
    # em /etc/resolv.conf não é alcançável a partir dos Pods. A ordem do sistema
    # é preservada. Nenhum provedor DNS externo é introduzido pelo instalador.
    paths = paths or [Path("/run/systemd/resolve/resolv.conf"), Path("/etc/resolv.conf")]
    for path in paths:
        candidates = []
        try:
            lines = Path(path).read_text(encoding="utf-8").splitlines()
        except OSError:
            continue
        for line in lines:
            fields = line.split("#", 1)[0].split(";", 1)[0].split()
            if len(fields) >= 2 and fields[0] == "nameserver":
                try:
                    server = servers_from(fields[1])[0]
                except ValueError:
                    continue
                if server not in candidates:
                    candidates.append(server)
        if candidates:
            return candidates[:15]
    reject("Nenhum upstream DNS alcançável pelos Pods foi encontrado nos arquivos resolv.conf da VM; informe RANCHER_DNS_SERVERS.")


def host_addresses(hostname):
    # O resolver NSS do host pode ter timeouts longos. A thread é daemon para
    # que um NSS travado não retenha o instalador depois do limite estabelecido.
    result = queue.Queue()

    def lookup():
        try:
            answers = socket.getaddrinfo(hostname, None, type=socket.SOCK_STREAM)
            result.put({str(ipaddress.ip_address(answer[4][0])) for answer in answers})
        except (OSError, ValueError):
            result.put(set())

    threading.Thread(target=lookup, daemon=True).start()
    try:
        addresses = result.get(timeout=10)
    except queue.Empty:
        addresses = set()
    if not addresses:
        reject("O próprio host não resolve o hostname Rancher; corrija o DNS da VM ou informe um hostname válido.")
    return addresses


def decode_name(message, offset):
    labels, seen, consumed = [], set(), None
    while True:
        if offset in seen or offset >= len(message):
            raise ValueError("Resposta DNS inválida.")
        seen.add(offset)
        size = message[offset]
        if size & 0xC0 == 0xC0:
            if offset + 1 >= len(message):
                raise ValueError("Resposta DNS inválida.")
            if consumed is None:
                consumed = offset + 2
            offset = ((size & 0x3F) << 8) | message[offset + 1]
            continue
        if size & 0xC0 or size > 63 or offset + 1 + size > len(message):
            raise ValueError("Resposta DNS inválida.")
        offset += 1
        if size == 0:
            return ".".join(labels).lower(), consumed if consumed is not None else offset
        labels.append(message[offset:offset + size].decode("ascii"))
        offset += size
        if len(labels) > 127:
            raise ValueError("Resposta DNS inválida.")


def parse_answers(message, transaction, hostname, qtype):
    if len(message) < 12:
        raise ValueError("Resposta DNS inválida.")
    identity, flags, questions, answer_count, _, _ = struct.unpack("!6H", message[:12])
    if identity != transaction or not flags & 0x8000 or flags & 0x7800 or questions != 1:
        raise ValueError("Resposta DNS inválida.")
    query_name, offset = decode_name(message, 12)
    if query_name != hostname or offset + 4 > len(message):
        raise ValueError("Resposta DNS inválida.")
    query_type, query_class = struct.unpack("!2H", message[offset:offset + 4])
    if query_type != qtype or query_class != 1:
        raise ValueError("Resposta DNS inválida.")
    if flags & 0xF:
        return set()
    offset += 4
    aliases, answers = {}, []
    for _ in range(answer_count):
        owner, offset = decode_name(message, offset)
        if offset + 10 > len(message):
            raise ValueError("Resposta DNS inválida.")
        record_type, record_class, _, size = struct.unpack("!HHIH", message[offset:offset + 10])
        offset += 10
        end = offset + size
        if end > len(message):
            raise ValueError("Resposta DNS inválida.")
        if record_class == 1 and record_type == 5:
            aliases[owner] = decode_name(message, offset)[0]
        elif record_class == 1 and record_type == qtype and size == (4 if record_type == 1 else 16):
            answers.append((owner, str(ipaddress.ip_address(message[offset:end]))))
        offset = end
    reachable = {hostname}
    for _ in range(len(aliases)):
        reachable.update(aliases[name] for name in list(reachable) if name in aliases)
    return {address for owner, address in answers if owner in reachable}


def recv_exact(connection, size):
    data = bytearray()
    while len(data) < size:
        part = connection.recv(size - len(data))
        if not part:
            raise OSError("Resposta DNS incompleta.")
        data.extend(part)
    return bytes(data)


def query_addresses(server, hostname, qtype, timeout=2):
    transaction = secrets.randbelow(65536)
    encoded_name = b"".join(bytes([len(label)]) + label.encode("ascii") for label in hostname.split(".")) + b"\0"
    request = struct.pack("!6H", transaction, 0x100, 1, 0, 0, 0) + encoded_name + struct.pack("!2H", qtype, 1)
    family = socket.AF_INET6 if ipaddress.ip_address(server).version == 6 else socket.AF_INET
    destination = (server, 53)
    with socket.socket(family, socket.SOCK_DGRAM) as connection:
        connection.settimeout(timeout)
        # connect também restringe a origem aceita da resposta UDP.
        connection.connect(destination)
        connection.send(request)
        response = connection.recv(65535)
    if len(response) >= 4 and struct.unpack("!H", response[2:4])[0] & 0x200:
        with socket.socket(family, socket.SOCK_STREAM) as connection:
            connection.settimeout(timeout)
            connection.connect(destination)
            connection.sendall(struct.pack("!H", len(request)) + request)
            size = struct.unpack("!H", recv_exact(connection, 2))[0]
            response = recv_exact(connection, size)
    return parse_answers(response, transaction, hostname, qtype)


def discover_servers(url, paths=None, lookup=None, query=None, allowed_families=None):
    hostname = hostname_from(url)
    reference = (lookup or host_addresses)(hostname)
    candidates = resolver_candidates(paths)
    selected = []
    deadline = time.monotonic() + 25
    for server in candidates:
        if allowed_families is not None and ipaddress.ip_address(server).version not in allowed_families:
            continue
        addresses = set()
        for qtype in (1, 28):
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                break
            try:
                addresses.update((query or query_addresses)(server, hostname, qtype, min(2, remaining)))
            except (OSError, ValueError, UnicodeError, struct.error):
                continue
        # Evita misturar resolutores que devolvem NXDOMAIN ou outra visão DNS.
        # Um override explícito continua disponível para DNS com balanceamento
        # cujas respostas mudam totalmente entre consultas.
        if addresses and addresses.issubset(reference):
            selected.append(server)
        if time.monotonic() >= deadline:
            break
    if not selected:
        reject("Nenhum DNS upstream da VM resolveu o Rancher de acordo com o host; confira split DNS/VPN ou informe RANCHER_DNS_SERVERS.")
    return selected


def managed_region(corefile):
    # Qualquer marker parecido, fora do formato exato, impede alteração incerta.
    occurrences = list(re.finditer(r"(?m)^.*(?:BEGIN|END) kubernetes-hml rancher-dns.*$", corefile))
    if not occurrences:
        return None
    begins = list(re.finditer(r"(?m)^" + re.escape(BEGIN) + r"\r?$", corefile))
    ends = list(re.finditer(r"(?m)^" + re.escape(END) + r"\r?$", corefile))
    if len(occurrences) != 2 or len(begins) != 1 or len(ends) != 1 or begins[0].end() >= ends[0].start():
        reject("Markers do bloco DNS HML estão incompletos, duplicados ou malformados; Corefile preservado.")
    begin, end = begins[0], ends[0]
    body = corefile[begin.end():end.start()]
    # Aceita drift nos valores, mas nunca apaga conteúdo desconhecido entre markers.
    shape = re.fullmatch(
        r"\s*([A-Za-z0-9.-]+):53\s*\{\s*errors\s+cache\s+\d+\s+"
        r"forward\s+\.\s+([0-9a-fA-F:. \t]+)\s*\{\s*"
        r"policy\s+(?:sequential|random|round_robin)\s*\}\s*\}\s*", body)
    if not shape:
        reject("Conteúdo do bloco DNS HML está malformado ou contém configuração desconhecida; Corefile preservado.")
    servers_from(shape[2])
    region_end = end.end()
    if corefile[region_end:region_end + 1] == "\n":
        region_end += 1
    return begin.start(), region_end


def build_plan(configmap, url, raw_servers, selection_mode="manual"):
    hostname = hostname_from(url)
    servers = servers_from(raw_servers)
    metadata = configmap.get("metadata", {})
    if (configmap.get("kind") != "ConfigMap" or metadata.get("name") != "coredns"
            or metadata.get("namespace") != "kube-system" or not metadata.get("resourceVersion")):
        reject("ConfigMap kube-system/coredns inválido ou sem resourceVersion; alteração recusada.")
    corefile = configmap.get("data", {}).get("Corefile")
    if not isinstance(corefile, str) or not corefile.strip():
        reject("ConfigMap CoreDNS não contém um Corefile legível; alteração recusada.")
    region = managed_region(corefile)
    outside = corefile if region is None else corefile[:region[0]] + corefile[region[1]:]
    # Não cria uma segunda definição para uma zona já personalizada pelo usuário.
    for match in re.finditer(r"(?m)^[^\n#{}]*\{", outside):
        for token in match[0][:-1].split():
            zone = token.lower().removesuffix(":53").removesuffix(".")
            if zone == hostname:
                reject("O hostname Rancher já possui configuração CoreDNS fora do bloco HML; Corefile preservado.")
    block = (f"{BEGIN}\n{hostname}:53 {{\n    errors\n    cache 30\n"
             f"    forward . {' '.join(servers)} {{\n        policy sequential\n    }}\n}}\n{END}\n")
    if region is None:
        separator = "" if corefile.endswith("\n\n") else ("\n" if corefile.endswith("\n") else "\n\n")
        desired = corefile + separator + block
    else:
        desired = corefile[:region[0]] + block + corefile[region[1]:]
    checksum = hashlib.sha256(block.encode("utf-8")).hexdigest()
    corefile_changed = desired != corefile
    annotation_changed = metadata.get("annotations", {}).get(ANNOTATION) != checksum
    patch = {"metadata": {"resourceVersion": metadata["resourceVersion"],
                          "annotations": {ANNOTATION: checksum}}}
    if corefile_changed:
        patch["data"] = {"Corefile": desired}
    state = {"format": 2, "hostname": hostname, "dns_servers": servers,
             "selection_mode": selection_mode,
             "managed_block_sha256": checksum}
    return {"corefile_changed": corefile_changed,
            "patch_needed": corefile_changed or annotation_changed,
            "patch": patch, "state": state}


def main():
    mode = sys.argv[1]
    if mode == "plan":
        source, target, url, servers = sys.argv[2:6]
        selection_mode = sys.argv[6] if len(sys.argv) > 6 else "manual"
        configmap = json.loads(Path(source).read_text(encoding="utf-8"))
        plan = build_plan(configmap, url, servers, selection_mode)
        Path(target).write_text(json.dumps(plan, ensure_ascii=False), encoding="utf-8")
    elif mode == "ip-url":
        print("true" if url_uses_ip(sys.argv[2]) else "false")
    elif mode == "discover":
        families = None
        if len(sys.argv) > 3:
            families = {ipaddress.ip_network(cidr, strict=False).version for cidr in sys.argv[3].split(",")}
        print(" ".join(discover_servers(sys.argv[2], allowed_families=families)))
    elif mode == "recorded":
        source, url = sys.argv[2:]
        state = json.loads(Path(source).read_text(encoding="utf-8"))
        if state.get("hostname") != hostname_from(url) or state.get("selection_mode") != "auto":
            reject("A seleção DNS automática ainda não foi reconciliada para o hostname Rancher atual.")
        print(" ".join(servers_from(" ".join(state["dns_servers"]))))
    elif mode == "extract":
        source, patch_file, state_file = sys.argv[2:]
        plan = json.loads(Path(source).read_text(encoding="utf-8"))
        Path(patch_file).write_text(json.dumps(plan["patch"], ensure_ascii=False), encoding="utf-8")
        Path(state_file).write_text(json.dumps(plan["state"], ensure_ascii=False) + "\n", encoding="utf-8")
        print(f"{str(plan['patch_needed']).lower()} {str(plan['corefile_changed']).lower()}")
    else:
        reject("Modo interno DNS inválido.")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, TypeError, OSError):
        # Não imprime payloads de ConfigMaps ou tracebacks com dados arbitrários.
        error = sys.exception()
        message = str(error) if isinstance(error, ValueError) and not isinstance(error, json.JSONDecodeError) else "Não foi possível interpretar o estado CoreDNS; alteração recusada."
        print(message, file=sys.stderr)
        sys.exit(1)
