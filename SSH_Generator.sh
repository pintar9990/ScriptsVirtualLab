#!/bin/bash
cd "$(dirname "$0")"
# Cargar configuración central
CONFIG_FILE="./exam_config.sh"
if [ ! -f "$CONFIG_FILE" ]; then
    echo -e "\033[0;31m[ERROR]\033[0m No se encuentra $CONFIG_FILE"
    exit 1
fi

source "$CONFIG_FILE"


LOG_DIR="/tmp/ssh_key_copy_logs_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$LOG_DIR"

# ===========================================
# VARIABLES GLOBALES PARA GESTIÓN DE ERRORES
# ===========================================
declare -a FAILED_IPS
declare -a FAILED_IDS
declare -a NOT_FOUND_IDS
declare -a FOUND_IDS
 

# Lock file para condiciones de carrera
LOCK_FILE="/tmp/ssh_key_copy_$$.lock"
exec 200>"$LOCK_FILE"

# Funciones protegidas con lock
add_to_failed() {
    local ip=$1
    local ids=$2
    flock -x 200
    FAILED_IPS+=("$ip")
    FAILED_IDS+=("$ids")
    flock -u 200
}

increment_success() {
    flock -x 200
    EXITOS=$((EXITOS + 1))
    flock -u 200
}

increment_failed() {
    flock -x 200
    FALLOS=$((FALLOS + 1))
    flock -u 200
}

# ===========================================
# VERIFICACIONES 
# ===========================================
# Solicitar contraseña de root de forma segura


if [ "$EUID" -ne 0 ]; then 
    log_error "Ejecuta como root: sudo $0"
    exit 1
fi

if [ ! -f "$HOSTS_FILE" ]; then
    log_error "No se encuentra $HOSTS_FILE"
    exit 1
fi

echo -n "Introduce la contraseña de root para los equipos remotos: "
read -s ROOT_PASS
echo  # Salto de línea después de la entrada oculta

# Verificar que no esté vacía
if [ -z "$ROOT_PASS" ]; then
    log_error "No se introdujo ninguna contraseña."
    exit 1
fi

# Si hay argumentos, usar solo esos IDs
declare -a TARGET_IDS=("$@")

# ===========================================
# CREAR CLAVES SSH SI NO EXISTEN
# ===========================================
if [ ! -f /root/.ssh/id_rsa ]; then
    log_info "Generando claves SSH..."
    ssh-keygen -t rsa -b 4096 -N "" -f /root/.ssh/id_rsa -q
    log_info "✅ Claves generadas"
fi

# ===========================================
# FUNCIÓN PARA COPIAR CLAVE
# ===========================================
copiar_clave() {
    local IP=$1
    local ID=$2
    
    log_info "Copiando clave a: $IP (ID: ${ID:-N/A})"
    
    if sshpass -p "$ROOT_PASS" ssh-copy-id -o StrictHostKeyChecking=accept-new "root@$IP"; then
        log_info "✅ Éxito en $IP"
        return 0
    else
        log_error "❌ Fallo en $IP"
        return 1
    fi
}

show_progress() {
    local current=$1
    local total=$2
    local width=50
    local percent=$((current * 100 / total))
    local progress=$((current * width / total))
    
    printf "\r["
    for ((i=0; i<width; i++)); do
        if [ $i -lt $progress ]; then
            printf "▓"
        else
            printf "░"
        fi
    done
    printf "] %d%% (%d/%d)" $percent $current $total
}

# ===========================================
# EJECUCIÓN PRINCIPAL
# ===========================================
log_info "COPIANDO CLAVE SSH A HOSTS REMOTOS"
log_info "========================================"

# Contadores
TOTAL=0
EXITOS=0
FALLOS=0
PROCESADOS=0

# Verificar qué IDs del archivo coinciden con los especificados
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

# Arrays para control de concurrencia
declare -a PIDS
declare -i CURRENT_JOBS=0
declare -i PROCESSED_COUNT=0

