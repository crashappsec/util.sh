YELLOW="\033[0;33m"
BLUE="\033[0;34m"
RED="\033[0;31m"
GREEN="\033[0;32m"
END_COLOR="\033[0m"
if [ -n "${NO_COLOR:-}" ]; then
    YELLOW=
    BLUE=
    RED=
    GREEN=
    END_COLOR=
fi
IYELLOW=$(echo -en $YELLOW)
IBLUE=$(echo -en $BLUE)
IRED=$(echo -en $RED)
IGREEN=$(echo -en $GREEN)
IEND_COLOR=$(echo -en $END_COLOR)

SOURCE=${BASH_SOURCE:-}

function _version {
    # https://stackoverflow.com/questions/4023830/how-to-compare-two-strings-in-dot-separated-version-format-in-bash
    echo "$@" | awk -F. '{ printf("%d%03d%03d%03d\n", $1,$2,$3,$4); }'
}

function _version_from_value {
    echo "$@" | grep -Eo '[0-9\.]+' | head -n1
}

if [[ $(_version $(_version_from_value $BASH_VERSION)) -lt $(_version 5) ]]; then
    echo -e "${RED}Detected old version of bash==$BASH_VERSION${END_COLOR}" > /dev/stderr
    echo -e "${RED}Please upgrade to bash>=5${END_COLOR}" > /dev/stderr
    if [ $(uname -s) = "Darwin" ]; then
        echo -e Usually: > /dev/stderr
        echo -e "\tbrew install bash" > /dev/stderr
    fi
    echo > /dev/stderr
    exit 1
fi

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
        echo -e ${RED}${command}${END_COLOR} or ${RED}${gnucommand}${END_COLOR} not found > /dev/stderr
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
function find { gnu find "$@"; }

# ============================================================================
# TOOLS
# ============================================================================

function _ensure_jq {
    if ! which jq &> /dev/null; then
        echo -e ${RED}jq is missing${END_COLOR} > /dev/stderr
        if [ $(uname -s) = "Darwin" ]; then
            echo -e Usually: > /dev/stderr
            echo -e "\tbrew install jq" > /dev/stderr
        fi
        exit 1
    fi
}

function _concurrent {
    cmd=
    for arg; do
        shift
        case "$arg" in
            --)
                cmd=$@
                break
                ;;
        esac
    done

    pids=()
    while read i; do
        $cmd $i &
        pids+=($!)
    done

    exit_codes=()
    for i in ${pids[@]}; do
        set +e
        wait $i
        exit_codes+=($?)
        set -e
    done

    # https://stackoverflow.com/questions/13635293/how-can-i-find-the-sum-of-the-elements-of-an-array-in-bash
    sum=$(
        IFS=+
        echo "$((${exit_codes[*]}))"
    )

    return $sum
}

# ============================================================================
# DOCKER
# ============================================================================

function _cat_all_compose_files {
    for i in $(echo $1 | tr ":" " "); do
        # only cat real files and no
        # process substitution devices
        # as if they are consumed they can no longer be read
        [ -f $i ] && cat $i
    done
}

function _strip_relative {
    echo ${1:-} | sed 's/^\.\/+//'
}

function _dockerfile_copied_files {
    context=${1:-.}
    dockerfile=${context%/}/${2:-Dockerfile}
    echo -e ${YELLOW}Dockerfile context${END_COLOR} $context > /dev/stderr
    echo -e ${YELLOW}Dockerfile${END_COLOR} $dockerfile > /dev/stderr
    if ! [ -e $dockerfile ]; then
        return
    fi
    (
        echo $dockerfile
        # sed concatenates all lines escaped with \
        # grep finds all COPY statements without --from
        # awk shows all columns except last
        for i in $(
            cat $dockerfile \
                | sed -e ':a' -e 'N' -e '$!ba' -e 's/\\\n/ /g' \
                | grep -Po '^COPY\K(\s+[^\s-][^\s]*)+' \
                | awk 'NF{NF--};1' \
                || true
        ); do
            stripped=$(_strip_relative $i)
            case $stripped in
                "") ;&
                .) ;&
                '$'*) ;&
                $(_strip_relative $(dirname $dockerfile | sed "s#^$context##")))
                    echo ignoring COPY $i > /dev/stderr
                    ;;

                *)
                    _strip_relative ${context%%/}/$i
                    ;;
            esac
        done
    ) | sort
}

