#!/bin/bash
cd "$(dirname "$0")"
# Cargar configuración central
CONFIG_FILE="./exam_config.sh"
if [ ! -f "$CONFIG_FILE" ]; then
    echo -e "\033[0;31m[ERROR]\033[0m No se encuentra $CONFIG_FILE"
    exit 1
fi
source "$CONFIG_FILE"

LOG_DIR="/tmp/exam_end_logs_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$LOG_DIR"

# Archivo para almacenar problemas de VMs entre procesos
VM_PROBLEMS_FILE="$LOG_DIR/vm_problems.txt"
> "$VM_PROBLEMS_FILE"

# ===========================================
# VARIABLES GLOBALES CON LOCKS
# ===========================================
declare -a FAILED_IPS
declare -a FAILED_IDS
declare -a NOT_FOUND_IDS
declare -a FOUND_IDS
declare -a HOSTS_WITH_VM_PROBLEMS
declare -a HOSTS_VM_FAILURE_DETAILS

TOTAL_PROCESSED=0
SUCCESS_COUNT=0
FAILED_COUNT=0

# Locks
MAIN_LOCK_FILE="/tmp/exam_end_main_lock_$$.lock"
exec 201>"$MAIN_LOCK_FILE"
VM_PROBLEMS_LOCK_FILE="/tmp/exam_end_vm_lock_$$.lock"
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

add_vm_problem_to_file() {
    local host_info=$1
    local failure_detail=$2
    flock -x 202
    echo "${host_info}|${failure_detail}" >> "$VM_PROBLEMS_FILE"
    flock -u 202
}

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

# Crear directorio de evidencias si no existe
mkdir -p "$EVIDENCE_BASE_DIR"
log_info "Las evidencias se guardarán en: $EVIDENCE_BASE_DIR"

declare -a TARGET_IDS=("$@")

# ===========================================
# FUNCIONES ESPECÍFICAS DE LA FASE DE FINALIZACIÓN
# ===========================================

