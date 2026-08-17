# encapsule

CLI tool to run developer containers, isolating your home directory and host from general effects inside the containers:
"encapsules" a project and/or temp home dir together with select "capabilities".

Originally derived from [toolbox-constrained](https://github.com/swick/toolbox-constrained).

Run a ([toolbox](https://containertoolbx.org/)) container or image as
an isolated podman container. Unlike with `toolbox create`, this does *not*
bind-mount your home directory or integrate with the host by default.
You can explicitly choose what dir(s) or file(s) to mount or features to enable,
selecting user-configured "capabilities" that the encapsule container can access.

```
encapsule COMMAND TOOLBOX [options] [CMD...]
```

if TOOLBOX is a container it will be committed (saved) to an "encapsule" container image from the named toolbox container using buildah.
(Though toolbox containers are recommended, as such it doesn't have to be a toolbox container.)
Your original toolbox container is left untouched: its system configuration and fs are just used as the base fs for the encapsule image.

Encapsule images and containers are prefixed by `encapsule-`.

## Usage

`$ encapsule --version`

```
0.5
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
  enter                    Connect to a encapsule container
  run                      Run a temporary encapsule container
```

There are 3 main commands: `run`, `create`, and `enter`.
`run` and `create` share many options.

### `run` command

`run` starts a temporary encapsule container (removed on exit)
from a (toolbox) image or container.

`$ encapsule run --help`

```
Usage: encapsule run IMAGE [-v|--volume HOST:CONTAINER[:opts]]
                     [-e|--env KEY[=VALUE]] [--path DIR] [-i|--init CMD]
                     [--cap NAME] [--pull]
                     [(-H|--home DIR[:opts]) [--backup-home]]
                     [(-p|--project DIR[:opts]) [--backup-project]]
                     [-n|--name NAME] [--readonly] [--no-network] [--no-sudo]
                     [--no-skel] [--podman-opt OPTION] [--debug] [--dryrun]
                     [CMD]

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
  --no-sudo                Skip passwordless sudo setup
  --no-skel                Don't copy /etc/skel into an empty home
  --podman-opt OPTION      Pass an option directly to podman
  --debug                  Show debug output
  --dryrun                 Print the podman command instead of running it
  -h,--help                Show this help text
```

### `create` command
`create` is similar but creates a reusable container for a project and/or tmp home.

### `enter` command
`enter` is used to join an existing (typically running) encapsule container.

## Examples

```bash
# Temporary isolated shell without host fs access
~$ encapsule run my-toolbox

# Mount current (project) directory path and set it as the working directory
# (also names the container after the project, e.g. encapsule-my-toolbox-myproject)
~/myproj$ encapsule create my-toolbox -p .

# Bind mount a volume
$ encapsule run my-toolbox -v ~/data:/data

# Mount a temp "home" directory (created if it doesn't exist)
$ encapsule run my-toolbox --home /tmp/somedir

# Use capabilities from one's config
$ encapsule create my-toolbox --cap ssh --cap git

# Read-only container filesystem
$ encapsule run my-toolbox --readonly

# Remove encapsule container
$ encapsule rm my-toolbox

# Set environment variables and prepend to PATH
$ encapsule run my-toolbox -e MY_VAR=hello -e LANG --path ~/.local/bin

# Run a specific command
$ encapsule run my-toolbox -- ls /

# Dry run: print the full podman command without running it
$ encapsule run --dryrun my-toolbox

# run directly from an image
$ encapsule run fedora:44 --home tmphome
```

Note a saved encapsule image remains cached for next time,
but can be removed with the `rmi` command.

## Capabilities

Capabilities define reusable groups of volumes, environment variables,
PATH entries, and init commands in `~/.config/encapsule/config.toml`:

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

Each capability can define:

- `volumes` : list of bind mount specs
- `env` : list of environment variables to set or pass through
- `path` : list of directories to prepend to `$PATH`
- `init` : a bash snippet to run on encapsule container creation
- `security_opts` : list of `--security-opt` values passed to podman

`~` and envvars are expanded in volume and path specs.
If the host and container paths are the same, you can use the shorthand
`PATH[:opts]` instead of `PATH:PATH[:opts]`.

## How it works

1. Commits the named toolbox container to an encapsule image using `buildah commit`
   (reuses the existing image unless `--refresh` is passed)
2. Runs `podman run` with `--userns=keep-id` so you are your own user, not root
3. Tries to install runuser (util-linux) and sudo (unless `--no-sudo`) if they are missing with dnf or apt-get.
4. Sets up passwordless `sudo` inside the encapsule container (unless `--no-sudo`)
5. Bind mounts get SELinux `:z` (shared) labels automatically,
   so multiple containers can safely access the same directories
6. When `-p/--project DIR` is used (and `--name` isn't), the container name
   includes the project directory's name (e.g. `encapsule-mytoolbox-myproject`),
   so you can run the same toolbox against different projects at the same time
   in separate encapsule containers

## Installation

A copr repo is available for Fedora and EPEL 10:

<https://copr.fedorainfracloud.org/coprs/petersen/encapsule/>

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
It needs podman, skips (pending) missing images, and does not pull.

Default images are `ubuntu:latest` and `fedora:latest`.
Override with `ENCAPSULE_TEST_UBUNTU` and `ENCAPSULE_TEST_FEDORA`.
Live tests need a TTY, or set `ENCAPSULE_LIVE=1` to try without one.
`ENCAPSULE` selects a different encapsule binary.

```bash
cabal test
```

## Runtime Requirements

- [podman](https://podman.io/) and [buildah](https://buildah.io/)
- An existing (toolbox) container (created with `toolbox create`) or image.
- Alternatively some other non-toolbox container/images may also work.

## Related projects

I already mentioned [toolbox-constrained](https://github.com/swick/toolbox-constrained) from which the initial code was derived.

There is also similarly [schupfn](https://github.com/whot/schupfn/) which uses QEMU to run a toolbox container image in a VM with a direct private ssh connection.

Another somewhat related project is [podenv](https://github.com/podenv/podenv), which "provides a declarative interface to manage containerized applications."

For stronger sandboxing and isolation, specially network, consider using [OpenShell](https://github.com/NVIDIA/OpenShell/). At some point this project might move to wrapping or supporting openshell possibly.

## Disclaimer
The simple isolation provided is limited best effort and
comes with no (security) warranty.
Please use this tool at your own risk.

Reports, suggests, and contributions to improve the tool are very welcome.

## Contribute

`encapsule` is at <https://github.com/juhp/encapsule> and distributed
under the Apache-2.0 license.
