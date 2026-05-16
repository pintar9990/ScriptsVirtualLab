#!/bin/bash

INICIO=$(date +%s)
cd "$(dirname "$0")"
# Cargar configuración central
CONFIG_FILE="./exam_config.sh"
if [ ! -f "$CONFIG_FILE" ]; then
    echo -e "\033[0;31m[ERROR]\033[0m No se encuentra $CONFIG_FILE"
    exit 1
fi
source "$CONFIG_FILE"

LOG_DIR="/tmp/ova_deploy_logs_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$LOG_DIR"



if [ ! -f "$HOSTS_FILE" ]; then
    log_error "No se encuentra $HOSTS_FILE"
    exit 1
fi

if [ "$EUID" -ne 0 ]; then 
    log_error "Ejecuta como root: sudo $0"
    exit 1
fi

echo -n "Introduce la contraseña root de las máquinas virtuales: "
read -s VM_PASSWORD
echo  # Salto de línea después de la entrada oculta

# Verificar que no esté vacía
if [ -z "$VM_PASSWORD" ]; then
    log_error "No se introdujo ninguna contraseña."
    exit 1
fi

declare -a FAILED_IPS
declare -a FAILED_IDS
declare -a NOT_FOUND_IDS

# ===========================================
# FUNCIONES PARA CREAR RECURSOS VIRTUALES
# ===========================================
# Función para crear redes virtuales
create_virtual_networks() {
    local HOST=$1
    
    log_info "Creando redes virtuales para examen en $HOST..."
    
    for NET_NAME in "${!VIRTUAL_NETWORKS[@]}"; do
        NET_CONFIG="${VIRTUAL_NETWORKS[$NET_NAME]}"
        NET_TYPE="${NET_CONFIG%%:*}"
        NET_CIDR="${NET_CONFIG#*:}"
        
        case $NET_TYPE in
             "nat-control")
                # RED NAT-CONTROL: NAT especial con IPs fijas y reenvío de puertos SSH
                log_info "Configurando red NAT-CONTROL '$NET_NAME' ($NET_CIDR)..."
                
                
                
                if ssh "root@$HOST" "sudo -u $EXAM_USER VBoxManage list natnetworks 2>/dev/null | grep -q $NET_NAME" </dev/null; then
                    log_warning "La red NAT-CONTROL '$NET_NAME' ya existe en $HOST"
                    log_info "✅ Red NAT-CONTROL ya configurada (omitida)"
                else
                
                # Crear una red NAT Network SIN DHCP
                if ssh "root@$HOST" "sudo -u $EXAM_USER VBoxManage natnetwork add --netname \"$NET_NAME\" --network \"$NET_CIDR\" --dhcp off" </dev/null; then
                    log_info "✅ Red NAT-CONTROL '$NET_NAME' creada (sin DHCP)"
                    
                    # Configurar reenvío de puertos SSH para cada IP fija
                    log_info "Configurando reenvío de puertos SSH..."
                    
                    IP_BASE="${NET_CIDR%.*}"  # Quita /24 -> Ejemplo: 192.168.150.0
                    
                    # Configurar SSH para IPs 1-5
                    for i in "${!VM_PORTS[@]}"; do
                    	VM_NUM=$((i + 1))
                        GUEST_IP="${IP_BASE}.10${VM_NUM}"
                        HOST_PORT="${VM_PORTS[$i]}"
                        
                        # Configurar reenvío de puertos SSH
                        if ssh "root@$HOST" "sudo -u $EXAM_USER VBoxManage natnetwork modify --netname \"$NET_NAME\" --port-forward-4 \"ssh-$VM_NUM:tcp:[127.0.0.1]:$HOST_PORT:[$GUEST_IP]:22\"" </dev/null; then
                            log_info "   ✅ SSH: localhost:$HOST_PORT → $GUEST_IP:22"
                        else
                            log_error "   ❌ Error configurando reenvío para $GUEST_IP"
                        fi
                    done
                    
                    log_info "✅ Reenvío de puertos SSH configurado"
                    log_info "NOTA: Las IPs deben configurarse como ESTÁTICAS dentro de cada VM"
                    
                else
                    log_error "❌ Error creando red NAT-CONTROL '$NET_NAME'"
                    return 1
                fi
                fi
                ;;
                               
            "natnetwork")
                # Verificar si la red ya existe
                if ssh "root@$HOST" "sudo -u $EXAM_USER VBoxManage list natnetworks 2>/dev/null | grep -q $NET_NAME" </dev/null; then
                    log_warning "La red NAT '$NET_NAME' ya existe en $HOST"
                else
                    # Crear la red NAT para examen
                    log_info "Creando red de examen '$NET_NAME' ($NET_CIDR)..."
                    
                    if ssh "root@$HOST" "sudo -u $EXAM_USER VBoxManage natnetwork add --netname \"$NET_NAME\" --network \"$NET_CIDR\" --enable --dhcp on" </dev/null; then
                        log_info "✅ Red de examen '$NET_NAME' creada"
                    else
                        log_error "❌ Error creando red '$NET_NAME'"
                        return 1
                    fi
                fi
                ;;
                
            *)
                log_error "Tipo de red desconocido: $NET_TYPE"
                return 1
                ;;
        esac
    done
    
    return 0
}

