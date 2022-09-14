YELLOW="\033[0;33m"
BLUE="\033[0;34m"
RED="\033[0;31m"
END_COLOR="\033[0m"
if [ -n "${NO_COLOR:-}" ]; then
    YELLOW=
    BLUE=
    RED=
    END_COLOR=
fi

SOURCE=${BASH_SOURCE:-}

# ============================================================================
# GNU
# ============================================================================

# use gnu version of command if exists
# usage:
# gnu <command> <args>
# example:
# gnu grep foo
function gnu {
    command=$1
    gnucommand=g$command
    path=$(which $command 2> /dev/null || true)
    gnupath=$(which $gnucommand 2> /dev/null || true)

    shift

    bin=${gnupath:-$path}

    if [ -z "$bin" ]; then
        echo -e ${RED}${command}${END_COLOR} or ${RED}${gnucommand}${END_COLOR} not found
        exit 1
    fi

    if [ $(uname -s) = "Darwin" ] && [ -z "$gnupath" ]; then
        echo -e Mac detected but ${RED}$gnucommand${END_COLOR} not found > /dev/stderr
        echo -e Mac version of ${BLUE}${command}${END_COLOR} is usually very outdated and might not work as expected > /dev/stderr
        echo -e Consider installing GNU version of ${BLUE}${command}${END_COLOR} with brew > /dev/stderr
        echo -e Usually: > /dev/stderr
        echo -e "\tbrew install ${command}" > /dev/stderr
        echo > /dev/stderr
    fi

    ${gnupath:-$path} "$@"
}

# alias some common gnu tools we use so that in the scripts
# we dont need to explicitly use `gnu <cmd>` function above
function grep { gnu grep "$@"; }
function paste { gnu paste "$@"; }
function sed { gnu sed "$@"; }

# ============================================================================
# DOCKER
# ============================================================================

# wrapper around docker-compose except:
# * in CI it switches to using images for caching
# * locally uses docker-compose as-is which builds image from scratch
# this allows to easily update containers as necessary locally
# without needing to build+tag images
function compose {
    # by default docker when mounts a non-existing path will create a folder
    # vs sometimes we would like to mount optional config files
    # marking mount with "# ensure:file" will touch that file if not present
    # so that docker can mount a file, not a folder
    for i in $(
        cat docker-compose.yml \
            | grep -E '# ensure:file$' \
            | awk '{ print $2 }' \
            | cut -d: -f1
    ); do
        path=$(eval echo $i)
        if ! [ -f $path ]; then
            (set -x && touch $path)
        fi
    done

    for i in $(
        cat docker-compose.yml \
            | grep -E '# ensure:network$' \
            | awk '{ print $1 }' \
            | cut -d: -f1
    ); do
        if ! docker network inspect $i &> /dev/null; then
            (
                set -x
                docker network create $i
            )
        fi
    done

    if [ -n "${CI:-}" ]; then
        # sed uncomments lines starting with "# CI"
        # and removes lines ending with "# CI"
        # therefore allowing to switch what is used locally and in CI
        set -x
        exec docker-compose \
            -f <(cat docker-compose.yml | sed -r -e 's/^(\s+)# CI\s*(.*)/\1\2/g' -e '/# CI/d') \
            --project-directory $PWD \
            $@
    else
        set -x
        exec docker-compose $@
    fi
}

# if Makefile target specifies which docker-compose service to use
# get its name to be used with docker-compose
# otherwise fallback to provided default
# usage:
# service_for_compose <default> "$@"
function service_for_compose {
    default=$1
    args=${2:-}
    if [ -f Makefile ]; then
        # looks magical but its pretty simple
        # for example if script is called with ./build.sh lint
        # it will look for a line in Makefile starting with "lint: # docker-compose:"
        # and if it finds such a line, it extracts docker-compose service
        # which is expected to be used for that makefile target
        service=$(
            (
                grep -H -E "^($(
                    echo $args \
                        | tr ' ' '\n' \
                        | paste -s -d'|'
                )):.*?# docker-compose:" Makefile* \
                    || true
            ) \
                | cut -d: -f4 \
                | head -n1
        )
    elif [ -f package.json ]; then
        # looks magical but its pretty simple
        # for example if script is called with ./build.sh lint
        # it will look for a line in package.json with ## @@docker-compose:
        # and if it finds such a line, it extracts docker-compose service
        # which is expected to be used for that scripts
        service=$(
            (
                grep -H -E "^\s+\"($(
                    echo $args \
                        | tr ' ' '\n' \
                        | paste -s -d'|'
                ))\":.*?@@docker-compose:" package.json \
                    || true
            ) \
                | head -n1 \
                | sed -r 's/.*?@@docker-compose:([a-zA-Z0-9_-]+).*/\1/g'
        )
    fi
    echo ${service:-$default}
}

