#!/usr/bin/env bash
# =============================================================================
# deploy.sh — wrapper git + ansible.
#
# Diferenças para a versão antiga:
#   - set -euo pipefail: erro em qualquer etapa aborta em vez de seguir
#   - sem `git add .` cego: foi exatamente esse padrão que commitou o token
#     da Cloudflare no histórico público
#   - o playbook é validado contra uma lista, não interpolado direto no
#     caminho (./deploy.sh ../../qualquer/coisa deixa de funcionar)
#   - --check obrigatório antes de aplicar, com confirmação explícita
# =============================================================================
set -euo pipefail

readonly VALID_PLAYBOOKS=(setup services update diag)
readonly REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    echo "Uso: $0 <playbook> [--limit <grupo>] [--yes]"
    echo "Playbooks: ${VALID_PLAYBOOKS[*]}"
    echo "Grupos:    prod, lab (padrão: lab)"
    exit 1
}

[[ $# -ge 1 ]] || usage

PLAYBOOK="$1"; shift
LIMIT="lab"
ASSUME_YES=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --limit) LIMIT="$2"; shift 2 ;;
        --yes)   ASSUME_YES=1; shift ;;
        *)       usage ;;
    esac
done

# Whitelist: o argumento nunca é usado para montar caminho arbitrário.
valid=0
for p in "${VALID_PLAYBOOKS[@]}"; do
    [[ "$PLAYBOOK" == "$p" ]] && valid=1
done
[[ $valid -eq 1 ]] || { echo "Playbook inválido: $PLAYBOOK"; usage; }

cd "$REPO_DIR"

# --- Guarda de segredos ------------------------------------------------------
# Roda antes de qualquer commit. Se o gitleaks não estiver instalado, avisa
# em vez de fingir que verificou.
if command -v gitleaks >/dev/null 2>&1; then
    echo ">> Varrendo segredos..."
    gitleaks detect --no-banner --redact || {
        echo "!! gitleaks encontrou possíveis segredos. Abortando."
        exit 1
    }
else
    echo ">> AVISO: gitleaks não instalado; varredura de segredos pulada."
    echo "   Instale com: brew install gitleaks"
fi

# --- Git ---------------------------------------------------------------------
if ! git diff --quiet || ! git diff --cached --quiet; then
    echo ">> Alterações não commitadas:"
    git status --short
    echo
    read -rp "Mensagem de commit (vazio = não commitar): " COMMIT_MSG
    if [[ -n "$COMMIT_MSG" ]]; then
        # -u: só arquivos já rastreados + os explicitamente adicionados.
        # Nunca `git add .`.
        git add -u
        git commit -m "$COMMIT_MSG"
        git push origin main
    fi
fi

# --- Senha do vault, pedida UMA vez ------------------------------------------
# Sem isto o script pediria a senha duas vezes (na simulação e na aplicação).
# O arquivo temporário vive em /tmp com modo 0600 e é apagado na saída do
# script, inclusive se ele for interrompido — é o que o `trap` garante.
VAULT_FILE="$(mktemp)"
chmod 600 "$VAULT_FILE"
trap 'rm -f "$VAULT_FILE"' EXIT INT TERM

read -rsp "Senha do ansible-vault: " VAULT_PASS; echo
printf '%s' "$VAULT_PASS" > "$VAULT_FILE"
unset VAULT_PASS

# --- Simulação obrigatória ---------------------------------------------------
# Rodar --check antes de aplicar não é burocracia: é a diferença entre ver o
# que vai mudar e descobrir depois.
echo ">> Simulando (--check --diff) em '$LIMIT'..."
ansible-playbook "playbooks/${PLAYBOOK}.yml" \
    --limit "$LIMIT" --check --diff --vault-password-file "$VAULT_FILE" || {
        echo "!! Simulação falhou. NADA foi aplicado."
        exit 1
    }

if [[ $ASSUME_YES -eq 0 ]]; then
    echo
    read -rp "Aplicar de verdade em '$LIMIT'? (digite 'sim'): " CONFIRM
    [[ "$CONFIRM" == "sim" ]] || { echo "Cancelado."; exit 0; }
fi

echo ">> Aplicando..."
ansible-playbook "playbooks/${PLAYBOOK}.yml" --limit "$LIMIT" \
    --vault-password-file "$VAULT_FILE"