# rebuild compose services if COPY files changed
# usage:
# compose_rebuild <service> [<service> ...]
function compose_rebuild {
    if [ -z "${CI:-}" ]; then
        echo -e "${RED}should only conditionally rebuild in CI. locally please use normal build${END_COLOR}" > /dev/stderr
        exit 1
    fi

    do_push=
    do_platform=
    for arg; do
        shift
        case "$arg" in
            --push)
                do_push=true
                ;;
            --platform=*)
                do_platform=${arg##*=}
                ;;
            *)
                set -- "$@" "$arg"
                ;;
        esac
    done

    if [[ -z "${@}" ]]; then
        echo -e "${RED}Specify compose service to rebuild${END_COLOR}" > /dev/stderr
        exit 1
    fi

    # if [ -n "$do_platform" ] && [ -z "$do_push" ]; then
    #     echo -e ${RED}Must --push when using --platform${END_COLOR} > /dev/stderr
    #     exit 1
    # fi

    function fetch {
        ref=$1
        echo -e "${YELLOW}$ref${END_COLOR} is not present locally. fetching" > /dev/stderr
        (
            set -x
            git fetch $remote $ref > /dev/stderr
        )
    }

    base_ref=${GITHUB_BEFORE_REF:-${GITHUB_BASE_REF:-main}}
    remote=$(git remote -v | head -n1 | awk '{ print $1 }')
    if git rev-parse --verify $base_ref &> /dev/null; then
        ref=$base_ref
    else
        if ! git rev-parse --verify $remote/$base_ref &> /dev/null; then
            fetch $base_ref
        fi
        ref=$(git rev-parse --verify $remote/$base_ref)
    fi
    if [ "$base_ref" = "$ref" ]; then
        echo -e "comparing to ${YELLOW}$ref${END_COLOR} ref" > /dev/stderr
    else
        echo -e "comparing to ${YELLOW}$base_ref${END_COLOR}@${YELLOW}$ref${END_COLOR} ref" > /dev/stderr
    fi
    if ! git cat-file -t $ref &> /dev/null; then
        fetch $ref
    fi
    diff="git diff --name-only HEAD..$ref"
    echo "$diff:" > /dev/stderr
    $diff | sed 's/^/\t/g' > /dev/stderr

    for i; do
        if IFS=" " read -r context dockerfile image < <(
            cat docker-compose.yml | python3 <(
                cat << EOF
import itertools, sys

def segment(needle, haystack):
    indent = " " * (2 + len(needle) - len(needle.lstrip()))
    lines = iter(haystack)
    list(itertools.takewhile(lambda i: not i.startswith(needle), lines))
    return list(itertools.takewhile(lambda i: i.startswith(indent), lines))

def value_of(needle, default, lines):
    line = next((i.strip() for i in lines if i.strip().startswith(needle)), '')
    return line.split(':', 1)[-1].split('#')[0].strip() or default

service =segment('  $i:', sys.stdin.read().splitlines())
build = segment('    build:', service)
if build:
    print(
        value_of('context', '.', build),
        value_of('dockerfile', 'Dockerfile', build),
        value_of('# CI image:', '', service),
    )
EOF
            )
        ); then

            if [ -z "$image" ]; then
                echo -e ${RED}$i${END_COLOR}: skipping as it does not have image defined > /dev/stderr
                continue
            fi
            echo -e ${YELLOW}$i${END_COLOR}: checking if COPY files changed > /dev/stderr
            for f in $(_dockerfile_copied_files "$context" "$dockerfile"); do
                f=$(realpath --relative-base=$(git rev-parse --show-toplevel 2> /dev/null) $f)
                # its valid change if the full path is valid
                # or its part of the path which includes trailing slash
                if $diff | grep "^$f\$" > /dev/null \
                    || $diff | grep "^$f/" 2> /dev/null; then
                    echo -e ${YELLOW}$i${END_COLOR}: ${GREEN}$f${END_COLOR} changed causing rebuild > /dev/stderr
                    if [ -z "$do_platform" ]; then
                        (CI= compose build $i)
                        hyphen=$(basename $(pwd))-$i
                        underscore=$(basename $(pwd))_$i
                        if docker inspect $hyphen 2>&1 > /dev/null; then
                            (
                                set -x
                                docker tag $hyphen $image
                            )
                        elif docker inspect $underscore 2>&1 > /dev/null; then
                            (
                                set -x
                                docker tag $underscore $image
                            )
                        else
                            echo -e "${RED}could not find compose built image. tried:${END_COLOR}" > /dev/stderr
                            echo -e "* ${YELLOW}${hyphen}${END_COLOR}" > /dev/stderr
                            echo -e "* ${YELLOW}${underscore}${END_COLOR}" > /dev/stderr
                            echo existing images: > /dev/stderr
                            docker image ls
                            exit 1
                        fi
                        if [ -n "$do_push" ]; then
                            (
                                set -x
                                docker push $image
                            )
                        fi
                    else
                        extra_args=
                        if [ -n "$do_push" ]; then
                            extra_args="$extra_args --push"
                        fi
                        (
                            set -x
                            docker buildx build \
                                -f $dockerfile \
                                --platform=$do_platform \
                                $extra_args \
                                --tag=$image \
                                .
                        )
                    fi
                    break
                else
                    echo -e ${YELLOW}$i${END_COLOR}: ${BLUE}$f${END_COLOR} didnt change > /dev/stderr
                fi
            done

        else
            echo -e ${RED}$i${END_COLOR}: skipping as it does not have build defined > /dev/stderr
        fi
    done
}