# ============================================================================
# HELP
# ============================================================================

HELP_WIDTH=${HELP_WIDTH:-15}

function _help_format {
    cat - | awk "{printf \"${BLUE}%-${HELP_WIDTH}s${END_COLOR} %s\n\", \$1, substr(\$0, length(\$1) + 1);}"
}

function _help_makefile {
    if [ ! -f Makefile ]; then
        return
    fi
    grep -H -E '^[a-zA-Z0-9_-]+:.*?## .*$$' Makefile* \
        | cut -d: -f2- \
        | sort \
        | sed 's/:\s*##\s*/ /g' \
        | _help_format
}

function _help_packagejson {
    if [ ! -f package.json ]; then
        return
    fi
    grep -H -E '"[a-zA-Z0-9_-]+":.*?## .*$$' package.json \
        | cut -d: -f2- \
        | sort \
        | sed -r 's/^\s+"(.*)":\s+".*##\s+(@@[a-zA-Z0-9:_-]+\s+)?(.*)",?$/\1 \3/g' \
        | _help_format
}

function _help_commands {
    bin=$1
    grep -E '^\s*## help:command' $bin \
        | cut -d: -f3- \
        | sort \
        | _help_format \
        || true
}

function _help_flags {
    bin=$1
    grep -E '^\s*## help:flag' $bin \
        | cut -d: -f3- \
        | sort \
        | _help_format \
        || true
}

# combine help from multiple sources
# usage:
# show_help $@
function show_help {
    echo -e ${YELLOW}$(basename $PWD)$END_COLOR
    echo
    echo -e ${YELLOW}${0}${END_COLOR} [flag ...] [command ...]
    echo

    echo -e ${YELLOW}Flags:${END_COLOR}
    echo
    {
        _help_flags $0
        _help_flags $SOURCE
    } | sort
    echo

    echo -e ${YELLOW}Commands:${END_COLOR}
    echo
    {
        _help_commands $0
        _help_commands $SOURCE
        _help_makefile
        _help_packagejson
    } | sort
    exit 0
}

# ============================================================================
# RUNNING
# ============================================================================

# this loop must be top-level so that it can overwrite $@ which is a global in bash
for arg; do
    shift
    case "$arg" in
        ## help:flag:--arm64 switch docker builds to linux/arm64 (emulated if host arch is different)
        --arm64)
            export COMPOSE_DOCKER_CLI_BUILD=1
            export DOCKER_BUILDKIT=1
            export DOCKER_DEFAULT_PLATFORM=linux/arm64
            ;;
        ## help:flag:--amd64 switch docker builds to linux/amd64 (emulated if host arch is different)
        --amd64)
            export COMPOSE_DOCKER_CLI_BUILD=1
            export DOCKER_BUILDKIT=1
            export DOCKER_DEFAULT_PLATFORM=linux/amd64
            ;;
        *)
            set -- "$@" "$arg"
            ;;
    esac
done

# note target is explicitly $1 vs searching for flags anywhere in $@
# as there could be other commands which accept nested flags like --help
target=${1:-}
case "$target" in
    ## help:flag:-h/--help print this message
    ## help:command:help print this message
    -h | --help | help)
        show_help $@
        ;;
    ## help:command:build build local docker-compose images
    build)
        compose $@
        ;;
    ## help:command:pull pull latest docker-compose images
    pull)
        compose $@
        ;;
    ## help:command:down trash all local containers including all their state/volumes
    down)
        compose $@ --volumes
        ;;
esac

# ============================================================================
# SELF UPDATE
# ============================================================================

util_url=${util_url:-}
util_check_min=60

# if SOURCE is NOT symlink (local testing)
# and url is set
# and url points to non-pinned main branch
# and file is older than $util_check_min
if [ ! -L ${SOURCE} ] \
    && [ -n "${util_url}" ] \
    && [[ "$util_url" == *"/main/"* ]] \
    && test $(find ${SOURCE} -mmin +${util_check_min}); then

    # only then check if its up to-date
    if ! cat ${SOURCE} | sha256sum --check --quiet <(curl -s $util_url | sha256sum) &> /dev/null; then
        echo -e ${RED}Local cached copy of \'${SOURCE}\' is outdated${END_COLOR}
        echo -e ${RED}${util_url} has newer version${END_COLOR}
        echo -e ${RED}To get latest version you can remove local cached copy with:${END_COLOR}
        echo -e "\trm ${SOURCE}"
        echo

    # if up to date then touch file so that its not checked again for $util_check_min
    else
        touch ${SOURCE}
    fi
fi
