#! /usr/bin/env bash

keybindings="alt+1: 20, alt+2: 50, alt+3: 100, alt+4: Previous page, alt+5: Next page, ?: Toggle preview, .: Open job in browser"
# PREVIEW_KEYBINDINGS="Shift+up/down: scroll preview, Shift+left/right: Preview page up/down"
# check if possible to see if preview is open and update keybindings with preview ones

jq_script='
.[]
| [
    .id,
    .name,
    .created_at,
    .duration,
    .status,
    .commit.short_id,
    .ref,
    .user.name,
    (.runner.id | if . then "#\(.)" end)
] | join(",")'

# Function to reverse any '/' separated string
function reverse() {
    tr '/' $'\n' <<< "$@" | tac | paste -s -d '/'
}

function config_file_path {
    echo "${config_file:=$HOME/.gllog.config}"
}

function log_file_path() {
    echo "/tmp/gllog/$1-$(echo "$2" | sed 's/\//-/g')-$3"
}

function update_page_info() {
    # Take page info from response header
    read -r next_page current_page per_page prev_page <<< "$(tr -d '\015' < /tmp/gllog/.response-headers \
    | awk '/x-next-page|x-page|x-per-page|x-prev-page/ {print $2} END{ORS="\n"; print}' ORS=" ")"
    # Update runtime settings with page info
    echo "$per_page;$current_page;$prev_page;$next_page" > "$settings_file"
}

function fetch_jobs() {
    mkdir -p /tmp/gllog

    # Try and fetch the jobs
    if ! jobs=$(curl -fsD /tmp/gllog/.response-headers --request GET --header "PRIVATE-TOKEN: $1" "$2/jobs?per_page=$3&page=$4"); then
        # Could maybe check exit codes here to give a more descriptive error than it maybe being the user's tokens
        echo "Failed to get jobs"
        echo "Check tokens and try again"
        exit 2
    fi

    if $5; then
        # Update page info from latest response
        update_page_info
    fi

    # Format the json response into a table
    jq -r "$jq_script" <<< "$jobs" | awk -F "," '
        function colour(pos){
            cksum_cmd="cksum<<<\""pos"\""
            cksum_cmd | getline check
            close(cksum_cmd)
            split(check,checkArr, " ")
            return checkArr[1]%255
        }
        function time(seconds){
            date_cmd="date -d@"seconds" -u +%H:%M:%S"
            date_cmd | getline result
            close(date_cmd)
            return result
        }
        function datetime(time){
            datetime_cmd="date -d "time" -u \"+%Y/%m/%d %H:%M:%S.%3N\""
            datetime_cmd | getline result
            close(datetime_cmd)
            return result
        }
        BEGIN{ORS=""}
        {
            # 255 instead of 256 because the resulting colours look nicer
            colour_value=colour($2)
            if ($4 != "") {duration=time($4)} else {duration=""}
            print $1 ","
            print "\u001b[38;5;" colour_value "m"$2 "\u001b[37m" ","
            print datetime($3) ","
            print duration ","
            if ($5=="failed") {print "\u001b[31m"} else if ($5=="success") {print "\u001b[32m"} else {print "\u001b[33m"}
            print $5 "\u001b[37m,"
            print $6 "," $7 "," $8 "," $9
            print "\n"
        }' \
    | column -ts "," -N "Job ID,Job Name,Created at,Duration,Status,Commit sha,Branch,Triggered by,Runner"
}

function fetch_job_from_id() {
    # Determine path for the log file
    # $domain, $project_path, $job_id
    log_file=$(log_file_path "$1" "$2" "$5" )


    # If ther log file is already stored, just use that
    if [ ! -f "$log_file" ] || [ ! -s "$log_file" ]; then
        # If job is still running, change log-file path
        # This means it will be refreshed everytime it is opened
        if [ "$6" = "running" ]; then
            log_file="${log_file}-running"
        fi

        # $log_token, $project_api_address, $job_id, $log_file
        curl -fs --request GET --header "PRIVATE-TOKEN: $3" "$4/jobs/$5/trace" > "$log_file"
    fi

    # return log file
    echo "$log_file"
}