mount_directory() {
    local HOST=$1
    local IDS=$2

    log_info "Montando directorio $MOUNT_POINT en $HOST:$OVA_SOURCE_PATH"

    # 1. Crear el directorio de destino si no existe
    ssh "root@$HOST" "sudo mkdir -p \"$OVA_SOURCE_PATH\"" </dev/null
    if [ $? -ne 0 ]; then
        log_error "No se pudo crear el directorio $OVA_SOURCE_PATH en $HOST"
        return 1
    fi

    # 2. Realizar el bind mount
    if ssh "root@$HOST" "sudo mount --bind \"$MOUNT_POINT\" \"$OVA_SOURCE_PATH\"" </dev/null; then
        log_info "✅ Mount realizado: $MOUNT_POINT → $OVA_SOURCE_PATH"
        return 0
    else
        log_error "❌ Fallo al montar $MOUNT_POINT en $OVA_SOURCE_PATH"
        return 1
    fi
}

# Función para crear volúmenes virtuales
create_virtual_volumes() {
    local HOST=$1
    
    log_info "Creando volúmenes para examen en $HOST..."
    
    # Crear directorio para volúmenes
    ssh "root@$HOST" "sudo -u $EXAM_USER mkdir -p \"$VOLUMES_DIR\"" </dev/null
    
    for VOL_NAME in "${!VIRTUAL_VOLUMES[@]}"; do
        VOL_SIZE="${VIRTUAL_VOLUMES[$VOL_NAME]}"
        VOL_PATH="$VOLUMES_DIR/$VOL_NAME.vdi"
        
        # Verificar si el volumen ya existe
        if ssh "root@$HOST" "sudo -u $EXAM_USER test -f \"$VOL_PATH\"" </dev/null; then
            log_warning "El volumen '$VOL_NAME' ya existe en $HOST"
        else
            # Crear disco duro virtual
            log_info "Creando volumen '$VOL_NAME' (${VOL_SIZE}GB)..."
            
            # Convertir GB a MB
            local SIZE_MB=$((VOL_SIZE * 1024))
            
            if ssh "root@$HOST" "sudo -u $EXAM_USER VBoxManage createhd --filename \"$VOL_PATH\" --size $SIZE_MB --format VDI --variant Standard" </dev/null; then
                log_info "✅ Volumen '$VOL_NAME' creado"
            else
                log_error "❌ Error creando volumen '$VOL_NAME'"
                return 1
            fi
        fi
    done
    
    return 0
}
# Función para configurar controladoras de almacenamiento
configure_storage_controllers() {
    local HOST=$1
    local VM_NAME=$2
    
    log_info "Configurando controladoras de almacenamiento para '$VM_NAME'..."
    
    # Buscar la primera controladora SATA
    local SATA_INFO=$(ssh "root@$HOST" "
        sudo -u $EXAM_USER VBoxManage showvminfo \"$VM_NAME\" --machinereadable 2>/dev/null | \
        grep -E '^storagecontrollertype[0-9]+=\"IntelAhci\"' -A 1 | \
        head -2
    " </dev/null 2>/dev/null)
            
    # Si no existe controladora SATA, crear una            
    if [ -z "$SATA_INFO" ]; then
        log_info "Creando controladora SATA..."
        ssh "root@$HOST" "sudo -u $EXAM_USER VBoxManage storagectl \"$VM_NAME\" --name 'SATA' --add sata --controller IntelAHCI --bootable on" </dev/null
        log_info "✅ Controladora SATA creada"
    else
        # Ya existe, mostrar información
        log_info "✅ Controladora SATA ya existe"
        
        # Extraer el nombre actual de la controladora
        local CURRENT_NAME=$(echo "$SATA_INFO" | grep 'storagecontrollername' | sed 's/.*="\([^"]*\)"/\1/')
        log_info "   Nombre actual: '$CURRENT_NAME'"
        
        # Renombrar a 'SATA' si es diferente
        if [ "$CURRENT_NAME" != "SATA" ] && [ -n "$CURRENT_NAME" ]; then
            log_info "Renombrando controladora de '$CURRENT_NAME' a 'SATA'..."
            ssh "root@$HOST" "sudo -u $EXAM_USER VBoxManage storagectl \"$VM_NAME\" --name \"$CURRENT_NAME\" --rename 'SATA'" </dev/null
            log_info "✅ Controladora renombrada a 'SATA'"
        fi
    fi
    
    return 0
}

# Función para vincular volúmenes a la VM
attach_virtual_volumes() {
    local HOST=$1
    local VM_NAME=$2
    
    log_info "Vinculando volúmenes a '$VM_NAME'..."
    
    # Configurar controladoras (asegura que haya una llamada 'SATA')
    configure_storage_controllers "$HOST" "$VM_NAME"
    
    # Vincular cada disco según configuración
    for DISK_CONFIG in "${VM_DISK_CONFIG[@]}"; do
        DISK_NAME="${DISK_CONFIG%%:*}"
        REST_CONFIG="${DISK_CONFIG#*:}"
        CONTROLLER_TYPE="${REST_CONFIG%%:*}"
        DISK_PORT="${REST_CONFIG#*:}"
        
        VOL_PATH="$VOLUMES_DIR/$DISK_NAME.vdi"
        
        # Verificar si el volumen existe
        if ! ssh "root@$HOST" "sudo -u $EXAM_USER test -f \"$VOL_PATH\"" </dev/null; then
            log_error "❌ El volumen '$DISK_NAME' no existe en $HOST"
            continue
        fi
        
        log_info "Vinculando '$DISK_NAME' a '$VM_NAME' (puerto SATA:$DISK_PORT)..."
        
        # Vincular el disco - usando 'SATA'
        if ssh "root@$HOST" "sudo -u $EXAM_USER VBoxManage storageattach \"$VM_NAME\" --storagectl 'SATA' --port $DISK_PORT --device 0 --type hdd --medium \"$VOL_PATH\"" </dev/null; then
            log_info "✅ Volumen '$DISK_NAME' vinculado exitosamente"
        else
            log_error "❌ Error vinculando volumen '$DISK_NAME'"
        fi
    done
    
    return 0
}
# Función para limpiar configuraciones de red previas
clean_existing_networks() {
    local HOST=$1
    local VM_NAME=$2
    
    log_info "Limpiando configuraciones de red previas para '$VM_NAME'..."
    
    # Desactivar TODAS las interfaces de red existentes
    for NIC_NUM in {1..8}; do
        ssh "root@$HOST" "sudo -u $EXAM_USER VBoxManage modifyvm \"$VM_NAME\" --nic$NIC_NUM none 2>/dev/null" </dev/null || true
    done
    
    log_info "✅ Configuraciones previas limpiadas"
}

# Función para configurar redes en la VM
configure_vm_networks() {
    local HOST=$1
    local VM_NAME=$2
    
    log_info "Configurando redes de EXAMEN para '$VM_NAME'..."
    
    # 1. Limpiar configuraciones previas
    clean_existing_networks "$HOST" "$VM_NAME"
    
    # 2. Configurar las redes necesarias
    local NIC_NUM=1
    for NET_CONFIG in "${VM_NETWORK_CONFIG[@]}"; do
        # Separar tipo y nombre si existe
        if [[ "$NET_CONFIG" == *":"* ]]; then
            NET_TYPE="${NET_CONFIG%%:*}"
            NET_NAME="${NET_CONFIG#*:}"
        else
            NET_TYPE="$NET_CONFIG"
            NET_NAME=""
        fi
        
        case $NET_TYPE in
            "nat")
                # NAT estándar
                ssh "root@$HOST" "sudo -u $EXAM_USER VBoxManage modifyvm \"$VM_NAME\" --nic$NIC_NUM nat" </dev/null
                log_info "  NIC$NIC_NUM: NAT (acceso a Internet)"
                ;;
                
            "natnetwork")
                if [ -n "$NET_NAME" ]; then
                    ssh "root@$HOST" "sudo -u $EXAM_USER VBoxManage modifyvm \"$VM_NAME\" --nic$NIC_NUM natnetwork --natnetwork$NIC_NUM \"$NET_NAME\"" </dev/null
                    log_info "  NIC$NIC_NUM: Red de examen '$NET_NAME' (NAT Network)"
                else
                    # Usar primera red NAT disponible
                    local FIRST_NATNET=$(ssh "root@$HOST" "sudo -u $EXAM_USER VBoxManage list natnetworks 2>/dev/null | grep 'NetworkName:' | head -1 | awk '{print \$2}'")
                    if [ -n "$FIRST_NATNET" ]; then
                        ssh "root@$HOST" "sudo -u $EXAM_USER VBoxManage modifyvm \"$VM_NAME\" --nic$NIC_NUM natnetwork --natnetwork$NIC_NUM \"$FIRST_NATNET\"" </dev/null
                        log_info "  NIC$NIC_NUM: Red '$FIRST_NATNET' (NAT Network)"
                    else
                        log_warning "  NIC$NIC_NUM: No hay redes NAT disponibles"
                    fi
                fi
                ;;
                
            "hostonly")
                ssh "root@$HOST" "sudo -u $EXAM_USER VBoxManage modifyvm \"$VM_NAME\" --nic$NIC_NUM hostonly --hostonlyadapter$NIC_NUM vboxnet0" </dev/null
                log_info "  NIC$NIC_NUM: Red de control (Host-Only, 192.168.150.0/24)"
                ;;
                
            "bridged")
                # Detectar interfaz de red activa automáticamente
                local ACTIVE_IFACE=$(ssh "root@$HOST" "
                    # Intentar varios métodos para detectar interfaz activa
                    if ip route | grep default >/dev/null 2>&1; then
                        ip route | grep default | awk '{print \$5}' | head -1
                    elif ip addr show | grep 'state UP' >/dev/null 2>&1; then
                        ip addr show | grep 'state UP' | awk -F': ' '{print \$2}' | grep -v '^lo' | head -1
                    elif [ -f /sys/class/net/eth0/operstate ] && grep -q 'up' /sys/class/net/eth0/operstate 2>/dev/null; then
                        echo 'eth0'
                    elif [ -f /sys/class/net/enp0s3/operstate ] && grep -q 'up' /sys/class/net/enp0s3/operstate 2>/dev/null; then
                        echo 'enp0s3'
                    else
                        echo 'eth0'  # Por defecto
                    fi
                " </dev/null 2>/dev/null)
                
                ACTIVE_IFACE="${ACTIVE_IFACE:-eth0}"
                log_info "Interfaz de red activa detectada: $ACTIVE_IFACE"
                
                ssh "root@$HOST" "sudo -u $EXAM_USER VBoxManage modifyvm \"$VM_NAME\" --nic$NIC_NUM bridged --bridgeadapter$NIC_NUM $ACTIVE_IFACE" </dev/null
                log_info "  NIC$NIC_NUM: Red Bridged ($ACTIVE_IFACE) "
                ;;
                
                
            "internal")
                if [ -n "$NET_NAME" ]; then
                    ssh "root@$HOST" "sudo -u $EXAM_USER VBoxManage modifyvm \"$VM_NAME\" --nic$NIC_NUM intnet --intnet$NIC_NUM \"$NET_NAME\"" </dev/null
                    log_info "  NIC$NIC_NUM: Red interna '$NET_NAME' (sin salida)"
                else
                    log_warning "  NIC$NIC_NUM: Red interna sin nombre, omitiendo"
                    continue
                fi
                ;;
                
            *)
                log_warning "  NIC$NIC_NUM: Tipo de red desconocido '$NET_TYPE', omitiendo"
                continue
                ;;
        esac
        
        # Activar la conexión
        ssh "root@$HOST" "sudo -u $EXAM_USER VBoxManage modifyvm \"$VM_NAME\" --cableconnected$NIC_NUM on" </dev/null
        
        ((NIC_NUM++))
    done
    
    log_info "✅ Redes de examen configuradas para '$VM_NAME' (total: $((NIC_NUM-1)))"
}

