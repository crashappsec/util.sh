# Util.sh

Common builder bash utilities across multiple CrashOverride repos

## Usage

Add to `build.sh`:

```bash
util=_util.sh
commit=main # or pin commit/tag
util_url=https://raw.githubusercontent.com/crashappsec/util.sh/$commit/util.sh
[ ! -f $util ] && curl -f -L $util_url -o $util
source $util
```

This will allow you to call reusable functions. For example:

```bash
exit_on_common $@
```

## Conventions

`util.sh` exposes multiple bash functions. All function names starting with
`_` are considered private functions and should not be directly used. Other
functions are allowed to be used. All public functions in the comment above
have usage example how to use them.

## Help

`util.sh` can also auto-generate help from the both the bash files
as well as other supporting files.

To see help simply run either:

```bash
./build.sh help
./build.sh -h
./build.sh --help
```

### Bash

#### commands

Add a comment with the format:

```bash
## help:command:<commandname> <description>
```

For example:

```bash
## help:command:lint run lint checks
```

#### flags

In addition to documenting commands, flags can be documented as well:

```bash
## help:flag:<flag> <description>
```

For example:

```bash
## help:flag:-v/--verbose show debug logs
```

### `Makefile`

Each Makefile target can document its help with:

```make
<target>: ## <description>
```

For example:

```make
lint: ## run lint checks
```

### `package.json`

As this is a json file, to keep syntax valid json, all help strings are
extracted from the script string itself:

```json
{
  "scripts": {
    "<name>": "<command> ## <description>"
  }
}
```

For example:

```json
{
  "scripts": {
    "lint": "eslint ## run lint checks"
  }
}
```

## Compose Service

`util.sh` can also automatically figure out which compose service should be
used for the given command. The `service_for_compose ` accepts the default
service if not override is found. Overrides can be specified like so:

### `Makefile`

```
<target>: # docker-compose:<service>
```

For example:

```make
lint: # docker-compose:precommit
```

### `package.json`

`docker-compose` service is annotated as part of the help description

```json
{
  "scripts": {
    "<name>": "<command> ## @@docker-compose:<service> <description>"
  }
}
```

For example:

```json
{
  "scripts": {
    "test": "playwright test ## @@docker-compose:tests run UI tests"
  }
}
```
