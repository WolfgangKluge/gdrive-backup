#!/bin/bash

# Manages Google Drive files and folders
# This script will create a config file in your /home directory with only user access. Keep that file secret!!
#
# With the google API scope https://www.googleapis.com/auth/drive.file, you are allowed to write/delete files
# that were created with the same client_id, only. If you want full access, use https://www.googleapis.com/auth/drive instead
#
# Usage: backup-to-google-drive <file or folder>
#
# You'll need a google account and a configured oauth2.0 token (http://console.developers.google.com/)
# Optionally, you can define an API-Key to easier distinguish between different clients

#Configuration variables
declare API_KEY=
declare CLIENT_ID=
declare CLIENT_SECRET=
declare REFRESH_TOKEN=
declare CONFIG_FILE=
declare -i VERBOSE=0

#Internal variable
readonly TOKEN_URI='https://accounts.google.com/o/oauth2/token'
readonly API_ENDPOINT='https://www.googleapis.com/drive/v3'
readonly SCOPE='https://www.googleapis.com/auth/drive.file'
readonly FOLDERMIMETYPE='application/vnd.google-apps.folder'

readonly DRIVE_ROOT_DIR='root'

declare ACCESS_TOKEN=
declare TOKEN_TYPE=

###############################################################################

function log() {
    local msg="$1"
    local -i verbosity="${2:-0}"

    if [ "${VERBOSE}" -gt "${verbosity}" ]; then
        >&2 echo -e "${msg}"
    fi
}

function updateConfig() {
    log "updateConfig($*)" 3

    local name="$1"
    local value="${!name}"

    if [ -f "${CONFIG_FILE}" ]; then
        sed -i /^${name}=/d "${CONFIG_FILE}"
    fi

    if [ ! -z "${value}" ]; then
        if [ ! -f "${CONFIG_FILE}" ]; then
            touch "${CONFIG_FILE}"
            chmod u=rw,g=,o= "${CONFIG_FILE}"
        fi

        echo "${name}=${value}" >> "${CONFIG_FILE}"
    fi
}

function ensureMinimumConfigValue() {
    log "ensureMinimumConfigValue($*)" 3

    local name="$1"
    local usage="${2:-mandatory}"

    if [ -z "${!name}" ]; then
        read -p "${name}: " "${name}";
        if [ -z "${!name}" ] && [ "${usage}" == 'mandatory' ]; then
            log "No value for ${name} provided. Abort" -1
            exit 1
        fi

        updateConfig "${name}"
    fi
}

function ensureMinimumConfig() {
    log "ensureMinimumConfig($*)" 3

    if [ -z "${CLIENT_ID}" ]; then
        ensureMinimumConfigValue API_KEY optional
        ensureMinimumConfigValue REFRESH_TOKEN optional
    fi
    ensureMinimumConfigValue CLIENT_ID
    ensureMinimumConfigValue CLIENT_SECRET
}

# Method to extract data from json response
# use $(readarray -t ids < <(echo $values | jsonValue 'id')) to extract multiple values
function jsonValue() {
    local KEY=$1
    local num=$2

    grep -oP "\"${KEY}\"\s*:\s*(?:\"(?:\\\\.|[^\"])*\"|[a-z0-9\d.]+)" | sed -n ${num}p | sed -r "s/\"${KEY}\"\s*:\s*\"?|\"$//g"
    #awk -F"[,:}][^://]" '{for(i=1;i<=NF;i++){if($i~/\042'${KEY}'\042/){print $(i+1)}}}' | tr -d '"' | sed -n ${num}p | sed -e 's/[}]*$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/[,]*$//'
}