# Función para importar una OVA específica
import_ova() {
    local HOST=$1
    local IDS=$2
    local OVA_FILE=$3
    
    # Extraer nombre de la VM del nombre del archivo
    local VM_NAME=$(basename "$OVA_FILE" .ova)
    
    echo "----------------------------------------"
    log_info "Importando: $OVA_FILE"
    log_info "Nombre VM: $VM_NAME"

    # Ejecutar importación
    if ssh "root@$HOST" "sudo -u $EXAM_USER VBoxManage import \"$OVA_FILE\" --vsys 0 --vmname \"$VM_NAME\" --basefolder \"$VM_BASE_PATH\"" </dev/null; then
        log_info "✅ OVA importada exitosamente como '$VM_NAME'"
        
        # Configurar redes específicas
        configure_vm_networks "$HOST" "$VM_NAME"
        
        # Vincular volúmenes a la VM
        attach_virtual_volumes "$HOST" "$VM_NAME"
        
        return 0
    else
        log_error "❌ Error importando OVA '$OVA_FILE'"
        return 1
    fi
}

# Función para configurar SSH sin contraseña en las VMs
configure_vm_ssh_keys() {
    local HOST=$1
    local IDS=$2
    
    # Variables locales para contar
    local COPY_FAILURES=0
    
    # Para guardar detalles de fallos
    local COPY_FAIL_DETAILS=""
    
    # Copiar la clave pública a las VMs
    log_info "Copiando clave pública a las VMs..."
    if [ ! -f /root/.ssh/id_rsa.pub ]; then
        log_error "No se encuentra /root/.ssh/id_rsa.pub. Ejecute primero el script SSH_Generator.sh"
        return 1
    fi
    
    for PORT in "${VM_PORTS[@]}"; do
        log_info "  Procesando VM en puerto $PORT..."

        
        if sshpass -p "$VM_PASSWORD" ssh-copy-id \
            -o StrictHostKeyChecking=accept-new \
            -o ConnectTimeout=5 \
            -o ProxyJump="root@$HOST" \
            -p "$PORT" \
            "root@127.0.0.1" >/dev/null 2>&1; then
            log_info "    ✅ Clave copiada exitosamente a VM (puerto $PORT)"
        else
            ((COPY_FAILURES++))
            log_warning "    ❌ No se pudo copiar clave a VM (puerto $PORT)"
            COPY_FAIL_DETAILS="${COPY_FAIL_DETAILS}puerto $PORT, "
        fi
    done
    
    # Mostrar resumen para este host
    if [ $COPY_FAILURES -eq 0 ]; then
        log_info "✅ SSH sin contraseña configurado en todas las VMs"
    else
        log_warning "⚠️ SSH incompleto: $COPY_FAILURES fallo(s) copiando claves"
    fi
    
    # Guardar contadores en archivos temporales
    echo "$COPY_FAILURES" > "$LOG_DIR/ssh_copy_failures_${HOST}_${IDS}.tmp"
    
    # Guardar detalles de fallos si los hay
    if [ -n "$COPY_FAIL_DETAILS" ]; then
        echo "${COPY_FAIL_DETAILS%, }" > "$LOG_DIR/ssh_copy_details_${HOST}_${IDS}.tmp"
    fi
    return 0
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
        if sshpass -p "$VM_PASSWORD" ssh -o ConnectTimeout=2 -o StrictHostKeyChecking=no \
               -J "root@$HOST" -p "$PORT" root@127.0.0.1 exit 2>/dev/null; then
            return 0
        fi
        sleep $INTERVAL
        ELAPSED=$((ELAPSED + INTERVAL))
    done
    return 1
}