# Función para esperar que haya espacio para más jobs
wait_for_slot() {
    while [ $CURRENT_JOBS -ge $MAX_WORKERS ]; do
        # Esperar a que cualquier job termine
        wait -n
        CURRENT_JOBS=$((CURRENT_JOBS - 1))
        
        # Procesar resultados de los jobs que terminaron
        for i in "${!PIDS[@]}"; do
            pid="${PIDS[$i]}"
            if ! kill -0 "$pid" 2>/dev/null; then
                # El proceso terminó
                if wait "$pid" 2>/dev/null; then
                    increment_success
                else
                    increment_failed
                    if [ -f "$LOG_DIR/pid_${pid}.info" ]; then
                        read -r REAL_IP REAL_IDS < "$LOG_DIR/pid_${pid}.info"
                        add_to_failed "$REAL_IP" "$REAL_IDS"
                        rm "$LOG_DIR/pid_${pid}.info"
                    fi
                fi
                PROCESSED_COUNT=$((PROCESSED_COUNT + 1))
                unset "PIDS[$i]"
            fi
        done
        # Reindexar array
        PIDS=("${PIDS[@]}")
        show_progress $PROCESSED_COUNT $PROCESADOS
    done
}

# Procesamos el archivo
while IFS= read -r LINE; do
    # Saltar líneas vacías y comentarios
    [[ -z "$LINE" ]] && continue
    [[ "$LINE" =~ ^#.* ]] && continue
    
    IP="${LINE%%:*}"
    ID="${LINE#*:}"
    
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
    
    # Esperar si ya tenemos el máximo de workers
    wait_for_slot
    
    # Lanzar la copia de clave en background
    (
        exec < /dev/null
        if copiar_clave "$IP" "$ID"; then
            exit 0
        else
            exit 1
        fi
    ) &
    
    PID=$!
    PIDS+=($PID)
    CURRENT_JOBS=$((CURRENT_JOBS + 1))
    
    # Guardar información del host para el PID
    echo "$IP $ID" > "$LOG_DIR/pid_${PID}.info"
    
done < "$HOSTS_FILE"

# Esperar a que todos los jobs restantes terminen
echo ""
echo "Esperando a que todos los hosts terminen..."
while [ ${#PIDS[@]} -gt 0 ]; do
    wait -n
    CURRENT_JOBS=$((CURRENT_JOBS - 1))
    for i in "${!PIDS[@]}"; do
        pid="${PIDS[$i]}"
        if ! kill -0 "$pid" 2>/dev/null; then
            if wait "$pid" 2>/dev/null; then
                increment_success
            else
                increment_failed
                if [ -f "$LOG_DIR/pid_${pid}.info" ]; then
                    read -r REAL_IP REAL_IDS < "$LOG_DIR/pid_${pid}.info"
                    add_to_failed "$REAL_IP" "$REAL_IDS"
                    rm "$LOG_DIR/pid_${pid}.info"
                fi
            fi
            PROCESSED_COUNT=$((PROCESSED_COUNT + 1))
            unset "PIDS[$i]"
        fi
    done
    # Reindexar array
    PIDS=("${PIDS[@]}")
    show_progress $PROCESSED_COUNT $PROCESADOS
    sleep 0.5
done

echo ""
log_info "========================================"

# ===========================================
# RESUMEN
# ===========================================
echo ""
log_info "RESUMEN FINAL"
log_info "========================================"
log_info "Total hosts en archivo: $TOTAL"

if [ ${#TARGET_IDS[@]} -gt 0 ]; then
    log_info "IDs especificados: ${#TARGET_IDS[@]}"
    log_info "IDs encontrados en archivo: ${#FOUND_IDS[@]}"
    if [ ${#NOT_FOUND_IDS[@]} -gt 0 ]; then
        log_warning "IDs no encontrados: ${#NOT_FOUND_IDS[@]}"
    fi
fi
log_info "Hosts procesados: $PROCESADOS"
log_info "Exitosos: $EXITOS"
log_info "Fallidos: $FALLOS"

if [ $FALLOS -gt 0 ]; then
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
elif [ $EXITOS -eq $PROCESADOS ]; then
    log_info "✅ ¡Todos los hosts procesados exitosamente!"
elif [ $EXITOS -eq 0 ]; then
    log_error "❌ ¡Todos los hosts fallaron!"
else
    log_warning "⚠️  Procesados $EXITOS de $PROCESADOS hosts"
fi

# Limpieza
rm -f "$LOCK_FILE" 2>/dev/null
rm -f "$LOG_DIR"/pid_*.info 2>/dev/null

echo ""
