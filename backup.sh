#!/bin/bash
#
# Creates or restores (incremental) backups and en/decrypts them
#
# Dependencies
#   - curl
#   - gpg

###############################################################################

# default config values
declare IGNORE_MISSING_FILES=false
declare BASE_NAME=$(basename "$0")
declare CONFIG_FILE=~/".$BASE_NAME.cfg"
declare CREATE_BACKUP=false
declare RESTORE_BACKUP=false
declare PASSPHRASE=
declare -i RESET_WEEKDAY=7
declare -i VERBOSE=0

# global variables
declare -a FILES

###############################################################################

function log() {
    local msg="$1"
    local -i verbosity="${2:-0}"

    if [ "${VERBOSE}" -gt "${verbosity}" ]; then
        >&2 echo -e "${msg}"
    fi
}

function includeConfigData() {
    log "includeConfigData($*)" 3

    if [ -f "${CONFIG_FILE}" ]; then
        log "read config file ${CONFIG_FILE}" 2
        source "${CONFIG_FILE}"
    fi
}

# create a new backup file. Needs one argument: file/folder to backup
function create() {
    log "create($*)" 3
    local files=("$@")

    local i
    local -a canonical
    for (( i = 0; i < ${#files[@]}; i++ )); do
        canonical[i]=$(cd "${files[i]}" && pwd)
    done

    # sort files
    readarray -t canonical < <(printf '%s\0' "${canonical[@]}" | sort -z | xargs -0n1)

    local -a basenames
    for (( i = 0; i < ${#canonical[@]}; i++ )); do
        basenames[i]=$(basename "${canonical[i]}")
    done

    local md5=$(echo "${canonical[@]}" | md5sum -t -)
    md5="${md5/ *}"

    names=$(IFS=','; echo "${basenames[*]}")

    local date=$(date -uIseconds)
    date=${date::-6}
    local snarfile="${md5}-${names}.snar"
    local encrypted="${md5}-${names}-${date}"

    if [ "${RESET_WEEKDAY}" -ne -1 ]; then
        local -i weekday=$(date -u +%u) # (1..7)
        if [ "${RESET_WEEKDAY}" -eq 0 ] || [ "${weekday}" -eq "${RESET_WEEKDAY}" ]; then
            log "remove file list for incremental backups" 2
            rm -f "${snarfile}"
        fi
    fi

    if [ -f "${snarfile}" ]; then
        encrypted+=".inc"
    else
        encrypted+=".full"
    fi
    encrypted+=".bkp"

    tar \
        --create \
        --force-local \
        --file=- \
        --keep-directory-symlink \
        --listed-incremental="${snarfile}" \
        "${canonical[@]}" \
        | gpg \
            --passphrase="${PASSPHRASE}" \
            --quiet \
            --output="${encrypted}" \
            --symmetric \
            --cipher-algo=TWOFISH \
            --batch \
            --yes \
            --compression-algo=zlib \
            -z9
    echo "${encrypted}"
}

# restore backup files into current folder
function restore() {
    log "restore($*)" 3
    local files=("$@")

    # sort files
    readarray -t files < <(printf '%s\0' "${files[@]}" | sort -z | xargs -0n1)

    # filter to the last full backup (and all it's incremental backups)
    local -i i
    for (( i = "${#files[@]}"; i >= 0; i-- )); do
        if [ "${files[i]:(-9)}" == ".full.bkp" ]; then
            files=("${files[@]:i}")
            break
        fi
    done
    log "Files used to create restore: ${files[*]}" 0

    local folder="restore-$(date -uIseconds)"

    mkdir -p "${folder}"
    cp "${files[@]}" "${folder}"

    pushd "${folder}" > /dev/null
    for f in *; do
        mv -- "$f" "$f.gpg"
    done

    gpg \
        --quiet \
        --batch \
        --decrypt-files \
        --passphrase="${PASSPHRASE}" \
        *.gpg

    rm -f *.gpg

    local file
    for file in *; do
        tar \
            --extract \
            --force-local \
            --listed-incremental=/dev/null \
            --preserve-permissions \
            -C .. \
            --file="${file}"
    done

    rm ./*.bkp
    for file in "${files[@]}"; do
        rm "$file"
    done

    # copy files... (manual action)
    log "files restored in \n\033[01;37m$(pwd)\033[00m" -1
    popd > /dev/null
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
 -b,     --backup          creates a backup (default)
 -r,     --restore         restores a backup
 -p <v>, --passphrase=<v>  use the given passphrase to en/decrypt
          --reset-weekday=<o>  day on which a new full backup is created
                            -1 = never (after first one)
                             0 = always
                             1 = monday
                             7 = sunday (default)

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
    local optspec=":c:bhpqrv-:"
    local val optchar
    local err=0

    while getopts "$optspec" optchar "$@"; do
        if [ "${optchar}" == '-' ]; then
            case "${OPTARG}" in
                backup)
                    optchar='b'
                    ;;
                config=*)
                    optchar='c'
                    OPTARG="${OPTARG#*=}"
                    ;;
                help)
                    optchar='h'
                    ;;
                ignore-missing)
                    IGNORE_MISSING_FILES=true
                    ;;
                passphrase=*)
                    optchar='p'
                    OPTARG="${OPTARG#*=}"
                    ;;
                quiet)
                    optchar='q'
                    ;;
                reset-weekday=*)
                    OPTARG="${OPTARG#*=}"
                    if [ "${OPTARG:0:1}" == "-" ]; then
                        RESET_WEEKDAY=-1
                    elif [ "${OPTARG:0:1}" != "" ]; then
                        RESET_WEEKDAY=$(( (OPTARG - 1) % 7 + 1 ))
                    fi
                    ;;
                restore)
                    optchar='r'
                    ;;
                verbose=*)
                    OPTARG="${OPTARG#*=}"
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
            b)
                if "${RESTORE_BACKUP}"; then
                    echo "Cannot create backup and restore at the same time" >&2
                    err=1
                fi
                CREATE_BACKUP=true
                ;;
            c)
                CONFIG_FILE="${OPTARG}"
                ;;
            h)
                show_help
                exit 0
                ;;
            p)
                PASSPHRASE="${OPTARG}"
                ;;
            q)
                VERBOSE=$((VERBOSE-1))
                ;;
            r)
                if "${CREATE_BACKUP}"; then
                    echo "Cannot create backup and restore at the same time" >&2
                    err=1
                fi
                RESTORE_BACKUP=true
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

if ! "${CREATE_BACKUP}" && ! "${RESTORE_BACKUP}"; then
    CREATE_BACKUP=true
fi

if [ -z "${PASSPHRASE}" ]; then
    log "Cannot backup/restore without passphrase" -1
    exit 1
fi

# execute
if "${CREATE_BACKUP}"; then
    create "${FILES[@]}"
elif "${RESTORE_BACKUP}"; then
    restore "${FILES[@]}"
fi