# Función para apagar todas las máquinas virtuales
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

configure_host_audit() {
    local HOST=$1
    local IDS=$2

    log_info "Configurando auditoría de comandos en el host $IDS"

    # 1. Asegurar que auditd está instalado
    ssh "root@$HOST" "
        if ! command -v auditctl >/dev/null 2>&1; then
            echo 'Instalando auditd...'
            if command -v dnf >/dev/null; then
                dnf install -y audit
            elif command -v yum >/dev/null; then
                yum install -y audit
            elif command -v apt-get >/dev/null; then
                apt-get update && apt-get install -y auditd
            else
                echo 'No se pudo instalar auditd, gestor de paquetes no soportado'
                exit 1
            fi
        fi
        
    "

    if [ $? -ne 0 ]; then
        log_error "  Fallo al instalar/verificar auditd en $IDS"
        return 1
    fi

    # 2. Eliminar regla -a task,never si existe (bloquea syscalls)
    ssh "root@$HOST" "
        # Buscar en archivos .rules y comentar la línea
        find /etc/audit/rules.d -type f -name '*.rules' | while read f; do
            if grep -q '^-a task,never' \"\$f\"; then
                sed -i 's/^-a task,never/#&/' \"\$f\"
            fi
        done
        # Limpiar reglas actuales
        auditctl -D >/dev/null 2>&1
    "

    # 3. Añadir reglas execve persistentes (solo si no existen)
    ssh "root@$HOST" "
        RULES_FILE='/etc/audit/rules.d/99-execve.rules'
        touch \"\$RULES_FILE\"
        grep -q '^-a always,exit -F arch=b64 -S execve' \"\$RULES_FILE\" || \\
            echo '-a always,exit -F arch=b64 -S execve -k command_log' >> \"\$RULES_FILE\"
        grep -q '^-a always,exit -F arch=b32 -S execve' \"\$RULES_FILE\" || \\
            echo '-a always,exit -F arch=b32 -S execve -k command_log' >> \"\$RULES_FILE\"
        
        # Regenerar archivo combinado y cargar reglas
        rm -f /etc/audit/audit.rules
        augenrules --load >/dev/null 2>&1
    "

    # 4. Verificar que las reglas están activas
    if ssh "root@$HOST" "auditctl -l | grep -q 'execve'"; then
        log_info "  ✅ Auditoría de comandos configurada correctamente en $IDS"
    else
        log_warning "  ⚠️  No se pudieron verificar las reglas en $IDS"
    fi
}