# wrapper around docker compose except:
# * in CI it switches to using images for caching
# * locally uses docker compose as-is which builds image from scratch
# this allows to easily update containers as necessary locally
# without needing to build+tag images
function compose {
    DOCKER_VERSION=$(_version_from_value $(docker --version))
    if [[ $(_version $DOCKER_VERSION) -lt $(_version 20.10.21) ]]; then
        echo -e "${RED}Detected old version of docker==$DOCKER_VERSION${END_COLOR}" > /dev/stderr
        echo -e "${RED}Please upgrade docker>=20.10.21${END_COLOR}" > /dev/stderr
    fi

    COMPOSE_VERSION=$(_version_from_value $(docker compose version))
    if [[ $(_version $COMPOSE_VERSION) -lt $(_version 2) ]]; then
        echo -e "${RED}Detected old version of docker compose==$COMPOSE_VERSION${END_COLOR}" > /dev/stderr
        echo -e "${RED}Please ensure you are using docker compose>=2${END_COLOR}" > /dev/stderr
        echo -e "\thttps://docs.docker.com/compose/compose-v2/" > /dev/stderr
    fi

    args=$@
    do_build=
    for arg; do
        shift
        case "$arg" in
            --*)
                break
                ;;
            build)
                do_build=true
                ;;
        esac
    done
    set -- $@ $args

    compose_file=
    no_deps=
    for arg; do
        shift
        case "$arg" in
            --no-deps)
                no_deps=true
                ;;
            -f | --file)
                compose_file=$compose_file:$1
                ;;
            --file=*)
                compose_file=$compose_file:${arg##*=}
                ;;
        esac
        compose_file=${compose_file##:}
    done
    set -- $@ $args
    compose_file=${compose_file:-${COMPOSE_FILE:-docker-compose.yml}}

    # by default docker when mounts a non-existing path will create a folder
    # vs sometimes we would like to mount optional config files
    # marking mount with "# ensure:file" will touch that file if not present
    # so that docker can mount a file, not a folder
    for i in $(
        _cat_all_compose_files $compose_file \
            | grep -E '# ensure:file$' \
            | awk '{ print $2 }' \
            | cut -d: -f1
    ); do
        path=$(eval echo $i)
        if ! [ -f $path ]; then
            (
                set -x
                touch $path
            )
        fi
    done

    # docker compose does not create external networks
    # however to connect containers between repos
    # external network must be used as docker bridge network
    # does not work on MacOSX
    # so we should ensure external network is created
    for i in $(
        _cat_all_compose_files $compose_file \
            | grep -E '# ensure:network$' \
            | awk '{ print $1 }' \
            | cut -d: -f1
    ); do
        # https://unix.stackexchange.com/questions/22044/correct-locking-in-shell-scripts
        lockfile=/tmp/docker-network-$i
        if (
            set -o noclobber
            echo "$$" > "$lockfile"
        ) 2> /dev/null; then
            trap 'rm -f "$lockfile"; exit $?' INT TERM EXIT
            if ! docker network inspect $i &> /dev/null; then
                (
                    set -x
                    docker network create $i > /dev/stderr
                )
            fi
            # clean up after yourself, and release your trap
            rm -f "$lockfile"
            trap - INT TERM EXIT
        fi
    done

    if [ -z "$no_deps" ] && [ -z "$do_build" ]; then
        # docker compose does not allow to depend on external docker compose files
        # which is useful when we want to link to deps from external deps
        # so we manually "glue" external deps
        for i in $(
            _cat_all_compose_files $compose_file \
                | grep -E '# depends_on:' \
                | cut -d# -f2
        ); do
            IFS=":" read -r service depends_on depends_on_path < <(eval echo $i | cut -d: -f2-)
            depends_on_dir=$(dirname $depends_on_path)
            depends_on_compose_file=$(basename $depends_on_path)

            # very stupid method to detect if we are attemptint to run service
            if [[ $@ = *"$service"* ]]; then
                if ! [ -f $depends_on_path ]; then
                    echo -e ${RED}\'$depends_on_path\' is missing to start $depends_on${END_COLOR} > /dev/stderr
                    exit 1
                fi

                if ! (
                    cd $depends_on_dir
                    COMPOSE_PROJECT_DIR=$depends_on_dir \
                        compose \
                        -f $depends_on_compose_file \
                        ps \
                        --status running \
                        $depends_on
                ) \
                    | grep '(healthy)' \
                        &> /dev/null; then

                    if (
                        cd $depends_on_dir
                        COMPOSE_PROJECT_DIR=$depends_on_dir \
                            compose \
                            --file $depends_on_compose_file \
                            --file <(
                                cat << EOF
version: "3"
services:
    wait_for_$depends_on:
        image: busybox
        command: "true"
        depends_on:
            $depends_on:
                condition: service_healthy
EOF
                            ) \
                            run \
                            --rm \
                            wait_for_$depends_on \
                            | cat
                    ); then
                        echo -e ${GREEN}Started $depends_on from \'$depends_on_path\'${END_COLOR} > /dev/stderr
                    else
                        echo -e ${RED}Failed to start $depends_on from \'$depends_on_path\'${END_COLOR} > /dev/stderr
                        exit 1
                    fi
                fi
            fi
        done
    fi

    if [ -n "${CI:-}" ]; then
        # sed uncomments lines starting with "# CI"
        # and removes lines ending with "# CI"
        # therefore allowing to switch what is used locally and in CI
        set -x
        exec docker compose \
            -f <(cat docker-compose.yml | sed -r -e 's/^(\s+)# CI\s*(.*)/\1\2/g' -e '/# CI/d') \
            --project-directory $PWD \
            "$@"
    else
        set -x
        exec docker compose "$@"
    fi
}

# if Makefile target specifies which docker compose service to use
# get its name to be used with docker compose
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
        # and if it finds such a line, it extracts docker compose service
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
        # and if it finds such a line, it extracts docker compose service
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
# AWS
# ============================================================================

function _ensure_aws_profile {
    if ! which aws &> /dev/null; then
        echo -e ${RED}aws cli is missing${END_COLOR} > /dev/stderr
        echo -e Usually: > /dev/stderr
        echo -e "\tpipx install awscli" > /dev/stderr
        exit 1
    fi
    if ! aws sts get-caller-identity > /dev/null; then
        echo -e ${RED}aws cli does not seem to be authenticated${END_COLOR} > /dev/stderr
        echo -e ${RED}ensure:${END_COLOR} > /dev/stderr
        echo -e "\t* MFA creds are setup. See Notion how to set that up" > /dev/stderr
        echo -e "\t* Rerun 'aws-mfa' to ensure MFA session token is up-to-date" > /dev/stderr
        exit 1
    fi
}

# get the content of the aws secret subkey
# usage:
# aws_secret <secretid> <key>
function aws_secret {
    _ensure_jq
    _ensure_aws_profile
    id=$1
    key=$2
    (
        set -x
        aws secretsmanager \
            get-secret-value \
            --secret-id=$id \
            --query='SecretString' \
            --output=text \
            | jq ".$key" -r
    )
}

# lookup full ecr repo by its name
# usage:
# aws_ecr_repo <name>
function aws_ecr_repo {
    name=$1
    if [[ "$name" = *amazonaws.com* ]]; then
        echo $name
        return
    fi
    _ensure_aws_profile
    (
        set -x
        aws ecr describe-repositories \
            --repository-names=$name \
            --query='repositories[].repositoryUri' \
            --output=text
    )
}

# login to ecr repo
# usage:
# aws_ecr_login <name>
function aws_ecr_login {
    docker_repo=$(aws_ecr_repo $1)
    _ensure_aws_profile
    (
        set -x
        aws ecr get-login-password | docker login --username AWS --password-stdin $docker_repo > /dev/stderr
    )
}

# redeploy ecr image
# usage:
# aws_ecr_redeploy --repo=* [--tag=*] [--name] [--login] [--build] [--push] [--redeploy] [--ecs] [--lambda] [-- <cmd>]
function aws_ecr_redeploy {
    repo=
    tag=
    branch=
    retag=
    cmd="docker build ."

    do_show_name=
    do_login=
    do_build=
    do_retag=
    do_latest=
    do_git_tag=
    do_git_branch=
    do_push=
    do_redeploy=
    do_ecs=
    do_lambda=

    for arg; do
        shift
        case "$arg" in
            --repo=*)
                repo=${arg##*=}
                ;;
            --tag=*)
                tag=${arg##*=}
                ;;
            --retag=*)
                retag=${arg##*=}
                ;;
            --name)
                do_show_name=true
                ;;
            --login)
                do_login=true
                ;;
            --build)
                do_build=true
                ;;
            --push)
                do_push=true
                ;;
            --redeploy)
                do_redeploy=true
                ;;
            --latest)
                do_latest=true
                ;;
            --git-tag)
                do_git_tag=true
                ;;
            --git-branch)
                do_git_branch=true
                ;;
            --ecs)
                do_ecs=true
                ;;
            --lambda)
                do_lambda=true
                ;;
            --)
                cmd=$@
                break
                ;;
            *)
                echo -e "${RED}unsupported deploy flag ${YELLOW}${arg}${END_COLOR}" > /dev/stderr
                exit 1
                ;;
        esac
    done

    if [ -z "$repo" ]; then
        echo -e "${RED}--repo=* is required${END_COLOR}" > /dev/stderr
        exit 1
    fi

    if [ -z "$do_show_name$do_login$do_build$do_push$do_redeploy" ]; then
        do_show_name=true
        do_login=true
        do_build=true
        do_push=true
        do_redeploy=true
    fi
    if [ -z "$do_latest$do_git_tag$do_git_branch" ]; then
        do_latest=true
        do_git_tag=true
        do_git_branch=true
    fi
    if [ -z "$do_ecs$do_lambda" ]; then
        do_ecs=true
        do_lambda=true
    fi

    if [ -z "$tag" ] && [ -n "$do_git_tag" ]; then
        tag=$(git describe --tags 2> /dev/null | sed 's/^v//' || true)
    fi
    if [ -z "$tag" ] && [ -n "$do_latest" ]; then
        tag=latest
    fi

    if [ -z "$tag" ]; then
        echo -e "${RED}tag is required${END_COLOR}" > /dev/stderr
        echo -e "${RED}either pass ${YELLOW}--tag=*${RED} or allow auto-version via ${YELLOW}--git-tag${RED} and/or ${YELLOW}--latest${END_COLOR}" > /dev/stderr
        exit 1
    fi

    branch=$(git symbolic-ref --short HEAD 2> /dev/null || echo "${GITHUB_HEAD_REF:-}")
    if [ -z "$branch" ] && [ -n "$do_git_branch" ]; then
        echo -e "${RED}could not determine git branch${END_COLOR}" > /dev/stderr
        exit 1
    fi

    repo=$(aws_ecr_repo $repo)
    name=$repo:$tag
    name_latest=$repo:latest
    name_branch=$repo:$(echo $branch | sed 's/[\/]/-/')

    if [ -n "$do_show_name" ]; then
        echo $name
    fi
    if [ -n "$do_login" ]; then
        aws_ecr_login $name
    fi
    if [ -n "$do_build" ]; then
        if [ -n "$retag" ]; then
            (
                set -x
                ($cmd)
                docker tag $retag $name
            )
        else
            (
                set -x
                ($cmd --tag $name)
            )
        fi
    fi
    if [ -n "$do_push" ]; then
        (
            set -x
            docker push $name
        )
        if [ -n "$do_latest" ]; then
            (
                set -x
                docker tag $name $name_latest
                docker push $name_latest
            )
        fi
        if [ -n "$do_latest" ]; then
            (
                set -x
                docker tag $name $name_branch
                docker push $name_branch
            )
        fi
    fi
    if [ -n "$do_redeploy" ]; then
        names=$name
        if [ -n "$do_latest" ]; then
            names="$names $name_latest"
        fi
        if [ -n "$do_git_branch" ]; then
            names="$names $name_branch"
        fi
        for i in $(echo $names | tr " " "\n" | sort -u); do
            (
                if [ -n "$do_ecs" ]; then
                    echo aws_ecs_redeploy_by_image $i
                fi
                if [ -n "$do_lambda" ]; then
                    echo aws_lambda_redeploy_by_image $i
                fi
            ) | _concurrent
        done
    fi
}

