# Visor

Visor is a package manager for Helm. In a file you describe the Helm packages you want to install, and Visor will install those packages appropriately.

See `spec.visor.pkg` for the file format. Visor access data in both YAML and JSON formats.

## Installation

1. Install an implementation of Raku. I suggest using [Rakubrew](https://rakubrew.org/).
2. Install zef. If using Rakubrew, you can do this with `rakubrew build-zef`.
3. Install dependencies -- `zef install YAMLish`
4. Run Visor -- `raku ./visor.raku --help`

## Options

```
--diff -- Print diffs for each package, showing the changes that running the install will make.
--dry-run -- perform an installation dry run.
--template -- output kubernetes template files for each install.
```
