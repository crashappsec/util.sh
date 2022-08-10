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