function docurl(){
    if [ "${VERBOSE}" -gt "4" ]; then
        local url=
        local data=
        local i
        for (( i = 1; i <= $#; i++ )); do
            local arg="${@:i:1}"

            if [ "${arg:0:1}" != '-' ]; then
                url=${arg}
            fi

            if [ "${arg:0:2}" == '-d' ] || [ "${arg:0:6}" == '--data' ]; then
                local val=${@:i + 1:1}
                if [ "${val#*=}" != '' ]; then
                    data="${data}\x20 \x20 ${val}\n"
                fi
                i=$((i + 1))
            fi
        done
        log "-- Request: ----------------\n${url}\n${data:0:-2}" 4
    fi

    local RESPONSE=$(curl "$@")
    log "-- Response: ---------------\n${RESPONSE}\n----------------------------" 4

    echo ${RESPONSE}
}

# Method to create directory in google drive. Requires 2 arguments: foldername and root directory id.
function createDirectory(){
    log "createDirectory($*)" 3

    local DIRNAME="$1"
    local ROOTDIR="$2"

    local FOLDER_ID=""
    local QUERY="'${ROOTDIR}' in parents and mimeType='${FOLDERMIMETYPE}' and name='${DIRNAME}'"

    local SEARCH_RESPONSE=$(getFileList "${QUERY}" "id" "name")
    local FOLDER_ID=$(echo ${SEARCH_RESPONSE} | jsonValue id 1)

    if [ -z "${FOLDER_ID}" ]; then
        log "Create folder ${DIRNAME}"
        local CREATE_FOLDER_POST_DATA="{\
            \"mimeType\": \"${FOLDERMIMETYPE}\",\
            \"name\": \"${DIRNAME}\",\
            \"parents\": [\"${ROOTDIR}\"]\
        }"
        local CREATE_FOLDER_RESPONSE=$(docurl \
                                --silent  \
                                -X POST \
                                -H "Authorization: ${TOKEN_TYPE} ${ACCESS_TOKEN}" \
                                -H "Content-Type: application/json; charset=UTF-8" \
                                --data "${CREATE_FOLDER_POST_DATA}" \
                                "${API_ENDPOINT}/files?fields=id,parents&key=${API_KEY}")
        FOLDER_ID=$(echo ${CREATE_FOLDER_RESPONSE} | jsonValue id 1)
    fi
    echo "${FOLDER_ID}"
}

# Method to download files. Requires a single argument: query.
# Files with the same name in the same directory are overwritten!!
function downloadFiles(){
    log "downloadFiles($*)" 3

    local QUERY="$1"

    local SEARCH_RESPONSE=$(getFileList "${QUERY}" "id,name" "name")

    local -a FILE_IDs
    local -a FILE_NAMEs

    readarray -t FILE_IDs < <(echo ${SEARCH_RESPONSE} | jsonValue 'id')
    readarray -t FILE_NAMEs < <(echo ${SEARCH_RESPONSE} | jsonValue 'name')

    downloadSpecificFiles "${FILE_IDs[@]}" "${FILE_NAMEs[@]}"
}

# download files with names. Requires 2 arrays of same size! file ids and file names
function downloadSpecificFiles(){
    log "downloadSpecificFiles($*)" 3

    local -a ALL=("$@")

    local -i i=$((${#ALL[@]} / 2))
    local -a FILE_IDs=("${ALL[@]:0:($i)}")
    local -a FILE_NAMEs=("${ALL[@]:($i)}")

    local tmpDir=$(mktemp -d)

    local -i i
    for (( i = 0; i < ${#FILE_IDs[@]}; i++ )); do
        local FILE_ID="${FILE_IDs[i]}"
        local FILE_NAME="${FILE_NAMEs[i]}"

        $(docurl \
            --output "${tmpDir}/${FILE_NAME}" \
            -X GET \
            -H "Authorization: ${TOKEN_TYPE} ${ACCESS_TOKEN}" \
            --get \
            --data "key=${API_KEY}" \
            --data "alt=media" \
            "${API_ENDPOINT}/files/${FILE_ID}")
    done

    echo "${tmpDir}"
}

# Method to delete files in a directory of google drive. Requires a single argument: query.
function deleteFiles(){
    log "deleteFiles($*)" 3

    local QUERY="$1"

    local SEARCH_RESPONSE=$(getFileList "${QUERY}")

    local -a FILE_IDs
    readarray -t FILE_IDs < <(echo ${SEARCH_RESPONSE} | jsonValue 'id')

    local FILE_ID
    for FILE_ID in "${FILE_IDs}"; do
        log "Delete ${FILE_ID}" 1
        $(docurl \
            --silent  \
            -X DELETE \
            -H "Authorization: ${TOKEN_TYPE} ${ACCESS_TOKEN}" \
            -H "Content-Type: application/json; charset=UTF-8" \
            --get \
            --data "key=${API_KEY}" \
            "${API_ENDPOINT}/files/${FILE_ID}")
    done
}

# Method to get a list of files. Requires a single argument: query. Optiona arguments are: fields (defaults to "id,name") and orderBy (defaults to "name")
function getFileList(){
    log "getFileList($*)" 3

    local QUERY="$1"
    local FIELDS="${2:-id,name}"
    local ORDERBY="${3:-name}"

    echo $(docurl \
            --silent \
            -X GET \
            -H "Authorization: ${TOKEN_TYPE} ${ACCESS_TOKEN}" \
            --get \
            --data-urlencode "q=${QUERY}" \
            --data-urlencode "fields=files(${FIELDS})" \
            --data-urlencode "orderBy=${ORDERBY}" \
            --data "key=${API_KEY}" \
            "${API_ENDPOINT}/files")
}


# Method to upload a file to google drive. Requires 2 arguments: file path and google folder id.
function uploadFile(){
    log "uploadFile($*)" 3

    local FILE="$1"
    local FOLDER_ID="$2"

    local MIME_TYPE=$(file --brief --mime-type "${FILE}")
    local SLUG=$(basename "${FILE}")
    local FILESIZE=$(stat -Lc%s "${FILE}")

    # JSON post data to specify the file name and folder under while the file to be created
    local postData="{\
        \"mimeType\": \"${MIME_TYPE}\",\
        \"name\": \"${SLUG}\",\
        \"parents\": [\"${FOLDER_ID}\"]\
    }"
    local postDataSize=$(echo ${postData} | wc -c)

    # Curl command to initiate resumable upload session and grab the location URL
    #log "Generating upload link for file ${FILE} ..."
    local uploadlink=$(docurl \
                --silent \
                -X POST \
                -H "Host: www.googleapis.com" \
                -H "Authorization: ${TOKEN_TYPE} ${ACCESS_TOKEN}" \
                -H "Content-Type: application/json; charset=UTF-8" \
                -H "X-Upload-Content-Type: ${MIME_TYPE}" \
                -H "X-Upload-Content-Length: ${FILESIZE}" \
                --data "${postData}" \
                "https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable&key=${API_KEY}" \
                --dump-header - | sed -ne s/"Location: "//p | tr -d '\r\n')

    # Curl command to push the file to google drive.
    # If the file size is large then the content can be split to chunks and uploaded.
    # In that case content range needs to be specified.
    log "Uploading file ${FILE}..."
    $(docurl \
        --silent \
        -X PUT \
        -H "Authorization: ${TOKEN_TYPE} ${ACCESS_TOKEN}" \
        -H "Content-Type: ${MIME_TYPE}" \
        -H "Content-Length: ${FILESIZE}" \
        -H "Slug: ${SLUG}" \
        -H "Transfer-Encoding: chunked" \
        -T "${FILE}" \
        --output /dev/null \
        "${uploadlink}" &)
}

# Method to upload a folder to google drive recursivly. Requires 2 arguments: folder path and google folder id
function uploadFolder(){
    log "uploadFolder($*)" 3

    local LOCAL_FOLDER_NAME=$(basename $1)
    local LOCAL_FOLDER="$1/.."
    local ROOT_FOLDER_ID="$2"

    local LAST_REL_FOLDER=
    local FOLDER_ID=
    local LOCAL_FILE

    for LOCAL_FILE in $(find "${LOCAL_FOLDER_NAME}" -type f); do
        local LOCAL_FILE_DIRNAME=$(dirname ${LOCAL_FILE})
        local REL_FOLDER=$(realpath --relative-to="${LOCAL_FOLDER}" ${LOCAL_FILE_DIRNAME})
        if [ "${LAST_REL_FOLDER}" != "${REL_FOLDER}" ]; then
            LAST_REL_FOLDER=${REL_FOLDER}

            FOLDER_ID=${ROOT_FOLDER_ID}
            local SFOLDER_NAMES
            IFS='/' read -ra SFOLDER_NAMES <<< $(echo ${REL_FOLDER})
            local SFOLDER_NAME
            for SFOLDER_NAME in "${SFOLDER_NAMES[@]}"; do
                FOLDER_ID=$(createDirectory "${SFOLDER_NAME}" "${FOLDER_ID}")
            done
        fi
        uploadFile "${LOCAL_FILE}" "${FOLDER_ID}"
    done
}

# creates a new access token
function createAccessToken() {
    log "createAccessToken($*)" 3

    echo "Open https://accounts.google.com/o/oauth2/auth?client_id=${CLIENT_ID}&redirect_uri=urn:ietf:wg:oauth:2.0:oob&scope=${SCOPE}&response_type=code and copy&past value here"
    read -p 'CODE: ' CODE;

    local RESPONSE=$(docurl \
        --silent \
        -X POST \
        --data "code=${CODE}" \
        --data "client_id=${CLIENT_ID}" \
        --data "client_secret=${CLIENT_SECRET}" \
        --data "redirect_uri=urn:ietf:wg:oauth:2.0:oob" \
        --data "grant_type=authorization_code" \
        "${TOKEN_URI}")

    ACCESS_TOKEN=$(echo "${RESPONSE}" | jsonValue access_token 1)
    TOKEN_TYPE=$(echo ${RESPONSE} | jsonValue token_type 1)
    REFRESH_TOKEN=$(echo "${RESPONSE}" | jsonValue refresh_token 1)

    updateConfig REFRESH_TOKEN
}

# refreshs the access token (every access token is valid for one hour)
function refreshAccessToken() {
    log "refreshAccessToken($*)" 3

    # Access token generation
    local RESPONSE=$(docurl \
        --silent \
        --X POST \
        --data "client_id=${CLIENT_ID}" \
        --data "client_secret=${CLIENT_SECRET}" \
        --data "refresh_token=${REFRESH_TOKEN}" \
        --data "grant_type=refresh_token" \
        "${TOKEN_URI}")

    ACCESS_TOKEN=$(echo ${RESPONSE} | jsonValue access_token 1)
    TOKEN_TYPE=$(echo ${RESPONSE} | jsonValue token_type 1)

    updateConfig ACCESS_TOKEN
    updateConfig TOKEN_TYPE
}

# tests, if the last access token is valid for at least one minute and creates/refreshs to a new one if needed
function ensureAccessToken() {
    log "ensureAccessToken($*)" 3

    if [ ! -z "${ACCESS_TOKEN}" ]; then
        # get info about last stored access token
        local RESPONSE=$(docurl \
            --silent \
            -X GET \
            --get \
            --data "access_token=${ACCESS_TOKEN}" \
            "https://www.googleapis.com/oauth2/v3/tokeninfo")

        local -i EXPIRES_IN=$(echo ${RESPONSE} | jsonValue expires_in 1)
        if [ -z "${EXPIRES_IN}" ] || [ "${EXPIRES_IN}" -lt 60 ]; then
            log "Create new access token"
            ACCESS_TOKEN=
        fi
    fi

    if [ -z "${REFRESH_TOKEN}" ]; then
        createAccessToken
    fi
    if [ -z "${ACCESS_TOKEN}" ]; then
        refreshAccessToken
    fi

    if [ -z "${ACCESS_TOKEN}" ] || [ -z "${TOKEN_TYPE}" ]; then
        log "Cannot resolve access token (${ACCESS_TOKEN}) and/or token type (${TOKEN_TYPE}). Abort" -1
        exit 2
    fi
}

function includeConfigData() {
    log "includeConfigData($*)" 3

    if [ -f "${CONFIG_FILE}" ]; then
        log "read config file ${CONFIG_FILE}" 2
        source "${CONFIG_FILE}"
    fi
}

function initialize() {
    log "initialize($*)" 3

    includeConfigData
    ensureMinimumConfig
    ensureAccessToken
}