configure_vm_audit() {
    local HOST=$1
    local IDS=$2   # Solo para logs

    log_info "Configurando auditoría de comandos en las VMs del host $IDS..."

    local VM_COUNT=0
    for VM_PORT in "${VM_PORTS[@]}"; do
        ((VM_COUNT++))
        log_info "  Procesando VM en puerto $VM_PORT..."

	    # 1. Asegurar que auditd está instalado
	     ssh -o ConnectTimeout=30 -o StrictHostKeyChecking=no -J "root@$HOST" -p "$VM_PORT" root@127.0.0.1 "
		if ! command -v auditctl >/dev/null 2>&1; then
		    echo 'Instalando auditd...'
		    if command -v dnf >/dev/null; then
		        dnf install -y audit
		    elif command -v yum >/dev/null; then
		        yum install -y audit
		    elif command -v apt-get >/dev/null; then
		        apt-get update && apt-get install -y auditd
		    else
		        echo 'No se pudo instalar auditd, gestor de paquetes no soportado'
		        exit 1
		    fi
		fi
		
	    "

	    if [ $? -ne 0 ]; then
		log_error "  Fallo al instalar/verificar auditd en $IDS"
		return 1
	    fi

	    # 2. Eliminar regla -a task,never si existe (bloquea syscalls)
	     ssh -o ConnectTimeout=30 -o StrictHostKeyChecking=no -J "root@$HOST" -p "$VM_PORT" root@127.0.0.1 "
		# Buscar en archivos .rules y comentar la línea
		find /etc/audit/rules.d -type f -name '*.rules' | while read f; do
		    if grep -q '^-a task,never' \"\$f\"; then
		        sed -i 's/^-a task,never/#&/' \"\$f\"
		    fi
		done
		# Limpiar reglas actuales
		auditctl -D >/dev/null 2>&1
	    "

	    # 3. Añadir reglas execve persistentes (solo si no existen)
	     ssh -o ConnectTimeout=30 -o StrictHostKeyChecking=no -J "root@$HOST" -p "$VM_PORT" root@127.0.0.1 "
		RULES_FILE='/etc/audit/rules.d/99-execve.rules'
		touch \"\$RULES_FILE\"
		grep -q '^-a always,exit -F arch=b64 -S execve' \"\$RULES_FILE\" || \\
		    echo '-a always,exit -F arch=b64 -S execve -k command_log' >> \"\$RULES_FILE\"
		grep -q '^-a always,exit -F arch=b32 -S execve' \"\$RULES_FILE\" || \\
		    echo '-a always,exit -F arch=b32 -S execve -k command_log' >> \"\$RULES_FILE\"
		
		# Regenerar archivo combinado y cargar reglas
		rm -f /etc/audit/audit.rules
		augenrules --load >/dev/null 2>&1
	    "

	    # 4. Verificar que las reglas están activas
	    if  ssh -o ConnectTimeout=30 -o StrictHostKeyChecking=no -J "root@$HOST" -p "$VM_PORT" root@127.0.0.1  "auditctl -l | grep -q 'execve'"; then
		log_info "  ✅ Auditoría de comandos configurada correctamente en las VMs de $IDS"
	    else
		log_warning "  ⚠️  No se pudieron verificar las reglas en las VMs de $IDS"
	    fi
	done
}

