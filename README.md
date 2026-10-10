# encapsule

CLI tool to run developer containers, isolating your home directory and host from general effects inside the containers:
"encapsules" a project and/or temp home dir together with select "capabilities".

Originally derived from [toolbox-constrained](https://github.com/swick/toolbox-constrained).

Run a ([toolbox](https://containertoolbx.org/)) container or image as
an isolated podman container. Unlike with `toolbox create`, this does *not*
bind-mount your home directory or integrate with the host by default.
You can explicitly choose what dir(s) or file(s) to mount or features to enable,
selecting user-configured "capabilities" that the encapsule container can access.

Most encapsule subcommands act on an image.
- If you wish to use an existing toolbox container as a starting point you can `commit` it to an "encapsule" container image.
  - Note your original toolbox container is left untouched: its system configuration and fs are just used as the base fs for the encapsule image (though its original bind mounts including $HOME will be not be included by default).
- Alternatively you can roll your own image or run a vanilla image like `fedora` (`fedora:latest`), `fedora-toolbox:45`, `ubuntu:latest`, etc.
  - Toolbox images or containers are generally recommended for development, but it doesn't have to be a toolbox container as such.

A typical invocation might look like:

```
$ encapsule someimage:tag --cap my-config --home ~/isolated --project projects/abc
```

(directories can be relative).

Encapsule images and containers are prefixed by `encapsule-`,
but there is no need to use this prefix normally - it is implicit.

## Usage

`$ encapsule --version`

```
0.6
```

`$ encapsule --help`

```
encapsule

Usage: encapsule [--version] COMMAND

  Run a toolbox image in an isolated podman container
  https://github.com/juhp/encapsule#readme

Available options:
  -h,--help                Show this help text
  --version                Show version

Available commands:
  list                     List encapsule images and containers
  list-caps                List available capabilities
  rm                       Remove an encapsule container
  rmi                      Remove an encapsule image
  stop                     Stop an encapsule container
  backup                   Create a tarball backup of a directory
  commit                   Commit an encapsule image from a container
  create                   Create an encapsule container
  enter                    Connect to an encapsule container
  run                      Run a temporary encapsule container
```

There are 3 main commands: `run`, `create`, and `enter`.
`run` and `create` share many options.

### `run` command

`run` starts a temporary encapsule container (removed on exit) from an image.

`$ encapsule run --help`

```
Usage: encapsule run IMAGE [-v|--volume HOST:CONTAINER[:opts]]
                     [-e|--env KEY[=VALUE]] [--path DIR] [-i|--init CMD]
                     [--cap NAME] [--pull] [--root | --user USER]
                     [(-H|--home DIR[:opts]) [--backup-home]]
                     [(-p|--project DIR[:opts]) [--backup-project]]
                     [-n|--name NAME] [--readonly]
                     [--no-network | --network-host] [--sudo] [--no-skel]
                     [--podman-opt OPTION] [--debug] [--dryrun] [[--] CMD]

  Run a temporary encapsule container

Available options:
  -v,--volume HOST:CONTAINER[:opts]
                           Bind mount (user's files default to selinux :z)
  -e,--env KEY[=VALUE]     Set or pass through an environment variable
  --path DIR               Prepend a directory to PATH inside the container
  -i,--init CMD            A bash snippet run when creating the encapsule
                           container
  --cap NAME               Enable a capability from the config file
  --pull                   Pull newer container image
  --root                   Run as root (shorthand for --user root)
  --user USER              Override container user [default: host/image user
                           with host UID]
  -H,--home DIR[:opts]     Mount a directory as a writable home (created if
                           missing; use DIR:O to overlay)
  --backup-home            Tarball home directory before starting
  -p,--project DIR[:opts]  Mount a (project) directory as workdir (use DIR:O to
                           overlay)
  --backup-project         Tarball project directory before starting
  -n,--name NAME           Optional container name (prefix with '^' prefix to
                           skip 'encapsule-' prefix)
  --readonly               Make the encapsule container filesystem read-only
  --no-network             Disable network access
  --network-host           Share the host network (including localhost ports)
  --sudo                   Set up passwordless sudo for the container user
  --no-skel                Don't copy /etc/skel into an empty home
  --podman-opt OPTION      Pass an option directly to podman
  --debug                  Show debug output
  --dryrun                 Print the podman command instead of running it
  -h,--help                Show this help text
```

Use `--network-host` with `run` (or `create`) to make servers on arbitrary
container localhost ports reachable on the same host localhost ports.
This also allows access to host-local services and shares the host's port
space. It cannot be combined with `--no-network`. Without either option,
Podman's default isolated container networking applies.

### `create` command
`create` is similar but creates a reusable container for a project and/or temp home.

### `enter` command
`enter` is used to join an existing (typically running) encapsule container.
An optional command can be given, as with `run`:

```bash
$ encapsule enter my-toolbox -- tmux
```

By default `enter` uses the user matching the host UID. Use `--root` (or
`--user root`) when administrative access is needed:

```bash
$ encapsule enter --root my-toolbox
```

### `commit` command
`commit` saves a container as an encapsule image (`encapsule-CONTAINER` by default).
Use `-n/--name NAME` for a custom image name (becomes `encapsule-NAME`, or `^NAME` to skip the prefix).

### `list` command
Lists the encapsule images and containers:

```
$ ncpsl list
localhost/encapsule-harness:latest  6.15 GB  12 days ago

encapsule-harness-encapsule  Up 31 hours
encapsule-fedora  Up 29 minutes
encapsule-fedora-toolbox-45  Up 5 seconds
```

### `backup` command
This is really independent of encapsule.
It provides a simple way to create a backup tarball of a (git) project or dir.
There are also runtime `--backup-project` and `--backup-home` options.


## Examples

```bash
# Temporary isolated shell without host fs access
~$ encapsule run fedora-toolbox:44

# Mount current (project) directory path and set it as the working directory
# (also names the container after the project, e.g. encapsule-ubuntu-myproj)
~/myproj$ encapsule create ubuntu -p .

# Bind mount a volume
$ encapsule run fedora -v ~/data:/data

# create a custom "encapsule-fedora-toolbox-45" image from a toolbox container
$ encapsule commit fedora-toolbox-45

# Mount a temp "home" directory in the committed encapsule image
$ encapsule run fedora-toolbox-45 --home ~/tmp/home

# Save another encapsule image named "encapsule-dev"
$ encapsule commit --name dev fedora-toolbox-45

# Use capabilities from one's config
$ encapsule create dev --cap ssh --cap git

# Remove encapsule container
$ encapsule rm dev

# create "encapsule-my-toolbox" image
$ encapsule commit fedora-toolbox-45 --name my-toolbox

# Read-only container filesystem
$ encapsule run my-toolbox --readonly

# Set environment variables and prepend to PATH
$ encapsule run my-toolbox -e MY_VAR=hello -e LANG --path ~/.local/bin

# Run a specific command
$ encapsule run my-toolbox -- ls /

# Run a setup init scriptlet
$ encapsule run fedora-toolbox:45 -p proj --init "dnf install -y gcc make"

# Dry run: print the full podman command without running it
$ encapsule run --dryrun my-toolbox
```

There is a `rmi` command to remove an encapsule image no longer needed.

## Capabilities

Capabilities define reusable groups of volumes, environment variables,
PATH entries, and init commands in `/usr/share/encapsule/config.toml`
and `~/.config/encapsule/config.toml`:

```toml
[capabilities.ssh]
volumes = ["~/.ssh:~/.ssh:ro"]

[capabilities.git]
volumes = ["~/.gitconfig:ro"]

[capabilities.wayland]
env = ["WAYLAND_DISPLAY", "XDG_RUNTIME_DIR"]
volumes = ["$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY"]
security_opts = ["label=disable"]

[capabilities.rust]
path = ["~/.cargo/bin"]
```

There is an example user config file: `example/config.toml`.

Use `encapsule list-caps` to list all the available defined capabilities.

Each capability can define:

- `volumes` : list of bind mount specs
- `env` : list of environment variables to set or pass through
- `path` : list of directories to prepend to `$PATH`
- `init` : a bash snippet to run on encapsule container creation
- `security_opts` : list of `--security-opt` values passed to podman

`~` and envvars are expanded in volume and path specs.
If the host and container paths are the same, you can use the shorthand
`PATH[:opts]` instead of `PATH:PATH[:opts]`.

The default defined capabilities live in the bundled `data/config.toml` file.
These capabilities can be overridden by XDG system config files
(under `XDG_CONFIG_DIRS`): by default `/etc/xdg/encapsule/config.toml`.
User settings (under `XDG_CONFIG_HOME`) take precedence over these settings;
earlier directories in `XDG_CONFIG_DIRS` take precedence over later ones.
Nested tables are merged, so overriding one field of a capability preserves
its other system defaults. Arrays are replaced rather than appended;
use an empty array to clear a default.

Note that an existing XDG system config, even an empty file,
replaces the bundled default definitions entirely,
whereas the user config will augment or modify them.

To be quite clear, no capabilities are used by default:
they need to be explicitly enabled on the commandline.
The definitions just make them available to use.

## How it works

0. Optionally commits the named toolbox container to an encapsule image (using `podman commit`).
1. Runs `podman run` with `--userns=keep-id` so you are your own user, not root
2. Drops from root with `runuser` if present, otherwise `sudo -u`. Explicit
   `--user root`/`--root` runs directly as root (`enter` uses
   `podman exec --user`)
3. Does not grant privilege escalation by default. `--sudo` opts into a
   passwordless sudoers entry when the image contains `sudo`
4. Bind mounts get SELinux `:z` (shared) labels automatically,
   so multiple containers can safely access the same directories
5. When `-p/--project DIR` is used (and `--name` isn't), the container name
   includes the project directory's name (e.g. `encapsule-mytoolbox-myproject`),
   so you can run the same toolbox against different projects at the same time
   in separate encapsule containers. For invocations with the same name,
   the container name gets differentiated by pid.

## Installation

Encapsule is packaged in Fedora: <https://src.fedoraproject.org/rpms/encapsule>

## Building from source

Install `cabal-install` and `ghc`.

```bash
cabal install
```


### Build with stack
Alternatively you can build with:
```
stack install
```

### Build release
To build the latest release: `cabal install encapsule`
or `stack install encapsule`.

## Tests

`cabal test` runs an hspec suite that drives the `encapsule` CLI
(`--dryrun` against local images, plus an optional live `run`).
It needs podman and skips missing images.

Default images are `fedora:latest` and `ubuntu:latest`.
Override with `ENCAPSULE_TEST_FEDORA` and `ENCAPSULE_TEST_UBUNTU`.
Live tests need a TTY, or set `ENCAPSULE_LIVE=1` to try without one.
`ENCAPSULE` selects a different encapsule binary.

```bash
cabal test
```

`cabal bench` times `encapsule run --dryrun` and a short `run -- true`
against a local image (same env vars as tests). It requires podman and an
image. It measures wall-clock time. To log timings:

```bash
cabal bench --benchmark-options '--csv /tmp/encapsule-bench.csv --time-limit 3'
# later: --baseline /tmp/encapsule-bench.csv
```

## Runtime Requirements

- [podman](https://podman.io/)
- An existing (toolbox) image (optionally created from a container with `toolbox create`).
  - There is a `--pull` option (intended for refreshing) - you may prefer to `podman pull` down your image first.
- Encapsule has only been tested on Linux.

## Related projects

I already mentioned [toolbox-constrained](https://github.com/swick/toolbox-constrained) from which the initial code was derived.

There is also similarly [schupfn](https://github.com/whot/schupfn/) which uses QEMU to run a toolbox container image in a VM with a direct private ssh connection.

Another somewhat related project is [podenv](https://github.com/podenv/podenv), which "provides a declarative interface to manage containerized applications."

For stronger sandboxing and isolation, specially network, consider using [OpenShell](https://github.com/NVIDIA/OpenShell/). At some point this project might support openshell perhaps.

There is also [litterbox](https://github.com/Gerharddc/litterbox) which has quite a lot of features and though somewhat opinionated, for example like openshell also supports landlock confinement.

## Disclaimer
The simple isolation provided is limited best effort and
comes with no (security) warranty.
Please use this tool at your own risk.

Reports, suggests, and contributions to improve the tool are very welcome.

## Contribute

`encapsule` is at <https://github.com/juhp/encapsule> and distributed
under the Apache-2.0 license.
