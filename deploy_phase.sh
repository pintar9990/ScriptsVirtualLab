#!/bin/bash
cd "$(dirname "$0")"
# Cargar configuración central
CONFIG_FILE="./exam_config.sh"
if [ ! -f "$CONFIG_FILE" ]; then
    echo -e "\033[0;31m[ERROR]\033[0m No se encuentra $CONFIG_FILE"
    exit 1
fi
source "$CONFIG_FILE"

if [ "$EUID" -ne 0 ]; then 
    log_error "Ejecuta como root: sudo $0"
    exit 1
fi

SCRIPTS=(
    "./SSH_Generator.sh"
    "./generate_users.sh"
    "./deploy_ova.sh"
)

for script in "${SCRIPTS[@]}"; do
    echo "========================================"
    echo "Ejecutando: $(basename $script)"
    echo "========================================"
    
    if [ -f "$script" ] && [ -x "$script" ]; then
        "$script" "$@"
        echo ""
    else
        echo "Error: No se puede ejecutar $script"
        exit 1
    fi
done

echo "✅ Todos los scripts completados"
