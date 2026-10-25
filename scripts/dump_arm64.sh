#!/usr/bin/env bash

set -euo pipefail

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

PACKAGE_NAME=""
LOCAL_FILE=""
CLASS_FILTER=""
METHOD_FILTER=""
OUTPUT_FILE=""

usage() {
    cat <<EOF
Uso: $0 [OPÇÕES]

Modos de entrada (escolha um):
  -p, --package <pacote>     Nome do pacote instalado no aparelho (ex: br.com.seupacote.app)
  -f, --file <caminho>       Arquivo .dex ou .apk local para compilar em /data/local/tmp

Filtros e Saída:
  -c, --class <classe>       Nome completo da classe (ex: androidx.collection.CircularIntArray)
  -m, --method <metodo>      Nome do método para extrair (ex: indexOf) [Opcional]
  -o, --output <arquivo>     Arquivo de saída local (padrão: <classe>_<metodo>_arm64.asm)
  -h, --help                 Exibe esta ajuda

Exemplos:
  # 1. A partir de um app instalado:
  $0 -p br.com.seupacote.app -c androidx.collection.CircularIntArray -m indexOf

  # 2. A partir de um classes.dex ou APK local sem instalar:
  $0 -f build/outputs/apk/release/app-release.apk -c androidx.collection.CircularIntArray -m indexOf
EOF
    exit 1
}

# Parse de argumentos
while [[ $# -gt 0 ]]; do
    case "$1" in
        -p|--package) PACKAGE_NAME="$2"; shift 2 ;;
        -f|--file)    LOCAL_FILE="$2"; shift 2 ;;
        -c|--class)   CLASS_FILTER="$2"; shift 2 ;;
        -m|--method)  METHOD_FILTER="$2"; shift 2 ;;
        -o|--output)  OUTPUT_FILE="$2"; shift 2 ;;
        -h|--help)    usage ;;
        *) echo -e "${RED}Erro: Opção desconhecida: $1${NC}"; usage ;;
    esac
done

# Validações básicas
if [[ -z "$PACKAGE_NAME" && -z "$LOCAL_FILE" ]]; then
    echo -e "${RED}Erro: Informe um pacote (-p) ou um arquivo local (-f).${NC}"
    usage
fi

if [[ -z "$CLASS_FILTER" ]]; then
    echo -e "${RED}Erro: O filtro de classe (-c) é obrigatório.${NC}"
    usage
fi

#Verifica conexão ADB e arquitetura
if ! command -v adb >/dev/null 2>&1; then
    echo -e "${RED}Erro: 'adb' não encontrado no PATH.${NC}"
    exit 1
fi

DEVICE_Count=$(adb devices | grep -w "device" | wc -l)
if [[ "$DEVICE_Count" -eq 0 ]]; then
    echo -e "${RED}Erro: Nenhum dispositivo Android conectado via ADB.${NC}"
    exit 1
fi

ABI=$(adb shell getprop ro.product.cpu.abi | tr -d '\r')
echo -e "${CYAN}==> Dispositivo detectado com arquitetura: ${ABI}${NC}"

# Define nome padrão do arquivo de saída
SHORT_CLASS="${CLASS_FILTER##*.}"
if [[ -z "$OUTPUT_FILE" ]]; then
    if [[ -n "$METHOD_FILTER" ]]; then
        OUTPUT_FILE="${SHORT_CLASS}_${METHOD_FILTER}_arm64.txt"
    else
        OUTPUT_FILE="${SHORT_CLASS}_arm64.txt"
    fi
fi

# Monta argumentos de filtro do oatdump
OATDUMP_ARGS=("--class-filter=${CLASS_FILTER}")
if [[ -n "$METHOD_FILTER" ]]; then
    OATDUMP_ARGS+=("--method-filter=${METHOD_FILTER}")
fi