function open_job_in_browser() {
    xdg-open "$1/$2/-/jobs/$3"
}

function run_down() {
    config_file="$(config_file_path)"

    IFS=" " read -r -a projects <<< "$(jq -r '.rundown.projects | join(" ")' "$config_file")"
    # collected_logs=()
    for project_alias in "${projects[@]}"; do
        export project_alias
        read -r domain project_path log_token \
            <<< "$(jq -r '.projects.[] | select(.projects.[].alias == $ENV.project_alias)
                | [.domain, (.projects.[] | select(.alias == $ENV.project_alias).path), .personal_access_token]
                | join(" ")' \
                "$config_file")"
        project_api_address="https://$domain/api/v4/projects/$(sed 's/\//%2F/g' <<< "$project_path")"

        echo "$project_alias ($domain/$project_path)"

        fetch_jobs "$log_token" "$project_api_address" 5 1 false
        # output="$(fetch_jobs "$log_token" "$project_api_address" 5 1 false)" #> /tmp/gllog_"$project_alias"
        # collected_logs+=("$output")

        if [[ $project_alias != "${projects[-1]}" ]]; then
            echo "" # Separate each output
        fi
    done
    # awk_join <("${collected_logs[1]}")
    # awk_join <("${collected_logs[3]}") <("${collected_logs[4]}")
    # awk_join /tmp/file_*
    # rm /tmp/gllog_*
}

function process_url() {
    # break up the URL in separate variables, this bit is only for the domain, the remainder is everything after that
    IFS=/ read -r _ _ project_domain remainder <<< "$1"

    # Reverse the remainder and store the definite bits, anything left over are all the parent groups
    IFS=/ read -r job_id _ _ project group <<< "$(reverse "$remainder")"

    # Determine path for the log file
    log_file=$(log_file_path "$project_domain" "$(reverse "$group")-$project" "$job_id")

    # If ther log file is already stored, just use that
    if [ ! -f "$log_file" ] || [ ! -s "$log_file" ]; then
        # Retrieve the relevant token from .gitlab.cfg file
        export project_domain

        log_token=$(jq -r '.projects.[] | select(.domain == $ENV.project_domain).personal_access_token' "$config_file")

        # Get the job log using the URL encoded project path
        if ! curl -fs --request GET --header "PRIVATE-TOKEN: $log_token" "https://$project_domain/api/v4/projects/$(reverse "$group" | sed 's/\//%2F/g')%2F$project/jobs/$job_id/trace" > "$log_file"; then
            echo "Failed to get job log"
            echo "Check tokens and try again"
            # Remove the empty log file so it doesn't get used on subsequent runs
            rm "$log_file"
            exit 1
        fi
    fi
}

