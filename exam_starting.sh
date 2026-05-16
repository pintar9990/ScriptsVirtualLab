#!/bin/bash
cd "$(dirname "$0")"
# Cargar configuración central
CONFIG_FILE="./exam_config.sh"
if [ ! -f "$CONFIG_FILE" ]; then
    echo -e "\033[0;31m[ERROR]\033[0m No se encuentra $CONFIG_FILE"
    exit 1
fi
source "$CONFIG_FILE"

LOG_DIR="/tmp/exam_start_logs_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$LOG_DIR"

# Archivo para almacenar problemas de VMs entre procesos
VM_PROBLEMS_FILE="$LOG_DIR/vm_problems.txt"
> "$VM_PROBLEMS_FILE"  # Limpiar archivo

# ===========================================
# VARIABLES GLOBALES CON LOCKS
# ===========================================
declare -a FAILED_IPS
declare -a FAILED_IDS
declare -a NOT_FOUND_IDS
declare -a FOUND_IDS

declare -a HOSTS_WITH_VM_PROBLEMS
declare -a HOSTS_VM_FAILURE_DETAILS

# Contadores protegidos
TOTAL_PROCESSED=0
SUCCESS_COUNT=0
FAILED_COUNT=0

# Locks para evitar condiciones de carrera
MAIN_LOCK_FILE="/tmp/exam_main_lock_$$.lock"
exec 201>"$MAIN_LOCK_FILE"

VM_PROBLEMS_LOCK_FILE="/tmp/exam_vm_lock_$$.lock"
exec 202>"$VM_PROBLEMS_LOCK_FILE"

# ===========================================
# FUNCIONES PROTEGIDAS CON LOCKS
# ===========================================
add_to_failed() {
    local ip=$1
    local id=$2
    flock -x 201
    FAILED_IPS+=("$ip")
    FAILED_IDS+=("$id")
    flock -u 201
}

# Función para añadir problemas de VMs a un archivo compartido
add_vm_problem_to_file() {
    local host_info=$1
    local failure_detail=$2
    flock -x 202
    echo "${host_info}|${failure_detail}" >> "$VM_PROBLEMS_FILE"
    flock -u 202
}

# Función para leer problemas de VMs desde el archivo
read_vm_problems() {
    if [ -f "$VM_PROBLEMS_FILE" ] && [ -s "$VM_PROBLEMS_FILE" ]; then
        while IFS='|' read -r host_info failure_detail; do
            HOSTS_WITH_VM_PROBLEMS+=("$host_info")
            HOSTS_VM_FAILURE_DETAILS+=("$failure_detail")
        done < "$VM_PROBLEMS_FILE"
    fi
}

increment_success() {
    flock -x 201
    ((SUCCESS_COUNT++))
    ((TOTAL_PROCESSED++))
    flock -u 201
}

increment_failed() {
    flock -x 201
    ((FAILED_COUNT++))
    ((TOTAL_PROCESSED++))
    flock -u 201
}

# ===========================================
# VERIFICACIONES INICIALES
# ===========================================
if [ "$EUID" -ne 0 ]; then 
    log_error "Ejecuta como root: sudo $0"
    exit 1
fi

if [ ! -f "$HOSTS_FILE" ]; then
    log_error "No se encuentra $HOSTS_FILE"
    exit 1
fi

if ! rpm -q sshpass &>/dev/null; then
    dnf install -y sshpass
fi

# Verificar que al menos una de las rutas de recursos existe
if [ ! -d "$EXAM_RESOURCES_PATH_HOST" ] && [ ! -d "$EXAM_RESOURCES_PATH_VMS" ]; then
    log_error "No se encuentran las rutas de recursos:"
    log_error "  - Host: $EXAM_RESOURCES_PATH_HOST"
    log_error "  - VMs: $EXAM_RESOURCES_PATH_VMS"
    exit 1
fi

declare -a TARGET_IDS=("$@")

# ===========================================
# FUNCIONES PRINCIPALES
# ===========================================

