# ============================================================================
# DOCKER
# ============================================================================

# wrapper around docker-compose except:
# * in CI it switches to using images for caching
# * locally uses docker-compose as-is which builds image from scratch
# this allows to easily update containers as necessary locally
# without needing to build+tag images
function compose {
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
    args=$2
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
    echo ${service:-$default}
}

# ============================================================================
# HELP
# ============================================================================

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

HELP_WIDTH=${HELP_WIDTH:-15}

function _help_format {
    cat - | awk "{printf \"${BLUE}%-${HELP_WIDTH}s${END_COLOR} %s\n\", \$1, substr(\$0, length(\$1) + 1);}"
}

function _help_makefile {
    if [ ! -f Makefile ]; then
        return
    fi
    grep -H -E '^[a-zA-Z_-]+:.*?## .*$$' Makefile* \
        | cut -d: -f2- \
        | sort \
        | sed 's/:\s*##\s*/ /g' \
        | _help_format

}

function _help_commands {
    bin=$0
    grep -E '^\s*## help:command' $bin \
        | cut -d: -f3- \
        | sort \
        | _help_format \
        || true
}

function _help_flags {
    bin=$0
    grep -E '^\s*## help:flag' $bin \
        | cut -d: -f3- \
        | sort \
        | _help_format \
        || true
}

# combine help from multiple sources
function _help_combined {
    echo -e ${YELLOW}$(basename $PWD)$END_COLOR
    echo
    echo -e ${YELLOW}${0}${END_COLOR} [flag ...] [command ...]
    echo

    echo -e ${YELLOW}Flags:${END_COLOR}
    echo
    {
        echo -h/--help print this message | _help_format
        _help_flags $@
    } | sort
    echo

    echo -e ${YELLOW}Commands:${END_COLOR}
    echo
    {
        echo help print this message | _help_format
        [ -f docker-compose.yml ] && echo build build local docker-compose images | _help_format
        _help_commands $@
        _help_makefile
    } | sort
}

# ============================================================================
# RUNNING
# ============================================================================

# exit early on some of the common flags script supports
# such as on --help or build
# usage:
# exit_on_common $@
function exit_on_common {
    # note target is explicitly $1 vs searching for flags anywhere in $@
    # as there could be other commands which accept nested flags like --help
    target=${1:-}
    case "$target" in
        -h | --help | help)
            _help_combined $@
            exit 0
            ;;
        build)
            compose build
            ;;
    esac
}