# Función para procesar un host
process_host() {
    local HOST=$1
    local IDS=$2
    
    echo "========================================"
    log_info "Procesando: $HOST (ID: $IDS)"
    echo "========================================"
    
     
    # 1. Verificar si podemos conectar por SSH
    log_info "Verificando conexión SSH..."
    if ! ssh -o ConnectTimeout=5 -o BatchMode=yes "root@$HOST" exit 2>/dev/null; then
        if [ -n "$IDS" ]; then
            log_error "❌ No se puede conectar por SSH a $HOST (ID: $IDS)"
        else
            log_error "❌ No se puede conectar por SSH a $HOST"
        fi
        return 1
    fi
    
    # 2. Verificar que el usuario EXAM_USER existe
    log_info "Verificando usuario '$EXAM_USER'..."
    if ! ssh -o ConnectTimeout=5 "root@$HOST" "id -u $EXAM_USER" >/dev/null 2>&1; then
        if [ -n "$IDS" ]; then
            log_error "❌ El usuario '$EXAM_USER' no existe en $HOST (ID: $IDS)"
        else
            log_error "❌ El usuario '$EXAM_USER' no existe en $HOST"
        fi
    fi
    
    # 3. Verificar que VirtualBox está instalado
    if ! ssh -o ConnectTimeout=5 "root@$HOST" "sudo -u $EXAM_USER which VBoxManage >/dev/null 2>&1" </dev/null; then
        if [ -n "$IDS" ]; then
            log_error "VirtualBox no está instalado en $HOST (ID: $IDS)"
        else
            log_error "VirtualBox no está instalado en $HOST"
        fi
        return 1
    fi
    
    # 4. Verificar que la ruta de OVAs existe en el remoto
    if ! ssh -o ConnectTimeout=5 "root@$HOST" "test -e \"$OVA_SOURCE_PATH\"" </dev/null; then
        if [ -n "$IDS" ]; then
            log_error "La ruta OVA no existe en $HOST (ID: $IDS): $OVA_SOURCE_PATH"
        else
            log_error "La ruta OVA no existe en $HOST: $OVA_SOURCE_PATH"
        fi
        return 1
    fi
    
    # 5. Montar ruta ovas
    if ! mount_directory "$HOST"; then
        log_error "Error montando directorio"
    fi
    
    # 6. Crear redes virtuales
    log_info "Creando redes virtuales..."
    if ! create_virtual_networks "$HOST"; then
        log_error "Error creando redes virtuales (continuando...)"
    fi
    
    # 7. Crear volúmenes virtuales
    log_info "Creando volúmenes virtuales..."
    if ! create_virtual_volumes "$HOST"; then
        log_error "Error creando volúmenes virtuales (continuando...)"
    fi
    
    # 8. Obtener lista de archivos OVA
    log_info "Buscando archivos OVA en: $OVA_SOURCE_PATH"
    
    # Obtener lista de archivos .ova desde el host remoto
    local OVA_FILES
    OVA_FILES=$(ssh "root@$HOST" "find \"$OVA_SOURCE_PATH\" -maxdepth 1 -name '*.ova' -type f 2>/dev/null")
    
    if [ -z "$OVA_FILES" ]; then
        log_error "No se encontraron archivos .ova en $OVA_SOURCE_PATH"
        return 1
    fi
    
    local OVA_COUNT=$(echo "$OVA_FILES" | wc -l)
    log_info "Encontrados $OVA_COUNT archivo(s) OVA"
    
    # 8. Importar cada archivo OVA
    local IMPORT_SUCCESS=0
    local IMPORT_FAILED=0
    local IMPORT_TOTAL=0
    
    while IFS= read -r OVA_FILE; do
        ((IMPORT_TOTAL++))
        
        if import_ova "$HOST" "$IDS" "$OVA_FILE"; then
            ((IMPORT_SUCCESS++))
        else
            ((IMPORT_FAILED++))
            log_error "Fallo importando OVA: $(basename "$OVA_FILE")"
        fi
    done <<< "$OVA_FILES"
    
    # 9. Resumen del host
    echo "----------------------------------------"
    log_info "Resumen para $HOST (ID: $IDS):"
    log_info "  Redes creadas: ${#VIRTUAL_NETWORKS[@]}"
    log_info "  Volúmenes creados: ${#VIRTUAL_VOLUMES[@]}"
    log_info "  Discos vinculados por VM: ${#VM_DISK_CONFIG[@]}"
    log_info "  Total OVAs procesados: $IMPORT_TOTAL"
    log_info "  OVAs importados exitosamente: $IMPORT_SUCCESS"
    if [ $IMPORT_FAILED -gt 0 ]; then
        log_error "  OVAs con errores: $IMPORT_FAILED"
    fi
    
    echo ""
    
    # 10. Configurar SSH con claves para las VMs
    log_info "Configurando SSH con claves para VMs..."
    start_all_virtual_machines "$HOST"
    for PORT in "${VM_PORTS[@]}"; do
    	if wait_for_vm_ready "$HOST" "$PORT"; then
    	    log_info "✅ VM en puerto $PORT encendida"
    	else
            log_error "❌ VM en puerto $PORT no arrancó o tuvo un error"
    	fi
    done
    configure_vm_ssh_keys "$HOST" "$IDS"
    configure_host_audit "$HOST" "$IDS"
    configure_vm_audit "$HOST" "$IDS"
    shutdown_all_virtual_machines "$HOST"

}