# redeploy existing ecs service
# usage:
# aws_ecs_redeploy <cluster> <service>
function aws_ecs_redeploy {
    cluster=$1
    service=$2
    (
        set -x
        aws ecs update-service --cluster $cluster --service $service --force-new-deployment
        aws ecs wait services-stable --cluster $cluster --service $service
    )
}

# redeploy existing ecs service
# usage:
# aws_ecs_redeploy_by_image <image_uri>
function aws_ecs_redeploy_by_image {
    image_uri=$1
    function redeploy {
        arn=$1
        IFS="/" read -r _ cluster service < <(echo $arn)
        aws_ecs_redeploy $cluster $service
    }
    aws \
        resourcegroupstaggingapi \
        get-resources \
        --resource-type-filters=ecs:service \
        --tag-filters=Key=image_uri,Values=$image_uri \
        --query='ResourceTagMappingList[].ResourceARN' \
        --output=text \
        | tr '\t' '\n' \
        | _concurrent -- redeploy
}

# redeploy existing lambda
# usage:
# aws_ecs_redeploy <image_uri>
function aws_lambda_redeploy_by_image {
    image_uri=$1
    function redeploy {
        arn=$1
        echo $arn > /dev/stderr
        (
            set -x
            aws lambda update-function-code --function-name $arn --image-uri $image_uri
            aws lambda wait function-updated --function-name $arn
        )
    }
    aws \
        resourcegroupstaggingapi \
        get-resources \
        --resource-type-filters=lambda:function \
        --tag-filters=Key=image_uri,Values=$image_uri \
        --query='ResourceTagMappingList[].ResourceARN' \
        --output=text \
        | tr '\t' '\n' \
        | _concurrent -- redeploy
}

