#! /usr/bin/env bash

keybindings="alt+1: 20, alt+2: 50, alt+3: 100, alt+4: Previous page, alt+5: Next page, ?: Toggle preview"
# PREVIEW_KEYBINDINGS="Shift+up/down: scroll preview, Shift+left/right: Preview page up/down"
# check if possible to see if preview is open and update keybindings with preview ones

jq_script='
.[]
| [
    .id,
    .name,
    .created_at,
    .status,
    .commit.short_id,
    .ref,
    .user.name
] | join(",")'

# Function to reverse any '/' separated string
function reverse() {
    tr '/' $'\n' <<< "$@" | tac | paste -s -d '/'
}

function log_file_path() {
    echo "/tmp/gllog/$1-$(echo "$2" | sed 's/\//-/g')-$3"
}

function update_page_info() {
    # Take page info from response header
    read -r next_page current_page per_page prev_page <<< "$(tr -d '\015' < /tmp/gllog/.response-headers \
    | awk '/x-next-page|x-page|x-per-page|x-prev-page/ {print $2} END{ORS="\n"; print}' ORS=" ")"
    # Update runtime settings with page info
    echo "$per_page;$current_page;$prev_page;$next_page" > $settings_file
}

function fetch_jobs() {
    # Try and fetch the jobs
    if ! jobs=$(curl -fsD /tmp/gllog/.response-headers --request GET --header "PRIVATE-TOKEN: $1" "$2/jobs?per_page=$3&page=$4"); then
        # Could maybe check exit codes here to give a more descriptive error than it maybe being the user's tokens
        echo "Failed to get jobs"
        echo "Check tokens and try again"
        exit 2
    fi

    # Update page info from latest response
    update_page_info

    # Format the json response into a table
    jq -r "$jq_script" <<< "$jobs" | awk -F "," '
        BEGIN{ORS=""}
        {
            cmd="cksum<<<"$2 "";
            cmd | getline check;
            close(cmd);
            split(check,checkArr, " ");
            # 255 instead of 256 because the resulting colours look nicer
            colour_value=checkArr[1]%255
            print $1 ","
            print "\u001b[38;5;" colour_value "m"$2 "\u001b[37m" ","
            print $3 ","
            if ($4=="failed") {print "\u001b[31m"} else if ($4=="success") {print "\u001b[32m"} else {print "\u001b[33m"}
            print $4 "\u001b[37m,"
            print $5 "," $6 "," $7
            print "\n"
        }' \
    | column -ts "," -N "Job ID,Job Name,Created at,Status,Commit sha,Branch,Triggered by"
}

function fetch_job_from_id() {
    # Determine path for the log file
    # $domain, $project_path, $job_id
    LOG_FILE=$(log_file_path "$1" "$2" "$5" )

    # If ther log file is already stored, just use that
    if [ ! -f "$LOG_FILE" ] || [ ! -s "$LOG_FILE" ]; then
        # $LOG_TOKEN, $project_api_address, $job_id, $LOG_FILE
        curl -fs --request GET --header "PRIVATE-TOKEN: $3" "$4/jobs/$5/trace" > "$LOG_FILE"
    fi

    # return log file
    echo "$LOG_FILE"
}

function process_url() {
    # break up the URL in separate variables, this bit is only for the domain, the remainder is everything after that
    IFS=/ read -r _ _ domain remainder <<< "$1"

    # Reverse the remainder and store the definite bits, anything left over are all the parent groups
    IFS=/ read -r job_id _ _ project group <<< "$(reverse "$remainder")"

    # Determine path for the log file
    LOG_FILE=$(log_file_path "$domain" "$(reverse "$group")-$project" "$job_id")

    # If ther log file is already stored, just use that
    if [ ! -f "$LOG_FILE" ] || [ ! -s "$LOG_FILE" ]; then
        # Retrieve the relevant token from .gitlab.cfg file
        export PROJECT_DOMAIN
        LOG_TOKEN=$(jq -r '.[] | select(.PROJECT_DOMAIN == $ENV.PROJECT_DOMAIN).personal_access_token' "$config_file")

        # Get the job log using the URL encoded project path
        if ! curl -fs --request GET --header "PRIVATE-TOKEN: $LOG_TOKEN" "https://$PROJECT_DOMAIN/api/v4/projects/$(reverse "$group" | sed 's/\//%2F/g')%2F$project/jobs/$job_id/trace" > "$LOG_FILE"; then
            echo "Failed to get job log"
            echo "Check tokens and try again"
            # Remove the empty log file so it doesn't get used on subsequent runs
            rm "$LOG_FILE"
            exit 1
        fi
    fi
}

