#!/bin/bash
# ===========================================
# CONFIGURACIÓN COMÚN PARA TODOS LOS SCRIPTS
# ===========================================

# Archivos y rutas base
HOSTS_FILE="/home/pruebas/Documentos/host.txt" # Ruta del archivo de anfitriones
EXAM_USER="examen" # Nombre de usuario que tendrá la cuenta de examen generada en los anfitriones
VM_USER="user1" # Nombre de usuario que tiene la máquina virtual donde el alumno tiene que trabajar
EVIDENCE_BASE_DIR="/home/pruebas/Evidencias" # Directorio donde se guardarán las evidencias (debe existir o se creará)
VALIDATION_SCRIPTS_DIR="/home/pruebas/scripts_validacion" # Ruta donde se encuentran los scripts de validación

# Rutas de recursos a copiar (PC_ADMIN) 
EXAM_RESOURCES_PATH_HOST="/home/pruebas/Documentos/RecursosExamen/Host"  # Para el anfitrión
EXAM_RESOURCES_PATH_VMS="/home/pruebas/Documentos/RecursosExamen/VMs" # Para las máquinas virtuales

# Rutas remotas donde se copian los recursos 
REMOTE_EXAM_PATH_HOST="/home/$EXAM_USER/examen_host" # En el anfitrión
REMOTE_EXAM_PATH_VMS="/home/$VM_USER/examen_vm"  # Dentro de cada VM

# Directorios donde los estudiantes guardarán sus respuestas (evidencias)
EVIDENCES_HOST_PATH="/home/$EXAM_USER/evidencias_host" # En el anfitrión
EVIDENCES_VM_PATH="/home/$VM_USER/evidencias_vm" # En la máquina virtual

# Configuración de redes y puertos
VM_PORTS=(2222)   # Puedes añadir más: (2222 2223 2224)
IP_LOCAL=$(hostname -I | awk '{print $1}') # Variable para obtener la IP del sistema en el que se está ejecutando el script
ALLOWED_IPS="$IP_LOCAL 192.168.15.105" # IPs desde las cuales se permitirá el tráfico

# Concurrencia
MAX_WORKERS=5 # Máximo de hosts procesados en paralelo

# Despliegue de OVAs
OVA_SOURCE_PATH="/mnt" # Directorio donde se montará la ubicación de los Ovas
MOUNT_POINT="/mnt/Ova" # Directorio NFS donde se encuentran los Ovas a Instalar
VM_BASE_PATH="/home/$EXAM_USER/Escritorio/Maquinas_Virtuales" # Directorio remoto donde se instalarán las máquinas virtuales
VOLUMES_DIR="$VM_BASE_PATH/volumenes" # Directorio remoto donde se instalarán los discos creados

# Configuración de redes

# Formato: nombre_red=tipo:subred
# Declarar redes ha añadir en VirtualBox
declare -A VIRTUAL_NETWORKS=(
    ["red-nat-control"]="nat-control:192.168.150.0/24" # Red de control obligatoria NO ELIMINAR
    ["red-examen"]="natnetwork:192.168.100.0/24" # Ejemplo de Red principal del examen
)

# Redes que se vincularán a las VMs Importadas
# Formato: tipo_de_red:nombre (si procede)
declare -a VM_NETWORK_CONFIG=(
    "natnetwork:red-nat-control" # Red de control obligatoria NO ELIMINAR
    "natnetwork:red-examen" # Ejemplo de Red principal del examen
)

# Configuración de volúmenes 

# Formato: nombre:tamaño_en_GB
# Declarar discos ha añadir en VirtualBox
declare -A VIRTUAL_VOLUMES=(
    ["disco-examen"]="20" # Ejemplo de Disco principal para el examen
    ["disco-datos"]="10" # Ejemplo de Disco adicional para datos
)

# Discos que se vincularán a las VMs Importadas
# ****** IMPORTANTE ****
# Tener en cuenta que si las máquinas importan algun disco estos se sobreescribiran por los detallados a continuación si utilizan el mismo puerto
# Formato: nombre:SATA:Puerto_SATA
declare -a VM_DISK_CONFIG=(
    "disco-examen:SATA:1"
    "disco-datos:SATA:2"
)

# ==================================================
# CONFIGURACIÓN DE LOGS, NO ES NECESARIO MODIFICARLA
# ==================================================

# --- Colores para mensajes ---
export RED='\033[0;31m'
export GREEN='\033[0;32m'
export YELLOW='\033[1;33m'
export BLUE='\033[0;34m'
export NC='\033[0m' # No Color

# --- Funciones de log ---
log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