function process_project() {
    # Export so jq can see it
    export log_input="$1"

    # Get the profile with the configured alias and store the info in variables
    read -r domain project_path log_token \
        <<< "$(jq -r '.projects.[] | select(.projects.[].alias == $ENV.log_input)
                | [.domain, (.projects.[] | select(.alias == $ENV.log_input).path), .personal_access_token]
                | join(" ")' \
                "$config_file")"

    # Failed to get info from profiles
    if [ -z "$domain" ]; then
        echo "Project '$log_input' not configured. Please add it to $config_file"
        exit 4
    fi

    # Put together the address for the project via the api
    project_api_address="https://$domain/api/v4/projects/$(sed 's/\//%2F/g' <<< "$project_path")"

    export settings_file=/tmp/gllog/.runtime-settings
    # Default page settings. 20 per page, page 1, next and previous pages don't matter because the first fetch overwrites them
    echo "20;1;1;1" > $settings_file

    # Retrieve job ID as selected by user
    job_id=$(fetch_jobs "$log_token" "$project_api_address" 20 1 \
    | fzf --ansi --no-sort --reverse --border --border-label " $project_path " --header-lines=1 --highlight-line \
        `# Overwrite 'enter' key action with execute command so fzf isn't exited when viewing logs` \
        --bind "enter:execute(source $0 && read job_id job_status <<< \$(echo {} | awk '{print \$1 \" \" \$5}') && $PAGER \$(fetch_job_from_id $domain $project_path $log_token $project_api_address \$job_id \$job_status))" \
        `# Default preview window to hidden, this also stops execution of preview command` \
        --preview-window=hidden,~1 \
        `# Preview command: source this file, get the job ID from the current selected line, open the job logs` \
        --preview "source $0 && read job_id job_status <<< \$(echo {} | awk '{print \$1 \" \" \$5}') && $PAGER \$(fetch_job_from_id $domain $project_path $log_token $project_api_address \$job_id \$job_status)" \
        --bind '?:toggle-preview' \
        --bind ".:execute(source $0 && read job_id <<< \$(echo {} | awk '{print \$1}') && open_job_in_browser $domain $project_path \$job_id)" \
        --bind 'shift-left:preview-page-up' \
        --bind 'shift-right:preview-page-down' \
        `# Keybindings for pagination` \
        --bind "alt-1:reload-sync(IFS=\; read -r per_page page prev_page next_page < $settings_file && source $0 && fetch_jobs $log_token $project_api_address 20 \$page)" \
        --bind "alt-2:reload-sync(IFS=\; read -r per_page page prev_page next_page < $settings_file && source $0 && fetch_jobs $log_token $project_api_address 50 \$page)" \
        --bind "alt-3:reload-sync(IFS=\; read -r per_page page prev_page next_page < $settings_file && source $0 && fetch_jobs $log_token $project_api_address 100 \$page)" \
        --bind "alt-4:reload-sync(IFS=\; read -r per_page page prev_page next_page < $settings_file && source $0 && fetch_jobs $log_token $project_api_address \$per_page \$prev_page)" \
        --bind "alt-5:reload-sync(IFS=\; read -r per_page page prev_page next_page < $settings_file && source $0 && fetch_jobs $log_token $project_api_address \$per_page \$next_page)" \
        `# Command used for what the info bar should display: Page info + keybindings` \
        --info-command="awk -F ';' '{print \"\u001b[36mPage: \" \$2 \", Viewing \" \$1 \"\u001b[37m | \u001b[38;5;174m$keybindings\u001b[37m\"}' $settings_file" \
        --info=default \
    | awk '{print $1}')
    # The fzf commands aren't functions because of subshell fun

    # If user didn't select a job ID exit cleanly
    if [ -z "$job_id" ]; then
        echo "No job selected"
        exit 0
    fi

    log_file="$(fetch_job_from_id "$domain" "$project_path" "$log_token" "$project_api_address" "$job_id")"
}

function main() {
    # Make log directory if it doesn't exist
    mkdir -p /tmp/gllog

    config_file="$(config_file_path)"

    # identify if input was a full job url
    if [[ $1 =~ https://.*-/jobs/[0-9]+ ]]; then
        process_url "$1"
    else
        process_project "$1"
    fi

    # Display the log using user's default pager
    $PAGER "$log_file"
}

function create_config() {
    config_path=$HOME/.gllog.config
    if [ ! -f "$config_path" ]; then
        cat <<EOF > "$config_path"
{
    "projects": [
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
    "rundown": {
        "projects": [
            "foo",
            "bar"
        ]
    }
}

EOF
        echo "Config created at $config_path"
    else
        echo "Config already exists at $config_path, not overwriting"
    fi
}

function configured_projects() {
    jq -r '.projects.[].projects[].alias' "$(config_file_path)"
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
    echo "-l         List configured project aliases"
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
    while getopts "c:lxhr" o; do
        case "${o}" in
            c)
                config_file="$OPTARG"
                ;;
            l)
                configured_projects
                exit 0
                ;;
            x)
                create_config
                exit 0
                ;;
            r)
                run_down
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
