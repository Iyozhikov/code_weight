#!/bin/bash
#
START_DIR="$(cd "$(dirname "${0}")" && pwd)"
CFG_FILE="${CFG_FILE:-$START_DIR/get_weight.conf}"
WORK_DIR="${START_DIR}/repos"
LOG_DIR="${START_DIR}/logs"
LOG_FILE="${LOG_DIR}/run_results_$(date +%Y-%m-%d_%H).log"
LOG_LVL=1
WORKING_ON=''
GIT_CMD="$(which git)"
# projects array
declare -a PROJECTS
# config array
declare -A CFG
# startup checks
if [ ! -f "${GIT_CMD}" ]; then
    echo "ERR: Please, install git, exiting!"
    exit 1
fi
if [ ! -d "${WORK_DIR}" ]; then
    mkdir -p "${WORK_DIR}"
fi
######## FUNCTIONS ##############
# logler
function log()
{
    local input="$*"
    if [ ! -d "${LOG_DIR}" ]; then
        mkdir -p "${LOG_DIR}"
    fi
    case "${LOG_LVL}" in
        3)
            if [ ! -z "${input}" ]; then
                echo "${input}" | tee -a "${LOG_FILE}"
            fi
            ;;
        2)
            if [ ! -z "${input}" ]; then
                echo "${input}" >> "${LOG_FILE}"
            fi
            ;;
        1)
            if [ ! -z "${input}" ]; then
                echo "${input}"
            fi
            ;;
        *)
            ;;
    esac
}
# iniget config-file section option
function iniget {
    local xtrace=$(set +o | grep xtrace)
    set +o xtrace
    local file=$1
    local section=$2
    local option=$3
    local line
    line=$(sed -ne "/^\[$section\]/,/^\[.*\]/ { /^$option[ \t]*=/ p; }" "$file")
    echo "${line#*=}"
    $xtrace
}
# read config
function read_config()
{
    if [ ! -f "${CFG_FILE}" ]; then echo "Config missed!"; exit 1; fi
    local loglvl="$(iniget "${CFG_FILE}" "default" "loglevel")"
    local gerrituser="$(iniget "${CFG_FILE}" "default" "gerrituser")"
    local gerrithost="$(iniget "${CFG_FILE}" "default" "gerrithost")"
    local gerritport="$(iniget "${CFG_FILE}" "default" "gerritport")"
    local relases="$(iniget "${CFG_FILE}" "default" "releases")"
    local update_code="$(iniget "${CFG_FILE}" "default" "updatecode")"
    local analyser="$(iniget "${CFG_FILE}" "default" "analyser")"
    local analyseropts="$(iniget "${CFG_FILE}" "default" "analyseropts")"
    if [ ! -z "${loglvl}" ]; then
        LOG_LVL="${loglvl}"
    fi
    if [ -z "${gerrituser}" ] || [ -z "${gerrithost}" ] || [ -z "${gerritport}" ] ; then
        log "Please make setup proper values for [default]/gerrit[user[host[port] in ${CFG_FILE}!"
        exit 2
    fi
    if [ -z "${relases}" ]; then
        log "Please make setup proper values for [default]/relases in ${CFG_FILE}!"
        exit 2
    fi
    if [ ! -z "${update_code}" ]; then
        CFG["updatecode"]=false
    else
        CFG["updatecode"]=true
    fi
    if [ ! -z "${analyser}" ]; then
        if [ -f "${analyser}" ]; then
            CFG["analyser"]="${analyser}"
            if [ ! -z "${analyseropts}" ]; then
                CFG["analyseropts"]="${analyseropts}"
            fi
        fi
    fi
    CFG["gerrituser"]="${gerrituser}"
    CFG["gerrithost"]="${gerrithost}"
    CFG["gerritport"]="${gerritport}"
    CFG["gerritconstring"]="ssh -p ${gerritport} ${gerrituser}@${gerrithost}"
    CFG["releases"]="${relases}"
}
# check gerrit connectivity
function check_connectivity()
{
    local retval=0
    log "Checking gerrit connection:"
    ${CFG[gerritconstring]} 'gerrit version' 2>/dev/null || retval=$?
    if [ "${retval}" -ne 0 ]; then
        log "Error accured, please try run manually '${CFG[gerritconstring]} 'gerrit version''!"
        exit 2
    fi
}
# collect data for further processing
function query_gerrit_for_projects()
{
    local branch="${1}"
    local projfilter="${2}"
    local projexclusions="${3}"
    local filter=""
    local exclusions=""
    for item in ${projfilter}
    do
        if [ -z "${filter}" ]; then
            filter="${item}/.*$"
        else
            filter+="|${item}/.*$"
        fi
    done
    local command="${CFG[gerritconstring]} 2>/dev/null \"gerrit ls-projects -b ${branch}\" | grep -oE \"(${filter})\""
    if [ ! -z "${projexclusions}" ]; then
        for excl in ${projexclusions}
        do
            if [ -z "${exclusions}" ]; then
                exclusions="${excl}"
            else
                exclusions+="|${excl}"
            fi
        done
        command="${command} | grep -vE \"(${exclusions})\""
    fi
    while read line
    do
        if [ ! -z "${line}" ]; then
            PROJECTS=("${PROJECTS[@]}" "${line}")
        fi
    done < <(eval "${command}")
    if [ ${#PROJECTS[@]} -eq 0 ]; then
        log "WRN: Projects list for '${branch}' is empty!"
    fi
}
# fetch projects
function get_code()
{
    local update_repo_if_exists="${CFG[updatecode]}"
    for i in $(seq 0 $(( ${#PROJECTS[@]} - 1)));
    do
        local gerritprojname="${PROJECTS[${i}]}"
        local localprojpath="${WORK_DIR}/${gerritprojname}"
        if [ ! -d "${localprojpath}" ]; then
            mkdir -p "${localprojpath}"
            if [ $? -ne 0 ]; then
                log "ERR: Can't create '${localprojpath}', exiting!"
                exit 2
            fi
        fi
        cd "${localprojpath}" && ${GIT_CMD} branch -a | grep -q master
        local mastercheck=$?
        if [ "${mastercheck}" -eq 0 ] && [ "${update_repo_if_exists}" = "true" ]; then
            log "$(basename "${localprojpath}") has git repo, pulling ${gerritprojname}..."
            local origin_remote="$(cd "${localprojpath}" && ${GIT_CMD} remote -v | grep origin | awk '{print $2}' | head -n1)"
            if [ "${origin_remote}" != "ssh://${CFG["gerrituser"]}@${CFG["gerrithost"]}:${CFG["gerritport"]}/${gerritprojname}" ]; then
                echo "WRN: ${localprojpath} has wrong remote for origin!"
                continue
            fi
            cd "${localprojpath}" && ${GIT_CMD} reset --hard --quiet 2>/dev/null && ${GIT_CMD} checkout master --quiet 2>/dev/null && ${GIT_CMD} pull --quiet origin master 2>/dev/null
            if [ $? -ne 0 ]; then
                log "WRN: Can't pull code for '${gerritprojname}', skipping!"
                continue
            fi
        elif [ "${mastercheck}" -eq 0 ] && [ "${update_repo_if_exists}" = "false" ]; then
            #log "$(basename "${localprojpath}") has git repo, update skipped"
            continue
        else
            log "Cloning ${gerritprojname}..."
            ${GIT_CMD} clone --quiet "ssh://${CFG["gerrituser"]}@${CFG["gerrithost"]}:${CFG["gerritport"]}/${gerritprojname}" "${localprojpath}" 2>/dev/null
            if [ $? -ne 0 ]; then
                log "WRN: Can't fetch code for '${gerritprojname}', skipping!"
                continue
            fi
        fi
    done
}
# switch to required branch
function switch_branch()
{
    local branch="${1}"
    for i in $(seq 0 $(( ${#PROJECTS[@]} - 1)));
    do
        local gerritprojname="${PROJECTS[${i}]}"
        local localprojpath="${WORK_DIR}/${gerritprojname}"
        log "Switching to '${branch}' for '$gerritprojname'"
        cd "${localprojpath}" && ${GIT_CMD} checkout "${branch}" --quiet 2>/dev/null
        if [ $? -ne 0 ]; then
            log "WRN: Can't switch to '${branch}' for '${gerritprojname}', skipping!"
            continue
        fi
    done
}
# reset PROJECTS array
function reset_proj_array()
{
    unset PROJECTS

}
#### TODO: add code analysis below
function analyse()
{
    if [ -z "${CFG[analyser]}" ]; then
        log "WRN: Analyser tool was not set up properly or wasn't found, check values of [default]/analyser[opts] in '${CFG_FILE}'. Skipping run."
        return 1
    fi
    local add_to_path="$(dirname "${CFG[analyser]}")"
    local report_file="${LOG_DIR}/$(basename "${CFG[analyser]}")-$(date +%Y-%m-%d_%H)-${WORKING_ON}.log"
    export PATH=$PATH:${add_to_path}
    export LANG=C
    log "Running analyser '${CFG[analyser]}'..."
    ${CFG[analyser]} ${CFG[analyseropts]} "${WORK_DIR}" >> "${report_file}"
    sed -i '/WARNING/d' "${report_file}"
}
####
# start processing
function main()
{
    read_config
    check_connectivity
    for relname in ${CFG[releases]}
    do
        local os_projfilter="$(iniget "${CFG_FILE}" "${relname}" "osprojfitler")"
        local os_projbranch="$(iniget "${CFG_FILE}" "${relname}" "osbranch")"
        local os_proj_exclusion="$(iniget "${CFG_FILE}" "${relname}" "osprojexclusion")"
        local dep_projfilter="$(iniget "${CFG_FILE}" "${relname}" "deprojfilter")"
        local dep_projbranch="$(iniget "${CFG_FILE}" "${relname}" "depbranch")"
        local dep_proj_exclusion="$(iniget "${CFG_FILE}" "${relname}" "deprojexclusion")"
        WORKING_ON="${relname}"
        log "####### Processing release: ${WORKING_ON}"
        log "''''''' OpenStack projects, branch : ${os_projbranch}"
        query_gerrit_for_projects "${os_projbranch}" "${os_projfilter}" "${os_proj_exclusion}"
        get_code
        switch_branch "${os_projbranch}"
        log "<EOL>"
        reset_proj_array
        log "''''''' Rest projects, branch : ${dep_projbranch}"
        query_gerrit_for_projects "${dep_projbranch}" "${dep_projfilter}" "${dep_proj_exclusion}"
        get_code
        switch_branch "${dep_projbranch}"
        log "<EOL>"
        reset_proj_array
        # call analyser
        analyse
    done
}
######### RUNTIME ###################
main
