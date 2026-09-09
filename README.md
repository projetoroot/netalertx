# NetAlertX Baremetal/VM - Debian 13

Instalação automatizada do **NetAlertX** em ambientes **Baremetal, VM ou LXC**, utilizando Debian 13 (Trixie).

O projeto foi desenvolvido para simplificar a implantação do NetAlertX em servidores Linux dedicados, automatizando a instalação das dependências, configuração dos serviços e validação do ambiente.

**Autor:** Diego Costa (@diegocostaroot) / Projeto Root (https://youtube.com/projetoroot) 

**Ano:** 2026

---

## Sobre o projeto

Este script automatiza a instalação do [NetAlertX](https://github.com/netalertx/NetAlertX) em uma instalação limpa do **Debian 13**.

A instalação configura automaticamente:

- Python e ambiente virtual
- Dependências do NetAlertX
- PHP 8.4 e PHP-FPM
- Nginx
- SQLite
- ARP-Scan
- Ferramentas de descoberta de rede
- Permissões e diretórios da aplicação
- Serviços `systemd`
- Runtime do NetAlertX
- Base OUI para identificação de fabricantes
- Proxy entre Nginx e a API do NetAlertX
- Health Check pós-instalação

A ideia é permitir que o servidor seja preparado de forma padronizada, reduzindo a quantidade de configurações manuais necessárias.

---

## Requisitos

### Sistema operacional

- Debian GNU/Linux 13 (Trixie)

### Arquitetura

- `amd64`

### Ambiente

Pode ser utilizado em:

- Baremetal
- Máquina virtual
- LXC

### Requisitos adicionais

- Acesso como `root`
- Acesso à Internet
- Acesso aos repositórios APT
- Acesso ao GitHub
- `systemd`
- Portas disponíveis para a interface Web e API

### Recursos recomendados

Os requisitos mínimos de CPU e memória não são definidos pelo script.

Como referência prática:

| Ambiente | CPU | RAM | Armazenamento |
|---|---:|---:|---:|
| Teste/Laboratório | 1 vCPU | 2 GB | 10 GB |
| Produção pequena | 2 vCPU | 4 GB | 20 GB |
| Produção maior | 4 vCPU | 8 GB | 30 GB+ |

Os recursos necessários podem variar conforme a quantidade de dispositivos monitorados, frequência das descobertas e plugins utilizados.

---

## Portas

Por padrão, o script utiliza:

| Serviço | Porta |
|---|---:|
| Interface Web | `20211` |
| API / GraphQL | `20212` |

As portas podem ser alteradas através das variáveis de ambiente.

Exemplo:

```bash
NETALERTX_UI_PORT=8080 NETALERTX_API_PORT=8081 ./install-netalertx-debian13.sh
```

---

# 🚀 Como Executar 
⚠️ **Instalação / Install**

Script de instalação 

Installation script

As instruções devem ser executadas como root, pois usuários comuns não têm acesso aos arquivos.

Instructions must be performed as `root`, as normal users do not have access to the files.

```bash
wget https://raw.githubusercontent.com/projetoroot/netalertx/refs/heads/main/install-netalertx-debian13.sh
chmod +x install-netalertx-debian13.sh
bash install-netalertx-debian13.sh
```
---
