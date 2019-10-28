#!/bin/bash
#
# Download the current file(s) from Google Drive and restore them into the current folder.
# This script will create a config file in your /home directory with only user access. Keep that file secret!!

declare DIR=$(dirname "${BASH_SOURCE[0]}")
source "$DIR/google-drive.sh"

###############################################################################

# default config values
declare BASE_NAME=$(basename "$0")
CONFIG_FILE=~/".$BASE_NAME.cfg"

# global variables
declare HOSTNAME=$(hostname)
declare BACKUP_FOLDER=
declare -a FILES

function download(){
    log "download($*)" 3

    local QUERY="'${DRIVE_ROOT_DIR}' in parents and mimeType='${FOLDERMIMETYPE}' and name='Backup'"
    local SEARCH_RESPONSE=$(getFileList "${QUERY}" "id" "name")

    local BACKUP_FOLDER=$(echo ${SEARCH_RESPONSE} | jsonValue id 1)

    if [ -z "${BACKUP_FOLDER}" ]; then
        log "Backup-Folder not found" -1
        exit 3
    fi

    local QUERY="'${BACKUP_FOLDER}' in parents and mimeType='${FOLDERMIMETYPE}' and name='${HOSTNAME}'"
    local SEARCH_RESPONSE=$(getFileList "${QUERY}" "id" "name")
    local HOST_FOLDER=$(echo ${SEARCH_RESPONSE} | jsonValue id 1)

    if [ -z "${HOST_FOLDER}" ]; then
        log "Host-Folder not found" -1
        exit 3
    fi

    # inspect files
    local QUERY="'${HOST_FOLDER}' in parents and mimeType!='${FOLDERMIMETYPE}'"
    local SEARCH_RESPONSE=$(getFileList "${QUERY}" "id,name" "name")

    local -a FILE_IDs
    local -a FILE_NAMEs
    readarray -t FILE_IDs < <(echo ${SEARCH_RESPONSE} | jsonValue 'id')
    readarray -t FILE_NAMEs < <(echo ${SEARCH_RESPONSE} | jsonValue 'name')

    local -i i
    for (( i = "${#FILE_NAMEs[@]}"; i >= 0; i-- )); do
        if [ "${FILE_NAMEs[i]:(-9)}" == ".full.bkp" ]; then
            FILE_IDs=("${FILE_IDs[@]:i}")
            FILE_NAMEs=("${FILE_NAMEs[@]:i}")
            break
        fi
    done

    if [ "${FILE_NAMEs[0]:(-9)}" != ".full.bkp" ]; then
        log "Cannot detect last full backup" -1
        exit 3
    fi

    local TMPFOLDER=$(downloadSpecificFiles "${FILE_IDs[@]}" "${FILE_NAMEs[@]}")
    if [ -z "${TMPFOLDER}" ]; then
        log "tmp-folder not created" -1
        exit 3
    fi

    local -a FILES=("${TMPFOLDER}"/*)
    echo ${FILES[@]@Q}
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
         --ignore-missing  continue on missing files/folders
 -n,     --hostname=<name> name of the host
                           (defaults to $HOSTNAME)
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
download