# ===========================================
# EJECUCIÓN PRINCIPAL
# ===========================================

# ===========================================
# CONFIGURACIÓN DE LOCK PARA CONDICIONES DE CARRERA
# ===========================================
LOCK_FILE="/tmp/ova_deploy_$$.lock"
exec 200>"$LOCK_FILE"

# Funciones protegidas con lock
increment_counter() {
    local counter_name=$1
    flock -x 200
    eval "$counter_name=\$((\$$counter_name + 1))"
    flock -u 200
}

add_to_failed() {
    local ip=$1
    local ids=$2
    flock -x 200
    FAILED_IPS+=("$ip")
    FAILED_IDS+=("$ids")
    flock -u 200
}

add_to_processed() {
    flock -x 200
    PROCESSED_COUNT=$((PROCESSED_COUNT + 1))
    flock -u 200
}

declare -a TARGET_IDS=("$@")

log_info "INICIANDO DESPLIEGUE DE OVA"
log_info "Ruta OVAs remota: $OVA_SOURCE_PATH"
log_info "Directorio máquinas: $VM_BASE_PATH"
log_info "Directorio volúmenes: $VOLUMES_DIR"
log_info "Redes a crear: ${!VIRTUAL_NETWORKS[@]}"
log_info "Volúmenes a crear: ${!VIRTUAL_VOLUMES[@]}"
log_info "Discos a vincular por VM:"
for DISK_CONFIG in "${VM_DISK_CONFIG[@]}"; do
    DISK_NAME="${DISK_CONFIG%%:*}"
    REST_CONFIG="${DISK_CONFIG#*:}"
    CONTROLLER_TYPE="${REST_CONFIG%%:*}"
    DISK_PORT="${REST_CONFIG#*:}"
    log_info "  - $DISK_NAME -> $CONTROLLER_TYPE Controller, puerto $DISK_PORT"
done


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

# Se verifica qué IDs del archivo coinciden con los especificados
declare -a AVAILABLE_IDS
declare -a FOUND_IDS

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

# Se procesa el archivo
declare -a PIDS
declare -i CURRENT_JOBS=0
declare -i PROCESSED_COUNT=0
declare -i SUCCESS_COUNT=0
declare -i FAILED_COUNT=0