function process_project() {
    # Export so jq can see it
    export LOG_INPUT="$1"

    # Get the profile with the configured alias and store the info in variables
    read -r domain project_path LOG_TOKEN \
        <<< "$(jq -r '.[] | select(.projects.[].alias == $ENV.LOG_INPUT)
                | [.domain, (.projects.[] | select(.alias == $ENV.LOG_INPUT).path), .personal_access_token]
                | join(" ")' \
                "$config_file")"

    # Failed to get info from profiles
    if [ -z "$domain" ]; then
        echo "Project '$LOG_INPUT' not configured. Please add it to $config_file"
        exit 4
    fi

    # Put together the address for the project via the api
    project_api_address="https://$domain/api/v4/projects/$(sed 's/\//%2F/g' <<< "$project_path")"

    export settings_file=/tmp/gllog/.runtime-settings
    # Default page settings. 20 per page, page 1, next and previous pages don't matter because the first fetch overwrites them
    echo "20;1;1;1" > $settings_file

    # Retrieve job ID as selected by user
    job_id=$(fetch_jobs "$LOG_TOKEN" "$project_api_address" 20 1 \
    | fzf --ansi --no-sort --reverse --border --border-label " $project_path " --header-lines=1 --highlight-line \
        `# Overwrite 'enter' key action with execute command so fzf isn't exited when viewing logs` \
        --bind "enter:execute(source $0 && job_id=\$(echo {} | awk '{print \$1}') && $PAGER \$(fetch_job_from_id $domain $project_path $LOG_TOKEN $project_api_address \$job_id))" \
        `# Default preview window to hidden, this also stops execution of preview command` \
        --preview-window=hidden,~1 \
        `# Preview command: source this file, get the job ID from the current selected line, open the job logs` \
        --preview "source $0 && job_id=\$(echo {} | awk '{print \$1}') && $PAGER \$(fetch_job_from_id $domain $project_path $LOG_TOKEN $project_api_address \$job_id)" \
        --bind '?:toggle-preview' \
        --bind 'shift-left:preview-page-up' \
        --bind 'shift-right:preview-page-down' \
        `# Keybindings for pagination` \
        --bind "alt-1:reload-sync(IFS=\; read -r per_page page prev_page next_page < $settings_file && source $0 && fetch_jobs $LOG_TOKEN $project_api_address 20 \$page)" \
        --bind "alt-2:reload-sync(IFS=\; read -r per_page page prev_page next_page < $settings_file && source $0 && fetch_jobs $LOG_TOKEN $project_api_address 50 \$page)" \
        --bind "alt-3:reload-sync(IFS=\; read -r per_page page prev_page next_page < $settings_file && source $0 && fetch_jobs $LOG_TOKEN $project_api_address 100 \$page)" \
        --bind "alt-4:reload-sync(IFS=\; read -r per_page page prev_page next_page < $settings_file && source $0 && fetch_jobs $LOG_TOKEN $project_api_address \$per_page \$prev_page)" \
        --bind "alt-5:reload-sync(IFS=\; read -r per_page page prev_page next_page < $settings_file && source $0 && fetch_jobs $LOG_TOKEN $project_api_address \$per_page \$next_page)" \
        `# Command used for what the info bar should display: Page info + keybidnings` \
        --info-command="awk -F ';' '{print \"\u001b[36mPage: \" \$2 \", Viewing \" \$1 \"\u001b[37m | \u001b[38;5;174m$keybindings\u001b[37m\"}' $settings_file" \
        --info=default \
    | awk '{print $1}')
    # The fzf commands aren't functions because of subshell fun

    # If user didn't select a job ID exit cleanly
    if [ -z "$job_id" ]; then
        echo "No job selected"
        exit 0
    fi

    LOG_FILE="$(fetch_job_from_id $domain $project_path $LOG_TOKEN $project_api_address $job_id)"
}

function main() {
    # Make log directory if it doesn't exist
    mkdir -p /tmp/gllog

    config_file="${config_file:=$HOME/.gllog.config}"

    # identify if input was a full job url
    if [[ $1 =~ https://.*-/jobs/[0-9]+ ]]; then
        process_url "$1"
    else
        process_project "$1"
    fi

    # Display the log using user's default pager
    $PAGER "$LOG_FILE"
}

function create_config() {
    config_path=$HOME/.gllog.config
    if [ ! -f "$config_path" ]; then
        cat <<EOF > "$config_path"
[
    {
        "domain": "gitlab.example.com",
        "personal_access_token": "",
        "projects": [
            {
                "path": "path/to/project",
                "alias": "foo"
            },
            {
                "path": "another/project",
                "alias": "bar"
            }
        ]
    }
]

EOF
        echo "Config created at $config_path"
    else
        echo "Config already exists at $config_path, not overwriting"
    fi
}

function help() {
    echo "GitLab job log viewer"
    echo ""
    echo "Allows for interactive browsing of job logs on the command line."
    echo "Initially designed to deal with excessively long job logs that GitLab"
    echo "can't render in full."
    echo ""
    echo "Options:"
    echo "-c FILE    Specify config file to use. Defaults to $HOME/.gllog.config"
    echo "-x         Generate a template config at $HOME/.gllog.config"
    echo ""
    echo "Usage:"
    echo "Pass individual job url"
    echo "gllog \${JOB_LOG_URL}"
    echo ""
    echo "Pass configured project"
    echo "gllog \${CONFIGURED_ALIAS}"
    echo ""
    echo "Created questionably by JZ"
}

function handle_options() {
    while getopts "c:xh" o; do
        case "${o}" in
            c)
                config_file="$OPTARG"
                ;;
            x)
                create_config
                exit 0
                ;;
            h|*)
                help
                return 1
                ;;
        esac
    done

    return 0
}

function begin() {
    if [ -z "$1" ]; then
        echo "Provide configured project alias / job url"
        exit 1
    else
        if handle_options "$@"; then
            # Exclude flags and only pass the input
            main "${@: -1}"
        fi
    fi
}

is_sourced() {
    if [ -n "$ZSH_VERSION" ]; then
        case $ZSH_EVAL_CONTEXT in *:file:*) return 0;; esac
    else  # Add additional POSIX-compatible shell names here, if needed.
        case ${0##*/} in dash|-dash|bash|-bash|ksh|-ksh|sh|-sh) return 0;; esac
    fi
    return 1  # NOT sourced.
}

# Don't begin execution if script is being sourced
if ! is_sourced; then
    begin "$@"
fi