# ============================================================================
# HELP
# ============================================================================

HELP_WIDTH=${HELP_WIDTH:-15}

function _help_format {
    cat - | awk "{printf \"${BLUE}%-${HELP_WIDTH}s${END_COLOR} %s\n\", \$1, substr(\$0, length(\$1) + 1);}"
}

function _help_file_makefile {
    grep -H -E '^[a-zA-Z0-9_-]+:.*?## .*$$' Makefile* \
        | cut -d: -f2- \
        | sort \
        | sed 's/:\s*##\s*/ /g' \
        | _help_format \
        || true
}

function _help_file_packagejson {
    grep -H -E '"[a-zA-Z0-9:_\.-]+":.*?## .*$$' package.json \
        | cut -d: -f2- \
        | sort \
        | sed -r 's/^\s+"(.*)":\s+".*##\s+(@@[a-zA-Z0-9:_-]+\s+)?(.*)",?$/\1 \3/g' \
        | _help_format \
        || true
}

function _help_file_commands {
    bin=$1
    if [ ! -f $bin ]; then
        return
    fi
    case "$bin" in
        Makefile)
            _help_file_makefile
            ;;
        package.json)
            _help_file_packagejson
            ;;
        *)
            grep -E '^\s*## help:command' $bin \
                | cut -d: -f3- \
                | sort \
                | _help_format \
                || true
            ;;
    esac
}