# Paso 1: Transferir archivos de respuesta del estudiante
transfer_host_answers() {
    local HOST=$1
    local ID=$2
    local host_evidence_dir="$EVIDENCE_BASE_DIR/$ID/Host"
    mkdir -p "$host_evidence_dir"

    log_info "Recogiendo respuestas del HOST anfitrión en $HOST (ID: $ID)..."

    # Copiar recursivamente desde el host remoto
    scp -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
        -r "root@$HOST:$EVIDENCES_HOST_PATH"/* "$host_evidence_dir/" 2>/dev/null

    if [ $? -eq 0 ] && [ -n "$(ls -A "$host_evidence_dir" 2>/dev/null)" ]; then
        log_info "  ✅ Respuestas del host copiadas"
    else
        log_warning "  ⚠️  No se encontraron respuestas en el host o falló la copia"
    fi
}
   
# Se copian desde las MV al directorio local de evidencias
transfer_vms_answers() {
    local HOST=$1
    local ID=$2
    local host_evidence_dir="$EVIDENCE_BASE_DIR/$ID/VMs"
    mkdir -p "$host_evidence_dir"

    log_info "Recogiendo respuestas de las MV en $HOST (ID: $ID)..."

    local VM_COUNT=0
    local SUCCESS_VM=0
    for VM_PORT in "${VM_PORTS[@]}"; do
        ((VM_COUNT++))
        local vm_evidence_dir="$host_evidence_dir/VM_$VM_PORT"
        scp -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
            -o ProxyJump="root@$HOST" \
            -P "$VM_PORT" \
            -r "root@127.0.0.1:$EVIDENCES_VM_PATH"/* "$vm_evidence_dir/" 2>/dev/null

        # Copiar archivos desde la MV mediante SCP con proxy jump
        if [ $? -eq 0 ] && [ -n "$(ls -A "$vm_evidence_dir" 2>/dev/null)" ]; then
            log_info "  ✅ Respuestas recogidas de VM en puerto $VM_PORT"
            ((SUCCESS_VM++))
        else
            log_warning "  ⚠️  No se encontraron respuestas en VM puerto $VM_PORT"
        fi
    done

    if [ $SUCCESS_VM -eq 0 ]; then
        log_warning "  No se recogieron respuestas de ninguna MV en $HOST"
    else
        log_info "  Respuestas recogidas en $SUCCESS_VM de $VM_COUNT MV(s)"
    fi
}

# Paso 2: Ejecutar ausearch en host y VMs, guardar salida
transfer_audit_logs() {
    local HOST=$1
    local ID=$2
    local host_dir="$EVIDENCE_BASE_DIR/$ID/Host"
    mkdir -p "$EVIDENCE_BASE_DIR/$ID/Host"    

    log_info "Recogiendo logs de auditoría (ausearch) en $ID..."

    # --- Ausearch en el host ---
    ssh -tt -o StrictHostKeyChecking=no -o ConnectTimeout=10 "root@$HOST" \
        "ausearch --start today -i" > "$host_dir/ausearch_host.txt" 2>/dev/null

    if [ $? -eq 0 ] && [ -s "$host_dir/ausearch_host.txt" ]; then
        log_info "  ✅ Log de auditoría del host copiado"
    else
        log_warning "  ⚠️  No se pudo obtener ausearch del host o no hay eventos"
    fi

    # --- Ausearch en cada MV ---
    for VM_PORT in "${VM_PORTS[@]}"; do
        local vm_dir="$EVIDENCE_BASE_DIR/$ID/VMs/VM_$VM_PORT"

	
	if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes \
            -o ProxyJump="root@$HOST" -p "$VM_PORT" "root@127.0.0.1" "exit" 2>/dev/null; then
                mkdir -p "$vm_dir"        
		ssh -tt -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
		    -o ProxyJump="root@$HOST" -p "$VM_PORT" \
		    "root@127.0.0.1" "sudo ausearch --start today -i" > "$vm_dir/ausearch_VM_$VM_PORT.txt" 2>/dev/null
	fi

        if [ $? -eq 0 ] && [ -s "$vm_dir/ausearch_VM_$VM_PORT.txt" ]; then
            log_info "  ✅ Log de auditoría de VM puerto $VM_PORT copiado"
        else
            log_warning "  ⚠️  No se pudo obtener ausearch de VM puerto $VM_PORT"
        fi
    done
}

# Paso 3: Ejecutar scripts de validación en las MV y transferir resultados
execute_validation_scripts() {
    local HOST=$1
    local ID=$2

    # Verificar que existe el directorio de scripts
    if [ ! -d "$VALIDATION_SCRIPTS_DIR" ]; then
        log_warning "  No se encuentra el directorio de scripts de validación: $VALIDATION_SCRIPTS_DIR"
        return 1
    fi

    
    local validation_out_dir="$EVIDENCE_BASE_DIR/$ID/Scripts_Validacion"
    mkdir -p "$validation_out_dir"


    log_info "Ejecutando scripts de validación locales para el ID $ID..."

    for script in "$VALIDATION_SCRIPTS_DIR"/*; do
        [ -f "$script" ] || continue
        local script_name=$(basename "$script")
        local output_file="$validation_out_dir/${script_name}.txt"

        log_info "  Ejecutando $script_name..."
        if bash "$script" "$HOST" "${VM_PORTS[*]}" > "$output_file" 2>&1; then
            log_info "    ✅ $script_name finalizado correctamente"
        else
            log_warning "    ⚠️  $script_name terminó con error (código $?)"
        fi
    done

    log_info "  Validación completada. Resultados en: $validation_out_dir"
}

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

# Paso 4: Parar todas las máquinas virtuales del host
shutdown_all_virtual_machines() {
    local HOST=$1
    local TIMEOUT=90
    local INTERVAL=3
    local ELAPSED

    log_info "Apagando todas las máquinas virtuales en $HOST..."

    # Obtener lista de VMs en ejecución
    local RUNNING_VMS
    RUNNING_VMS=$(ssh -o ConnectTimeout=10 -o BatchMode=yes "root@$HOST" \
        "sudo -u $EXAM_USER VBoxManage list runningvms 2>/dev/null | cut -d'\"' -f2" </dev/null 2>/dev/null)

    if [ -z "$RUNNING_VMS" ]; then
        log_info "No hay máquinas virtuales en ejecución"
        return 0
    fi

    while IFS= read -r VM_NAME; do
        if [ -n "$VM_NAME" ]; then
            log_info "  Enviando acpipowerbutton a: $VM_NAME"

            # 1. Apagado suave
            ssh -o ConnectTimeout=10 -o BatchMode=yes "root@$HOST" \
                "sudo -u $EXAM_USER VBoxManage controlvm \"$VM_NAME\" acpipowerbutton" </dev/null 2>/dev/null

            # 2. Esperar a que se apague (máximo TIMEOUT segundos)
            ELAPSED=0
            while [ $ELAPSED -lt $TIMEOUT ]; do
                local STATE
                STATE=$(ssh -o ConnectTimeout=5 -o BatchMode=yes "root@$HOST" \
                    "sudo -u $EXAM_USER VBoxManage showvminfo \"$VM_NAME\" --machinereadable 2>/dev/null | grep 'VMState=' | cut -d'=' -f2 | tr -d '\"'" </dev/null 2>/dev/null)

                if [ "$STATE" = "poweroff" ]; then
                    log_info "    ✅ VM '$VM_NAME' apagada correctamente"
                    break
                fi
                sleep $INTERVAL
                ELAPSED=$((ELAPSED + INTERVAL))
            done

            # 3. Si no se apagó a tiempo, forzar apagado
            if [ $ELAPSED -ge $TIMEOUT ]; then
                log_warning "    ⚠️  VM '$VM_NAME' no respondió al apagado ACPI, forzando poweroff..."
                ssh -o ConnectTimeout=10 -o BatchMode=yes "root@$HOST" \
                    "sudo -u $EXAM_USER VBoxManage controlvm \"$VM_NAME\" poweroff" </dev/null 2>/dev/null
                sleep 2
            fi
        fi
    done <<< "$RUNNING_VMS"
}

# Paso 5: Restablecer la configuración del cortafuegos (permitir todo)
restore_firewall() {
    local HOST=$1
    log_info "Restaurando cortafuegos en $HOST a estado abierto..."

    ssh -o ConnectTimeout=10 -o BatchMode=yes "root@$HOST" "
      
        # Limpiar reglas
	nft flush ruleset 2>/dev/null
	
	# Guardar reglas para que persistan tras reinicio
        nft list ruleset > /etc/sysconfig/nftables.conf

        echo '✅ Firewall restaurado'
    " </dev/null

    if [ $? -eq 0 ]; then
        log_info "  ✅ Firewall restaurado correctamente"
    else
        log_error "  ❌ Error al restaurar firewall"
        return 1
    fi
}

deactivate_exam_account() {

    local HOST=$1    
    log_info "Desactivando cuenta $EXAM_USER..."    
    ssh -o ConnectTimeout=10 -o BatchMode=yes "root@$HOST" "passwd -l $EXAM_USER 2>/dev/null" </dev/null
    
}

# Función worker que procesa un host completo
worker_process_host() {
    local HOST=$1
    local ID=$2

    echo "========================================"
    log_info "PROCESANDO: $HOST (ID: ${ID:-N/A})"

    # Verificar conexión SSH
    if ! ssh -o ConnectTimeout=10 -o BatchMode=yes "root@$HOST" exit </dev/null 2>/dev/null; then
        log_error "No se puede conectar a $HOST"
        return 1
    fi

    # Ejecutar los pasos en orden
    start_all_virtual_machines "$HOST"
    # Esperar a que todas las VMs arranquen
    for PORT in "${VM_PORTS[@]}"; do
    	if wait_for_vm_ready "$HOST" "$PORT"; then
    	    log_info "✅ VM en puerto $PORT encendida"
    	else
            log_error "❌ VM en puerto $PORT no arrancó o tuvo un error"
    	fi
    done
    transfer_host_answers "$HOST" "$ID"
    transfer_vms_answers "$HOST" "$ID"
    transfer_audit_logs "$HOST" "$ID"
    execute_validation_scripts "$HOST" "$ID"
    shutdown_all_virtual_machines "$HOST"
    restore_firewall "$HOST"
    deactivate_exam_account "$HOST"

    echo "----------------------------------------"
    log_info "✅ FINALIZACIÓN COMPLETADA EN $HOST"
    echo "   Evidencias guardadas en: $EVIDENCE_BASE_DIR/$ID"
    return 0
}

# ===========================================
# FUNCIONES DE CONTROL DE CONCURRENCIA
# ===========================================
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

wait_for_slot() {
    while [ $CURRENT_JOBS -ge $MAX_WORKERS ]; do
        wait -n 2>/dev/null
        CURRENT_JOBS=$((CURRENT_JOBS - 1))
        for i in "${!PIDS[@]}"; do
            local pid="${PIDS[$i]}"
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
    done
}

# ===========================================
# EJECUCIÓN PRINCIPAL
# ===========================================
log_info "INICIANDO FASE DE FINALIZACIÓN DE EXAMEN"
log_info "Directorio de evidencias: $EVIDENCE_BASE_DIR"
echo ""

# Preparar listado de hosts a procesar
declare -a AVAILABLE_IDS
TOTAL_HOSTS=0
HOSTS_TO_PROCESS=0

while IFS= read -r HOST; do
    [[ -z "$HOST" ]] && continue
    [[ "$HOST" =~ ^#.* ]] && continue
    IP="${HOST%%:*}"
    ID="${HOST#*:}"
    if [ "$IP" = "$ID" ]; then ID=""; fi
    ((TOTAL_HOSTS++))
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
    if [ -n "$ID" ]; then
        AVAILABLE_IDS+=("$ID")
    fi
done < "$HOSTS_FILE"

# Verificar IDs no encontrados
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

# Procesar en paralelo
declare -a PIDS
CURRENT_JOBS=0

while IFS= read -r HOST; do
    [[ -z "$HOST" ]] && continue
    [[ "$HOST" =~ ^#.* ]] && continue
    IP="${HOST%%:*}"
    ID="${HOST#*:}"
    if [ "$IP" = "$ID" ]; then ID=""; fi
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

    wait_for_slot

(
    exec < /dev/null
    worker_process_host "$IP" "$ID"
) &

    PID=$!
    PIDS+=($PID)
    CURRENT_JOBS=$((CURRENT_JOBS + 1))
    echo "$IP $ID" > "$LOG_DIR/pid_${PID}.info"
done < "$HOSTS_FILE"

# Esperar a que terminen todos
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
    log_info "IDs encontrados: ${#FOUND_IDS[@]}"
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

read_vm_problems
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
    log_info "✅ ¡Todos los hosts finalizados exitosamente!"
elif [ $SUCCESS_COUNT -eq 0 ]; then
    log_error "❌ ¡Todos los hosts fallaron!"
else
    log_warning "⚠️  Procesados $SUCCESS_COUNT de $HOSTS_TO_PROCESS hosts"
fi

echo ""

# Limpieza
exec 201>&-
exec 202>&-
rm -f "$MAIN_LOCK_FILE" "$VM_PROBLEMS_LOCK_FILE" 2>/dev/null
rm -f "$LOG_DIR"/pid_*.info 2>/dev/null
rm -f "$VM_PROBLEMS_FILE" 2>/dev/null