# ==============================================================================
# MODO 1: Pacote Instalado no Dispositivo
# ==============================================================================
if [[ -n "$PACKAGE_NAME" ]]; then
    echo -e "${CYAN}==> [1/3] Forçando compilação AOT (speed) para '${PACKAGE_NAME}'...${NC}"
    adb shell cmd package compile -m speed -f "$PACKAGE_NAME"

    echo -e "${CYAN}==> [2/3] Localizando arquivo .odex no dispositivo...${NC}"
    APK_PATH=$(adb shell pm path "$PACKAGE_NAME" | head -n 1 | cut -d':' -f2 | tr -d '\r')
    if [[ -z "$APK_PATH" ]]; then
        echo -e "${RED}Erro: Pacote '${PACKAGE_NAME}' não encontrado no dispositivo.${NC}"
        exit 1
    fi

    APP_DIR=$(dirname "$APK_PATH")
    ODEX_PATH="${APP_DIR}/oat/arm64/base.odex"

    # Verifica se o arquivo base.odex existe
    if ! adb shell ls "$ODEX_PATH" >/dev/null 2>&1; then
        echo -e "${RED}Erro: Arquivo ${ODEX_PATH} não encontrado. Verifique se o app não está em outra arquitetura.${NC}"
        exit 1
    fi

    echo -e "${GREEN}    Encontrado: ${ODEX_PATH}${NC}"
    echo -e "${CYAN}==> [3/3] Extraindo assembly com oatdump para '${OUTPUT_FILE}'...${NC}"
    adb shell oatdump --oat-file="$ODEX_PATH" "${OATDUMP_ARGS[@]}" > "$OUTPUT_FILE"

# ==============================================================================
# MODO 2: Arquivo .dex ou .apk Local Avulso (em /data/local/tmp)
# ==============================================================================
elif [[ -n "$LOCAL_FILE" ]]; then
    if [[ ! -f "$LOCAL_FILE" ]]; then
        echo -e "${RED}Erro: Arquivo local '${LOCAL_FILE}' não encontrado.${NC}"
        exit 1
    fi

    REMOTE_DEX="/data/local/tmp/temp_input_$(basename "$LOCAL_FILE")"
    REMOTE_OAT="/data/local/tmp/temp_output.oat"

    cleanup() {
        echo -e "${CYAN}==> Limpando arquivos temporários em /data/local/tmp/...${NC}"
        adb shell rm -f "$REMOTE_DEX" "$REMOTE_OAT" 2>/dev/null || true
    }
    trap cleanup EXIT

    echo -e "${CYAN}==> [1/3] Enviando '${LOCAL_FILE}' para o dispositivo...${NC}"
    adb push "$LOCAL_FILE" "$REMOTE_DEX" >/dev/null

    echo -e "${CYAN}==> [2/3] Executando dex2oat (--compiler-filter=speed --instruction-set=arm64)...${NC}"
    adb shell dex2oat \
        --dex-file="$REMOTE_DEX" \
        --oat-file="$REMOTE_OAT" \
        --instruction-set=arm64 \
        --compiler-filter=speed

    echo -e "${CYAN}==> [3/3] Extraindo assembly com oatdump para '${OUTPUT_FILE}'...${NC}"
    adb shell oatdump --oat-file="$REMOTE_OAT" "${OATDUMP_ARGS[@]}" > "$OUTPUT_FILE"
fi

# ==============================================================================
# Resumo de Auditoria Rápida
# ==============================================================================
if [[ -s "$OUTPUT_FILE" ]]; then
    echo -e "\n${GREEN}✔ Extração concluída com sucesso! Arquivo salvo em: ${OUTPUT_FILE}${NC}"
    echo -e "${YELLOW}--- Resumo Rápido de Auditoria ARM64 ---${NC}"

    # Conta chamadas de sub-rotina (bl) e acessos à memória (ldr/str)
    BL_COUNT=$(grep -E "^\s+0x[0-9a-f]+:\s+[0-9a-f]+\s+bl\s+" "$OUTPUT_FILE" | wc -l || true)
    LDR_COUNT=$(grep -E "^\s+0x[0-9a-f]+:\s+[0-9a-f]+\s+ldr" "$OUTPUT_FILE" | wc -l || true)

    echo -e "• Instruções 'bl' (Branch with Link / chamadas externas ou alocações): ${BL_COUNT}"
    echo -e "• Instruções 'ldr' (leituras de memória): ${LDR_COUNT}"
    echo -e "\nPara visualizar direto no terminal com destaque para o bloco CODE:"
    echo -e "  ${CYAN}grep -A 45 \"CODE:\" \"${OUTPUT_FILE}\"${NC}"
else
    echo -e "${RED}Aviso: O arquivo de saída está vazio. Verifique se o nome da classe/método não foi ofuscado pelo R8.${NC}"
fi