function _help_file_flags {
    bin=$1
    grep -E '^\s*## help:flag' $bin \
        | cut -d: -f3- \
        | sort \
        | _help_format \
        || true
}

function _help_header {
    echo -e ${YELLOW}$(basename $PWD)$END_COLOR
    echo
    echo -e ${YELLOW}$(basename $0)${END_COLOR} [flag ...] [command ...]
    echo
}

function _help_flags {
    echo -e ${YELLOW}Flags:${END_COLOR}
    echo
    {
        for i in $@; do
            _help_file_flags $i
        done
    } | sort | uniq
}

function _help_commands {
    echo -e ${YELLOW}Commands:${END_COLOR}
    echo
    {
        for i in $@; do
            _help_file_commands $i
        done
    } | sort | uniq
}

function _help_usage {
    for i in $@; do
        if [ ! -f $i ]; then
            continue
        fi
        if which glow &> /dev/null; then
            glow $i
        elif which bat &> /dev/null; then
            echo
            bat --style=plain $i
        else
            echo
            echo -e "${YELLOW}glow/bat${RED} is not installed. cannot pretty show ${YELLOW}$i${END_COLOR}" > /dev/stderr
            if [ $(uname -s) = "Darwin" ]; then
                echo -e Usually: > /dev/stderr
                echo -e "\tbrew install glow bats" > /dev/stderr
            fi
            echo
            cat $i
        fi
    done
}