# Paso 1: Arrancar todas las máquinas virtuales
start_all_virtual_machines() {
    local HOST=$1
    
    log_info "Arrancando todas las máquinas virtuales..."
    
    # Obtener lista de todas las VMs
    local VM_LIST
    VM_LIST=$(ssh -o ConnectTimeout=10 -o BatchMode=yes "root@$HOST" "sudo -u $EXAM_USER VBoxManage list vms 2>/dev/null | cut -d'\"' -f2" </dev/null 2>/dev/null)
    
    if [ -z "$VM_LIST" ]; then
        log_warning "No se encontraron VMs"
        return 1
    fi
    
    while IFS= read -r VM_NAME; do
        if [ -n "$VM_NAME" ]; then         
                ssh -o ConnectTimeout=10 -o BatchMode=yes "root@$HOST" "sudo -u $EXAM_USER VBoxManage startvm \"$VM_NAME\" --type headless" </dev/null
                log_info "  VM $VM_NAME arrancada"
                
                # Esperar a que la VM termine de arrancar
                sleep 2

        fi
    done <<< "$VM_LIST"
    
    return 0
}

wait_for_vm_ready() {
    local HOST=$1
    local PORT=$2
    local TIMEOUT=90
    local INTERVAL=2
    local ELAPSED=0

    while [ $ELAPSED -lt $TIMEOUT ]; do
        if ssh -o ConnectTimeout=2 -o BatchMode=yes \
               -J "root@$HOST" -p "$PORT" root@127.0.0.1 exit 2>/dev/null; then
            return 0
        fi
        sleep $INTERVAL
        ELAPSED=$((ELAPSED + INTERVAL))
    done
    return 1
}

# Paso 2: Configurar cortafuegos
configure_firewall() {
    local HOST=$1
    
    log_info "Configurando cortafuegos en $HOST..."
    
    ssh -o ConnectTimeout=10 -o BatchMode=yes "root@$HOST" "

    	# 0. Iniciar nftables por si no lo estuviera
    	systemctl start nftables

        # 1. Limpiar todas las reglas nftables existentes
        nft flush ruleset
        
        # 2. Crear tabla y cadenas con política DROP por defecto
        nft add table inet filter
        nft add chain inet filter input { type filter hook input priority 0\; policy drop\; }
        nft add chain inet filter forward { type filter hook forward priority 0\; policy drop\; }
        nft add chain inet filter output { type filter hook output priority 0\; policy drop\; }
        
        # 3. Permitir loopback (entrada y salida)
        nft add rule inet filter input iif lo accept
        nft add rule inet filter output oif lo accept
        
        # 4. Permitir tráfico desde/hacia las IPs permitidas
        for ip in $ALLOWED_IPS; do
            nft add rule inet filter input ip saddr \$ip accept
            nft add rule inet filter output ip daddr \$ip accept
        done
        
        # 5. Guardar reglas para que persistan tras reinicio
        nft list ruleset > /etc/sysconfig/nftables.conf
        systemctl enable nftables
        
        echo '✅ FIREWALL CONFIGURADO con nftables'
        echo '   • IPs Permitidas: $ALLOWED_IPS'
        echo '   • Internet: BLOQUEADO'
    " </dev/null
    
    return 0
}


