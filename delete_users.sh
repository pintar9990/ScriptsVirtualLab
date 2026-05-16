#!/bin/bash
cd "$(dirname "$0")"
# Cargar configuración central
CONFIG_FILE="./exam_config.sh"
if [ ! -f "$CONFIG_FILE" ]; then
    echo -e "\033[0;31m[ERROR]\033[0m No se encuentra $CONFIG_FILE"
    exit 1
fi
source "$CONFIG_FILE"

# ===========================================
# VARIABLES GLOBALES PARA GESTIÓN DE ERRORES
# ===========================================
declare -a FAILED_IPS
declare -a FAILED_IDS
declare -a NOT_FOUND_IDS
declare -a FOUND_IDS

# ===========================================
# VERIFICACIONES INICIALES
# ===========================================

if [ "$EUID" -ne 0 ]; then 
    log_error "Ejecuta como root: sudo $0"
    exit 1
fi

# Verificar archivo de hosts
if [ ! -f "$HOSTS_FILE" ]; then
    log_error "No se encuentra $HOSTS_FILE"
    exit 1
fi

# Si hay argumentos, usar solo esos IDs
declare -a TARGET_IDS=("$@")

# ===========================================
# FUNCIÓN PARA ELIMINAR USUARIO
# ===========================================
process_host() {
    local HOST=$1
    local ID=$2
    
    echo "Procesando $HOST (ID: ${ID:-N/A})"
    
    # Comando SSH para eliminar usuario
    ssh -T "root@$HOST" << EOF
        if id '$EXAM_USER' &>/dev/null; then
            echo 'Usuario $EXAM_USER encontrado. Eliminando...'
            
            # Matar procesos del usuario (si los hay)
            pkill -u '$EXAM_USER' 2>/dev/null || true
            
            # Eliminar usuario y su home
            userdel -r '$EXAM_USER' 2>/dev/null
            
            if [ \$? -eq 0 ]; then
                echo 'Usuario $EXAM_USER eliminado correctamente.'
            else
                echo 'Error al eliminar el usuario $EXAM_USER.'
                exit 1
            fi
        else
            echo 'El usuario $EXAM_USER no existe en este host. Nada que eliminar.'
        fi
EOF
    
    return $?
}

# ===========================================
# EJECUCIÓN PRINCIPAL
# ===========================================
log_info "INICIANDO ELIMINACIÓN DE USUARIO '$EXAM_USER'"