# Función para esperar que haya espacio para más jobs
wait_for_slot() {
    while [ $CURRENT_JOBS -ge $MAX_WORKERS ]; do
        # Esperar a que cualquier job termine
        wait -n
        CURRENT_JOBS=$((CURRENT_JOBS - 1))
        
        # Contar resultados de los jobs que terminaron
        for i in "${!PIDS[@]}"; do
            pid="${PIDS[$i]}"
            if ! kill -0 "$pid" 2>/dev/null; then
                # El proceso terminó
                if wait "$pid" 2>/dev/null; then
                    increment_counter "SUCCESS_COUNT"
                else
                    increment_counter "FAILED_COUNT"
		    if [ -f "$LOG_DIR/pid_${pid}.info" ]; then
			read -r REAL_IP REAL_IDS < "$LOG_DIR/pid_${pid}.info"
			add_to_failed "$REAL_IP" "$REAL_IDS"
			rm "$LOG_DIR/pid_${pid}.info"
		    fi
		fi
		add_to_processed
		unset "PIDS[$i]"
	     fi
        done
        # Reindexar array
        PIDS=("${PIDS[@]}")
        show_progress $PROCESSED_COUNT $PROCESADOS
    done
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

# Procesar cada host
while IFS= read -r HOST; do
    # Saltar líneas vacías y comentarios
    [[ -z "$HOST" ]] && continue
    [[ "$HOST" =~ ^#.* ]] && continue
    IP="${HOST%%:*}"
    IDS="${HOST#*:}"
    
    if [ "$IP" = "$IDS" ]; then
        IDS=""
    fi
    
    ((TOTAL++))
    
    # Si se especificaron IDs y este ID no está en la lista, saltar
    if [ ${#TARGET_IDS[@]} -gt 0 ]; then
        SKIP=true
        for TARGET_ID in "${TARGET_IDS[@]}"; do
            if [ "$IDS" = "$TARGET_ID" ]; then
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
    
    # Lanzar el procesamiento del host en background
    (
        exec < /dev/null          # 🔧 Desconectar stdin del archivo de hosts
        # Crear archivo de log único para este host
        LOG_FILE="$LOG_DIR/host_${IP}_${IDS}.log"
        exec > >(tee -a "$LOG_FILE")
        exec 2>&1
        
        echo "========================================"
        echo "INICIANDO HOST: $IP (ID: $IDS)"
        echo "========================================"
        
        if process_host "$IP" "$IDS"; then
            echo "✅ EXITO: $IP (ID: $IDS)"
            exit 0
        else
            echo "❌ FALLO: $IP (ID: $IDS)"
            exit 1
        fi
    ) &
    
    PID=$!
    PIDS+=($PID)
    CURRENT_JOBS=$((CURRENT_JOBS + 1))
    
    echo "$IP $IDS" > "$LOG_DIR/pid_${PID}.info"
    echo "🚀 Lanzado host $IP (ID: $IDS) - PID: $PID"
    
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
		increment_counter "SUCCESS_COUNT"
            else
                increment_counter "FAILED_COUNT"
                if [ -f "$LOG_DIR/pid_${pid}.info" ]; then
                    read -r REAL_IP REAL_IDS < "$LOG_DIR/pid_${pid}.info"
                    add_to_failed "$REAL_IP" "$REAL_IDS"
                    rm "$LOG_DIR/pid_${pid}.info"
                fi
            fi
            add_to_processed
            # Eliminar el PID del array
            unset "PIDS[$i]"
        fi
    done
    # Reindexar array
    PIDS=("${PIDS[@]}")
    show_progress $PROCESSED_COUNT $PROCESADOS
    sleep 1
done

echo ""
echo "========================================"

SUCCESS=$SUCCESS_COUNT
FAILED=$FAILED_COUNT

echo "========================================"
log_info "RESUMEN FINAL"
echo "========================================"
FIN=$(date +%s)
DURACION=$((FIN - INICIO))
log_info "Tiempo total de ejecución: ${DURACION} segundos"
log_info "Total hosts: $TOTAL"

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
# ===========================================
# ESTADÍSTICAS SSH DETALLADAS
# ===========================================

echo ""
log_info "RESUMEN DE CONFIGURACIÓN SSH:"

# Buscar todos los archivos temporales de SSH
SSH_COPY_FILES=("$LOG_DIR"/ssh_copy_failures_*.tmp)

# Inicializar contadores y arrays
REAL_SSH_KEY_FAILURES=0
declare -a HOSTS_WITH_COPY_FAILURES
declare -a HOSTS_WITH_SSH_SUCCESS

# Procesar archivos de copia
for file in "${SSH_COPY_FILES[@]}"; do
    if [[ -f "$file" ]]; then
        # Extraer host e ID del nombre del archivo
        if [[ "$file" =~ ssh_copy_failures_(.+)_(.+)\.tmp ]]; then
            HOST="${BASH_REMATCH[1]}"
            ID="${BASH_REMATCH[2]}"
            
            FAILURES=$(cat "$file")
            if [ $FAILURES -gt 0 ]; then
                REAL_SSH_KEY_FAILURES=$((REAL_SSH_KEY_FAILURES + FAILURES))
                # Buscar detalles
                DETAILS_FILE="$LOG_DIR/ssh_copy_details_${HOST}_${ID}.tmp"
                DETAILS=""
                if [ -f "$DETAILS_FILE" ]; then
                    DETAILS=" (fallos en: $(cat "$DETAILS_FILE"))"
                    rm "$DETAILS_FILE"
                fi
                HOSTS_WITH_COPY_FAILURES+=("$HOST (ID: $ID): $FAILURES fallo(s)$DETAILS")
            else
                # Host sin fallos de copia
                HOST_KEY="$HOST:$ID"
                if [[ ! " ${HOSTS_WITH_SSH_SUCCESS[@]} " =~ " ${HOST_KEY} " ]]; then
                    HOSTS_WITH_SSH_SUCCESS+=("$HOST_KEY")
                fi
            fi
            rm "$file"
        fi
    fi
done

# Contar hosts que intentaron SSH
TOTAL_SSH_HOSTS=$((${#HOSTS_WITH_COPY_FAILURES[@]} + ${#HOSTS_WITH_SSH_SUCCESS[@]}))

if [ $TOTAL_SSH_HOSTS -gt 0 ]; then
    log_info "Hosts que configuraron SSH: $TOTAL_SSH_HOSTS"
    
    # Mostrar hosts con éxito completo
    if [ ${#HOSTS_WITH_SSH_SUCCESS[@]} -gt 0 ]; then
        log_info "✅ Hosts con SSH configurado EXITOSAMENTE: ${#HOSTS_WITH_SSH_SUCCESS[@]}"
        for host_key in "${HOSTS_WITH_SSH_SUCCESS[@]}"; do
            IFS=':' read -r HOST ID <<< "$host_key"
            log_info "   ✓ $HOST (ID: $ID) - SSH configurado correctamente"
        done
    fi
    
    # Mostrar hosts con fallos de copia
    if [ ${#HOSTS_WITH_COPY_FAILURES[@]} -gt 0 ]; then
        log_warning "⚠️ Hosts con FALLOS copiando claves SSH: ${#HOSTS_WITH_COPY_FAILURES[@]}"
        for host_fail in "${HOSTS_WITH_COPY_FAILURES[@]}"; do
            log_warning "   ✗ $host_fail"
        done
    fi
    
    # Resumen general
    if [ $REAL_SSH_KEY_FAILURES -eq 0 ]; then
        log_info "✅ SSH configurado EXITOSAMENTE en TODAS las VMs de TODOS los hosts"
    else
        log_warning "⚠️ Configuración SSH con ALGUNOS fallos:"
        log_warning "   - Fallos copiando claves: $REAL_SSH_KEY_FAILURES máquina(s)"
    fi
    
    echo $final
    
else
    log_warning "No se configuró SSH en ningún host (no había VMs o fallaron antes)"
fi

# Limpiar cualquier archivo temporal restante
rm -f "$LOG_DIR"/ssh_*.tmp 2>/dev/null
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