# Paso 3: Copiar recursos del PC_ADMIN al HOST remoto
copy_host_resources() {
    local HOST=$1
    
    if [ ! -d "$EXAM_RESOURCES_PATH_HOST" ]; then
        log_warning "No hay recursos para el host"
        return 0
    fi
    
    log_info "Copiando recursos para el HOST..."
    
    # Crear directorio remoto
    ssh -o ConnectTimeout=3 "root@$HOST" "mkdir -p $REMOTE_EXAM_PATH_HOST" </dev/null
    
    # Verificar si hay archivos para copiar
    if [ -z "$(ls -A "$EXAM_RESOURCES_PATH_HOST" 2>/dev/null)" ]; then
        log_warning "Directorio de recursos del host vacío"
        return 0
    fi
    
    # Usar scp para copiar
    log_info "Copiando archivos con scp..."
    scp -o ConnectTimeout=3 -r "$EXAM_RESOURCES_PATH_HOST"/* "root@$HOST:$REMOTE_EXAM_PATH_HOST/" </dev/null
    
    if [ $? -eq 0 ]; then
        # Cambiar propietario
        ssh -o ConnectTimeout=10 "root@$HOST" "chown -R $EXAM_USER:$EXAM_USER $REMOTE_EXAM_PATH_HOST" </dev/null
        log_info "✅ Recursos del host copiados"
        return 0
    else
        log_error "Error copiando recursos del host"
        return 1
    fi
}

# Paso 4: Copiar recursos del PC_ADMIN a las máquinas del HOST remoto
copy_resources_to_vms() {
    local HOST=$1
    local ID=$2
    
    if [ ! -d "$EXAM_RESOURCES_PATH_VMS" ]; then
        log_warning "No hay recursos para VMs"
        return 0
    fi
    
    log_info "Copiando recursos a las VMs..."
    
    local VM_COUNT=0
    local LOCAL_SUCCESS_COUNT=0
    local LOCAL_FAIL_COUNT=0
    local FAILED_PORTS=""  
    
    for VM_PORT in "${VM_PORTS[@]}"; do
        ((VM_COUNT++))
        log_info "  Procesando VM [$VM_COUNT] en IP: 127.0.0.1 -p $VM_PORT"
        
        # CREAR DIRECTORIO
        ssh -o StrictHostKeyChecking=no -o ConnectTimeout=3 -J "root@$HOST" \
            "root@127.0.0.1 -p $VM_PORT" "mkdir -p $REMOTE_EXAM_PATH_VMS" 2>/dev/null
        
        # COPIAR ARCHIVOS
        scp -o StrictHostKeyChecking=no -o ConnectTimeout=3 \
            -o ProxyJump="root@$HOST" \
            -P "$VM_PORT" \
            -r "$EXAM_RESOURCES_PATH_VMS"/* \
            "root@127.0.0.1:$REMOTE_EXAM_PATH_VMS/" 2>/dev/null
        
        # VERIFICAR RESULTADO
        
        if [ $? -eq 0 ]; then
        # Cambiar propietario
        ssh -o ConnectTimeout=10 -J "root@$HOST" -p "$VM_PORT" "root@127.0.0.1" "chown -R $VM_USER:$VM_USER $REMOTE_EXAM_PATH_VMS" </dev/null
            ((LOCAL_SUCCESS_COUNT++))
            log_info "    ✅ Recursos copiados a 127.0.0.1 -p $VM_PORT"
    else
            ((LOCAL_FAIL_COUNT++))
            log_warning "    ⚠️  Fallo en 127.0.0.1 -p $VM_PORT"
            FAILED_PORTS="$FAILED_PORTS$VM_PORT, "
    fi


    done
    
    log_info "✅ Recursos copiados a $LOCAL_SUCCESS_COUNT de $VM_COUNT VM(s)"
    
    # REGISTRAR SI HUBO FALLOS - USANDO ARCHIVO
    if [ $LOCAL_FAIL_COUNT -gt 0 ]; then
        # Guardar información del fallo
        local host_info
        local failure_detail       

        host_info="$HOST (ID: $ID)"
        
        # Guardar detalles del fallo
        if [ $LOCAL_SUCCESS_COUNT -eq 0 ]; then
            failure_detail="No se copió a NINGUNA VM"
        elif [ $LOCAL_FAIL_COUNT -eq $VM_COUNT ]; then
            failure_detail="Falló en TODAS las VMs"
        else
            failure_detail="Falló en $LOCAL_FAIL_COUNT de $VM_COUNT VMs (puertos: ${FAILED_PORTS%, })"
        fi
        
        # Usar función que escribe en archivo compartido
        add_vm_problem_to_file "$host_info" "$failure_detail"
    fi
    
    return 0
}

# Paso 5: Crear directorios vacíos de evidencias en host y VMs
create_evidences_directories() {
    local HOST=$1
    local ID=$2
    
    log_info "Creando directorios de evidencias en $HOST (ID: $ID)..."
    
    # Crear en el host anfitrión
    ssh -o ConnectTimeout=10 "root@$HOST" "mkdir -p $EVIDENCES_HOST_PATH && chown $EXAM_USER:$EXAM_USER $EVIDENCES_HOST_PATH" </dev/null
    if [ $? -eq 0 ]; then
        log_info "  ✅ Directorio de evidencias del host creado"
    else
        log_error "  ❌ Error creando directorio de evidencias del host"
    fi
    
    # Crear en cada VM
    local VM_COUNT=0
    for VM_PORT in "${VM_PORTS[@]}"; do
        ((VM_COUNT++))
        log_info "  Creando directorio de evidencias en VM puerto $VM_PORT..."
        
        ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -J "root@$HOST" -p "$VM_PORT" "root@127.0.0.1" \
            "mkdir -p $EVIDENCES_VM_PATH && chown $VM_USER:$VM_USER $EVIDENCES_VM_PATH" </dev/null 2>/dev/null
        
        if [ $? -eq 0 ]; then
            log_info "    ✅ Directorio creado en VM puerto $VM_PORT"
        else
            log_warning "    ⚠️  No se pudo crear directorio en VM puerto $VM_PORT (la VM podría no estar arrancada)"
        fi
    done
}

# Paso 6: Activar cuenta del usuario de examen
activate_exam_account() {
    local HOST=$1
    
    log_info "Activando cuenta $EXAM_USER..."
    
    ssh -o ConnectTimeout=10 -o BatchMode=yes "root@$HOST" "passwd -u $EXAM_USER 2>/dev/null" </dev/null
    
    return $?
}

# Función worker para procesar un host
worker_process_host() {
    local HOST=$1
    local ID=$2
    
    echo "========================================"
    log_info "PROCESANDO: $HOST (ID: ${ID:-N/A})"
    
    # Verificar conexión con timeout
    if ! ssh -o ConnectTimeout=10 -o BatchMode=yes "root@$HOST" exit </dev/null 2>/dev/null; then
        log_error "No se puede conectar"
        return 1
    fi
    
    # Ejecutar pasos
    if ! start_all_virtual_machines "$HOST"; then
        log_warning "Problema al arrancar VMs, continuando..."
    fi
    
    # Esperar a que todas las VMs arranquen
    for PORT in "${VM_PORTS[@]}"; do
    	if wait_for_vm_ready "$HOST" "$PORT"; then
    	    log_info "✅ VM en puerto $PORT encendida"
    	else
            log_error "❌ VM en puerto $PORT no arrancó o tuvo un error"
    	fi
    done
    
    if ! configure_firewall "$HOST"; then
        log_error "Error configurando firewall"
        return 1
    fi
    
    if ! copy_host_resources "$HOST"; then
        log_warning "Error copiando recursos del host, continuando..."
    fi
    
    if ! copy_resources_to_vms "$HOST" "$ID"; then
        log_warning "Problemas copiando recursos a VMs"
    fi
    
    if ! create_evidences_directories "$HOST" "$ID"; then
        log_warning "Error generando carpetas para las evidencias"
    fi
    
    if ! activate_exam_account "$HOST"; then
        log_warning "Error activando cuenta de examen"
    fi
    
    echo "----------------------------------------"
    log_info "✅ COMPLETADO EN $HOST"
    echo "   Usuario: $EXAM_USER"
    echo "   Recursos HOST en: $REMOTE_EXAM_PATH_HOST"
    echo "   Recursos VMs en: $REMOTE_EXAM_PATH_VMS"
    
    return 0
}

# Función para mostrar progreso
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

# Función para esperar que haya espacio para más workers
wait_for_slot() {
    while [ $CURRENT_JOBS -ge $MAX_WORKERS ]; do
        # Esperar a que cualquier proceso termine
        wait -n 2>/dev/null
        CURRENT_JOBS=$((CURRENT_JOBS - 1))
        
        # Procesar resultados de los procesos que terminaron
        for i in "${!PIDS[@]}"; do
            local pid="${PIDS[$i]}"
            if ! kill -0 "$pid" 2>/dev/null; then
                # El proceso terminó
                if wait "$pid" 2>/dev/null; then
                    increment_success
                else
                    increment_failed
                    # Extraer información del log para fallos
                    if [ -f "$LOG_DIR/pid_${pid}.info" ]; then
                        read -r REAL_IP REAL_ID < "$LOG_DIR/pid_${pid}.info"
                        add_to_failed "$REAL_IP" "$REAL_ID"
                        rm "$LOG_DIR/pid_${pid}.info"
                    fi
                fi
                unset "PIDS[$i]"
            fi
        done
        # Reindexar array
        PIDS=("${PIDS[@]}")
        show_progress $TOTAL_PROCESSED $HOSTS_TO_PROCESS
    done
}


# ===========================================
# EJECUCIÓN PRINCIPAL CON PARALELISMO
# ===========================================
log_info "INICIANDO FASE DE INICIO DE EXAMEN"

# Mostrar información de recursos
if [ -d "$EXAM_RESOURCES_PATH_HOST" ]; then
    log_info "Recursos para HOST encontrados en: $EXAM_RESOURCES_PATH_HOST"
    log_info "  Número de archivos: $(find "$EXAM_RESOURCES_PATH_HOST" -type f | wc -l)"
fi

if [ -d "$EXAM_RESOURCES_PATH_VMS" ]; then
    log_info "Recursos para VMs encontrados en: $EXAM_RESOURCES_PATH_VMS"
    log_info "  Número de archivos: $(find "$EXAM_RESOURCES_PATH_VMS" -type f | wc -l)"
fi

if [ ${#TARGET_IDS[@]} -eq 0 ]; then
    log_info "Procesando TODOS los hosts del archivo"
else
    log_info "Procesando solo los hosts con IDs: ${TARGET_IDS[*]}"
fi
echo ""

# Arrays para control de concurrencia
declare -a PIDS
CURRENT_JOBS=0

# Contadores
TOTAL_HOSTS=0
HOSTS_TO_PROCESS=0

# Contar cuántos hosts vamos a procesar y verificar IDs
declare -a AVAILABLE_IDS
while IFS= read -r HOST; do
    [[ -z "$HOST" ]] && continue
    [[ "$HOST" =~ ^#.* ]] && continue
    
    IP="${HOST%%:*}"
    ID="${HOST#*:}"
    
    if [ "$IP" = "$ID" ]; then
        ID=""
    fi
    
    ((TOTAL_HOSTS++))
    
    # Filtrar por ID si se especificó
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
    
    ((HOSTS_TO_PROCESS++))
    
    if [ "$IP" != "$ID" ] && [ -n "$ID" ]; then
        AVAILABLE_IDS+=("$ID")
    fi
done < "$HOSTS_FILE"

# Verificar IDs si se especificaron
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

# Procesar el archivo con workers paralelos
while IFS= read -r HOST; do
    [[ -z "$HOST" ]] && continue
    [[ "$HOST" =~ ^#.* ]] && continue
    
    IP="${HOST%%:*}"
    ID="${HOST#*:}"
    
    if [ "$IP" = "$ID" ]; then
        ID=""
    fi
    
    # Filtrar por ID si se especificó
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
    
    # Esperar si ya tenemos el máximo de workers
    wait_for_slot
    
    # Lanzar el worker en background
    (
        exec < /dev/null
        worker_process_host "$IP" "$ID"
    ) &
    
    PID=$!
    PIDS+=($PID)
    CURRENT_JOBS=$((CURRENT_JOBS + 1))
    
    # Guardar información del host para este PID
    echo "$IP $ID" > "$LOG_DIR/pid_${PID}.info"
    
done < "$HOSTS_FILE"

# Esperar a que todos los workers restantes terminen
echo ""
echo "Esperando a que todos los hosts terminen..."
while [ ${#PIDS[@]} -gt 0 ]; do
    wait -n 2>/dev/null
    CURRENT_JOBS=$((CURRENT_JOBS - 1))
    for i in "${!PIDS[@]}"; do
        pid="${PIDS[$i]}"
        if ! kill -0 "$pid" 2>/dev/null; then
            if wait "$pid" 2>/dev/null; then
                increment_success
            else
                increment_failed
                if [ -f "$LOG_DIR/pid_${pid}.info" ]; then
                    read -r REAL_IP REAL_ID < "$LOG_DIR/pid_${pid}.info"
                    add_to_failed "$REAL_IP" "$REAL_ID"
                    rm "$LOG_DIR/pid_${pid}.info"
                fi
            fi
            unset "PIDS[$i]"
        fi
    done
    PIDS=("${PIDS[@]}")
    show_progress $TOTAL_PROCESSED $HOSTS_TO_PROCESS
    sleep 0.5
done

echo ""

# ===========================================
# RESUMEN FINAL
# ===========================================
echo ""
echo "========================================"
log_info "RESUMEN FINAL"
echo "========================================"
log_info "Total hosts en archivo: $TOTAL_HOSTS"

if [ ${#TARGET_IDS[@]} -gt 0 ]; then
    log_info "IDs especificados: ${#TARGET_IDS[@]}"
    log_info "IDs encontrados en archivo: ${#FOUND_IDS[@]}"
    if [ ${#NOT_FOUND_IDS[@]} -gt 0 ]; then
        log_warning "IDs no encontrados: ${#NOT_FOUND_IDS[@]}"
    fi
fi

log_info "Hosts procesados: $HOSTS_TO_PROCESS"
log_info "Exitosos: $SUCCESS_COUNT"

if [ $FAILED_COUNT -gt 0 ]; then
    log_error "Fallidos: $FAILED_COUNT"
    echo ""
    log_error "HOSTS QUE FALLARON:"
    echo "----------------------------------------"
    
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

# LEER PROBLEMAS DE VMs DESDE EL ARCHIVO
read_vm_problems

# MOSTRAR HOSTS CON PROBLEMAS EN VMs
if [ ${#HOSTS_WITH_VM_PROBLEMS[@]} -gt 0 ]; then
    echo ""
    log_warning "⚠️  HOSTS CON PROBLEMAS AL COPIAR A VMs:"
    echo "----------------------------------------"
    for i in "${!HOSTS_WITH_VM_PROBLEMS[@]}"; do
        HOST_INFO="${HOSTS_WITH_VM_PROBLEMS[$i]}"
        FAILURE_DETAIL="${HOSTS_VM_FAILURE_DETAILS[$i]}"
        echo "  ⚠️  $HOST_INFO: $FAILURE_DETAIL"
    done
    echo "----------------------------------------"
fi

if [ ${#NOT_FOUND_IDS[@]} -gt 0 ]; then
    echo ""
    log_warning "IDs ESPECIFICADOS PERO NO ENCONTRADOS:"
    echo "----------------------------------------"
    for NOT_FOUND_ID in "${NOT_FOUND_IDS[@]}"; do
        echo "  ❓ $NOT_FOUND_ID"
    done
    echo "----------------------------------------"
fi

if [ $HOSTS_TO_PROCESS -eq 0 ]; then
    if [ ${#NOT_FOUND_IDS[@]} -eq ${#TARGET_IDS[@]} ]; then
        log_error "❌ ¡Ninguno de los IDs especificados existe!"
    else
        log_warning "⚠️  No se procesó ningún host"
    fi
elif [ $SUCCESS_COUNT -eq $HOSTS_TO_PROCESS ]; then
    log_info "✅ ¡Todos los hosts procesados exitosamente!"
elif [ $SUCCESS_COUNT -eq 0 ]; then
    log_error "❌ ¡Todos los hosts fallaron!"
else
    log_warning "⚠️  Procesados $SUCCESS_COUNT de $HOSTS_TO_PROCESS hosts"
fi

echo ""

# Limpieza
exec 201>&-  # Cerrar file descriptors
exec 202>&-
rm -f "$MAIN_LOCK_FILE" "$VM_PROBLEMS_LOCK_FILE" 2>/dev/null
rm -f "$LOG_DIR"/pid_*.info 2>/dev/null
rm -f "$VM_PROBLEMS_FILE" 2>/dev/null