if [ ${#TARGET_IDS[@]} -eq 0 ]; then
    log_info "Procesando TODOS los hosts del archivo"
else
    log_info "Procesando solo los hosts con IDs: ${TARGET_IDS[*]}"
fi
echo ""

# Contadores
TOTAL=0
SUCCESS=0
FAILED=0
PROCESADOS=0

# Primero, verificar qué IDs del archivo coinciden con los especificados
declare -a AVAILABLE_IDS

# Leer el archivo una vez para encontrar qué IDs están disponibles
while IFS= read -r HOST; do
    [[ -z "$HOST" ]] && continue
    [[ "$HOST" =~ ^#.* ]] && continue
    IP="${HOST%%:*}"
    IDS="${HOST#*:}"
    
    if [ "$IP" != "$IDS" ]; then
        AVAILABLE_IDS+=("$IDS")
    fi
done < "$HOSTS_FILE"

# Si se especificaron IDs, verificar cuáles existen
if [ ${#TARGET_IDS[@]} -gt 0 ]; then
    for TARGET_ID in "${TARGET_IDS[@]}"; do
        FOUND=false
        for AVAILABLE_ID in "${AVAILABLE_IDS[@]}"; do
            if [ "$TARGET_ID" = "$AVAILABLE_ID" ]; then
                FOUND=true
                FOUND_IDS+=("$TARGET_ID")
                break
            fi
        done
        
        if [ "$FOUND" = false ]; then
            NOT_FOUND_IDS+=("$TARGET_ID")
        fi
    done
fi

# Ahora procesamos el archivo
while IFS= read -r HOST; do
    # Saltar líneas vacías y comentarios
    [[ -z "$HOST" ]] && continue
    [[ "$HOST" =~ ^#.* ]] && continue
    
    IP="${HOST%%:*}"
    ID="${HOST#*:}"
    
    if [ "$IP" = "$ID" ]; then
        ID=""
    fi
    
    ((TOTAL++))
    
    # Si se especificaron IDs y este ID no está en la lista, saltar
    if [ ${#TARGET_IDS[@]} -gt 0 ]; then
        SKIP=true
        for TARGET_ID in "${TARGET_IDS[@]}"; do
            if [ "$ID" = "$TARGET_ID" ]; then
                SKIP=false
                break
            fi
        done
        
        if [ "$SKIP" = true ]; then
            continue
        fi
    fi
    
    ((PROCESADOS++))
    
    if process_host "$IP" "$ID"; then
        ((SUCCESS++))
        log_info "✅ $HOST completado"
    else
        ((FAILED++))
        FAILED_IPS+=("$IP")
        FAILED_IDS+=("$ID")
        log_error "❌ Error en $HOST"
    fi
    
done < "$HOSTS_FILE"

# ===========================================
# RESUMEN
# ===========================================
echo ""
echo "========================================"
log_info "RESUMEN FINAL"
echo "========================================"
log_info "Total hosts en archivo: $TOTAL"

if [ ${#TARGET_IDS[@]} -gt 0 ]; then
    log_info "IDs especificados: ${#TARGET_IDS[@]}"
    log_info "IDs encontrados en archivo: ${#FOUND_IDS[@]}"
    if [ ${#NOT_FOUND_IDS[@]} -gt 0 ]; then
        log_warning "IDs no encontrados: ${#NOT_FOUND_IDS[@]}"
    fi
fi
log_info "Hosts procesados: $PROCESADOS"
log_info "Exitosos: $SUCCESS"

if [ $FAILED -gt 0 ]; then
    log_error "Fallidos: $FAILED"
    echo ""
    log_error "HOSTS QUE FALLARON:"
    echo "----------------------------------------"
    
    # Mostrar lista de fallos con identificadores
    for i in "${!FAILED_IPS[@]}"; do
        IPS="${FAILED_IPS[$i]}"
        IDS="${FAILED_IDS[$i]}"
        
        if [ -n "$IDS" ]; then
            echo "  ❌ $IPS (ID: $IDS)"
        else
            echo "  ❌ $IPS"
        fi
    done
    
    echo "----------------------------------------"
fi

# Mostrar IDs no encontrados si los hay
if [ ${#NOT_FOUND_IDS[@]} -gt 0 ]; then
    echo ""
    log_warning "IDs ESPECIFICADOS PERO NO ENCONTRADOS EN EL ARCHIVO:"
    echo "----------------------------------------"
    for NOT_FOUND_ID in "${NOT_FOUND_IDS[@]}"; do
        echo "  ❓ $NOT_FOUND_ID"
    done
    echo "----------------------------------------"
fi

if [ $PROCESADOS -eq 0 ]; then
    if [ ${#NOT_FOUND_IDS[@]} -eq ${#TARGET_IDS[@]} ]; then
        log_error "❌ ¡Ninguno de los IDs especificados existe en el archivo!"
    else
        log_warning "⚠️  No se procesó ningún host"
    fi
elif [ $SUCCESS -eq $PROCESADOS ]; then
    log_info "✅ ¡Todos los hosts procesados exitosamente!"
elif [ $SUCCESS -eq 0 ]; then
    log_error "❌ ¡Todos los hosts fallaron!"
else
    log_warning "⚠️  Procesados $SUCCESS de $PROCESADOS hosts"
fi

echo ""
log_info "Usuario '$EXAM_USER' ha sido eliminado de los hosts procesados con éxito."