if [[ $(type -t show_help) != function ]]; then
    # combine help from multiple sources
    # usage:
    # show_help $@
    function show_help {
        _help_header

        _help_flags $0 $SOURCE
        echo
        _help_commands $0 $SOURCE Makefile package.json

        _help_usage USAGE.md

        exit 0
    }
fi

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
    ## help:command:rebuild rebuild local docker compose service if any files in COPY changed
    rebuild)
        shift
        compose_rebuild $@
        exit 0
        ;;
    ## help:command:build build local docker compose images
    build)
        compose $@
        ;;
    ## help:command:pull pull latest docker compose images
    pull)
        compose $@
        ;;
    ## help:command:down trash all local containers including all their state/volumes
    down)
        compose $@ --volumes --remove-orphans
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
        echo -e ${RED}Local cached copy of \'${SOURCE}\' is outdated${END_COLOR} > /dev/stderr
        echo -e ${RED}${util_url} has newer version${END_COLOR} > /dev/stderr
        echo -e ${RED}To get latest version you can remove local cached copy with:${END_COLOR} > /dev/stderr
        echo -e "\trm ${SOURCE}" > /dev/stderr
        echo > /dev/stderr

    # if up to date then touch file so that its not checked again for $util_check_min
    else
        touch ${SOURCE}
    fi
fi
