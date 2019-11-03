#!/bin/bash
#
# Uploads a file or folder to Google Drive with backup semantics (store files in Backup/{HOSTNAME}/{DATE}/ and delete old folder)
# This script will create a config file in your /home directory with only user access. Keep that file secret!!
#
# With the google API scope https://www.googleapis.com/auth/drive.file, you are allowed to write/delete files
# that were created with the same client_id, only. If you want full access, use https://www.googleapis.com/auth/drive instead

declare DIR=$(dirname "${BASH_SOURCE[0]}")
source "$DIR/google-drive.sh"

###############################################################################

# default config values
declare -i DAYS_TO_KEEP=10
SKIP_DELETE_OLD=false
IGNORE_MISSING_FILES=false
BASE_NAME=$(basename "$0")
CONFIG_FILE=~/".$BASE_NAME.cfg"

# global variables
declare HOSTNAME=$(hostname)
[ "$HOSTNAME" == "localhost" ] && command -v cloud-init >/dev/null && HOSTNAME=$(cloud-init query ds.meta_data.public_hostname)

BACKUP_FOLDER=
declare -a FILES

# Method to delete old files in a directory of google drive. Requires 1 argument root directory id.
function deleteOldFiles(){
    log "deleteOldFiles($*)" 3

    local ROOTDIR="$1"

    local OLDDATE=$(date -Iseconds -u -d "-${DAYS_TO_KEEP} days")
    local QUERY="'${ROOTDIR}' in parents and modifiedTime < '${OLDDATE}'"

    deleteFiles "${QUERY}"
}

# Method to create the minimum folder structure /Backup/{HOSTNAME}
function createBackupFolder() {
    log "createBackupFolder($*)" 3

    # we don't store directly into the root
    local FOLDER_BACKUP=$(createDirectory Backup "${DRIVE_ROOT_DIR}")

    # every host uses its own subdirectory
    BACKUP_FOLDER=$(createDirectory "${HOSTNAME}" "${FOLDER_BACKUP}")
}

# Create a folder with the current UTC date
function createDateFolder() {
    log "createDateFolder($*)" 3

    if [ -z ${BACKUP_FOLDER} ]; then
        createBackupFolder
    fi

    local BACKUPDATE=$(date -Iseconds -u)
    BACKUPDATE="${BACKUPDATE::-6}"

    local FOLDER_DATE=$(createDirectory "${BACKUPDATE}" "${BACKUP_FOLDER}")

    echo "${FOLDER_DATE}"
}

# Upload a file or a folder. Requires 2 arguments: root directory id and local file
function upload() {
    log "upload($*)" 3

    local DIRECTORY_ID="$1"
    local FILE="$2"

    if [ -f "${FILE}" ]; then
        uploadFile "${FILE}" "${DIRECTORY_ID}"
        wait
    elif [ -d "${FILE}" ]; then
        uploadFolder "${FILE}" "${DIRECTORY_ID}"
        wait
    fi
}

function backupFiles() {
    log "backupFiles($*)" 3

    local f
    for f in "$@"; do
        if [ -r ${file} ]; then
            if [ -z "${BACKUP_FOLDER}" ]; then
                createBackupFolder
            fi

            upload "${BACKUP_FOLDER}" "${f}"
        fi
    done
}

# test if files/folders exists and are readable and recreate FILES-Array
function testFiles() {
    log "testFiles($*)" 3
    local file
    local result=()
    for file in "${FILES[@]}"; do
        if [ ! -r "${file}" ]; then
            log "Could not find '${file}'" -1
            if ! "${IGNORE_MISSING_FILES}"; then
                exit 3
            fi
        else
            result+=("${file}")
        fi
    done
    FILES=("${result[@]}")
}

function show_help() {
    cat <<EOF
Usage:
 $BASE_NAME [Options] <file/folder ...>
 $BASE_NAME [Options] -- <file/folder ...>

Options:
 -c,     --config=<file>   sets the config file to use
                           (defaults to ~/".$BASE_NAME.cfg")
 -n,     --hostname=<name> name of the host
                           (defaults to $HOSTNAME)
         --skip-delete-old skips the deletion of old backup entities
         --ignore-missing  continue on missing files/folders
 -k <n>, --keep-days=<n>   delete backup files that are older than n days
                           (defaults to 10)

 -q,     --quiet           decrements verbosity by one
 -v,     --verbose         increments verbosity by one
         --verbose=<n>     sets the verbosity to n
                             -1 = no output at all
                              0 = errors only (default)
                              5 = debug
 -h,     --help            display this help and exit
EOF
}

# command line arguments

function parse_args() {
    local optspec=":c:hqnv-:"
    local val optchar
    local err=0

    while getopts "$optspec" optchar "$@"; do
        if [ "${optchar}" == '-' ]; then
            case "${OPTARG}" in
                config=*)
                    optchar='c'
                    OPTARG=${OPTARG#*=}
                    ;;
                hostname=*)
                    optchar='n'
                    OPTARG=${OPTARG#*=}
                    ;;
                help)
                    optchar='h'
                    ;;
                ignore-missing)
                    IGNORE_MISSING_FILES=true
                    ;;
                quiet)
                    optchar='q'
                    ;;
                skip-delete-old)
                    SKIP_DELETE_OLD=true
                    ;;
                verbose=*)
                    OPTARG=${OPTARG#*=}
                    VERBOSE=${OPTARG}
                    ;;
                verbose)
                    optchar='v'
                    ;;
                *)
                    echo "Unknown option --${OPTARG}" >&2
                    err=1
                    ;;
            esac
        fi

        case "${optchar}" in
            -)
                ;;
            c)
                CONFIG_FILE=${OPTARG}
                ;;
            h)
                show_help
                exit 0
                ;;
            n)
                HOSTNAME=${OPTARG}
                ;;
            q)
                VERBOSE=$((VERBOSE-1))
                ;;
            v)
                VERBOSE=$((VERBOSE+1))
                ;;
            *)
                if [ "$OPTERR" != 1 ] || [ "${optspec:0:1}" = ":" ]; then
                    echo "Non-option argument: '-${OPTARG}'" >&2
                    err=1
                fi
                ;;
        esac
    done

    if [ "$err" -ne 0 ]; then
        exit 2
    fi
}

# command line args
parse_args "$@"
shift $((OPTIND - 1))

FILES=("$@")
testFiles

# execute
initialize
backupFiles "${FILES[@]}"

if ! "${SKIP_DELETE_OLD}"; then
    if [ -z "${BACKUP_FOLDER}" ]; then
        createBackupFolder
    fi
    deleteOldFiles "${BACKUP_FOLDER}"
fi
