# Changelog

All notable changes to this project will be documented in this file.

This project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html). The changelog is generated and managed by [sley](https://github.com/indaco/sley).

## v0.3.1 - 2026-04-12

### 🩹 Fixes

- **core/deps:** free orphaned dep strings in resolve BFS ([8c137d2](https://github.com/indaco/malt/commit/8c137d2)) ([#15](https://github.com/indaco/malt/pull/15))

### 📖 Documentation

- **readme:** fix callouts types ([00e8664](https://github.com/indaco/malt/commit/00e8664))
- **readme:** use INFO callouts on the benchmark section ([f7bbb69](https://github.com/indaco/malt/commit/f7bbb69))
- **readme:** fix typos in github callouts types ([e7209f0](https://github.com/indaco/malt/commit/e7209f0))

### ✅ Tests

- raise code coverage ([6d6e4e3](https://github.com/indaco/malt/commit/6d6e4e3)) ([#16](https://github.com/indaco/malt/pull/16))

### ❤️ Contributors

- [@indaco](https://github.com/indaco)

## v0.3.0 - 2026-04-11

### 🚀 Enhancements

- **cli:** add `mt purge` to wipe a malt installation ([a70ccae](https://github.com/indaco/malt/commit/a70ccae)) ([#10](https://github.com/indaco/malt/pull/10))
- **cli:** add backup and restore commands ([16ac579](https://github.com/indaco/malt/commit/16ac579)) ([#7](https://github.com/indaco/malt/pull/7))
- **cli:** add `completions` command for bash, zsh, and fish ([6393b06](https://github.com/indaco/malt/commit/6393b06)) ([#5](https://github.com/indaco/malt/pull/5))
- **install:** download progress bars and materialize spinner ([9a265ad](https://github.com/indaco/malt/commit/9a265ad)) ([#4](https://github.com/indaco/malt/pull/4))

### 🩹 Fixes

- multi-package install correctness sweep ([ea64fc4](https://github.com/indaco/malt/commit/ea64fc4)) ([#11](https://github.com/indaco/malt/pull/11))
- **cli:** honour global --dry-run flag in subcommands ([75da6a6](https://github.com/indaco/malt/commit/75da6a6)) ([#6](https://github.com/indaco/malt/pull/6))

### 📖 Documentation

- **readme:** add demo gif and recording tape ([ab8176e](https://github.com/indaco/malt/commit/ab8176e))
- **readme:** added mt backup and mt restore sections ([fcef76b](https://github.com/indaco/malt/commit/fcef76b)) ([#9](https://github.com/indaco/malt/pull/9))

### ⚡ Performance

- faster warm installs, cleaner install pipeline ([06962ec](https://github.com/indaco/malt/commit/06962ec)) ([#13](https://github.com/indaco/malt/pull/13))

### 🎨 Styling

- **readme:** reformat benchmark tables ([24dc7b2](https://github.com/indaco/malt/commit/24dc7b2))

### 🏡 Chores

- add code coverage tooling (kcov + Codecov) ([f7721f9](https://github.com/indaco/malt/commit/f7721f9)) ([#12](https://github.com/indaco/malt/pull/12))
- **justfile:** add `install` recipe delegating to scripts/install.sh ([4d1fc81](https://github.com/indaco/malt/commit/4d1fc81))
- **devbox:** reuse justfile recipes in shell scripts ([64c1b9d](https://github.com/indaco/malt/commit/64c1b9d)) ([#8](https://github.com/indaco/malt/pull/8))

### Other

- update benchmark results 2026-04-11 ([d78c146](https://github.com/indaco/malt/commit/d78c146))

### ❤️ Contributors

- [@indaco](https://github.com/indaco)
- [@github-actions[bot]](https://github.com/github-actions[bot])

## v0.2.1 - 2026-04-09

### 🩹 Fixes

- **cellar:** always substitute @@HOMEBREW\_\*@@ placeholders in text files ([bbc4cc1](https://github.com/indaco/malt/commit/bbc4cc1)) ([#3](https://github.com/indaco/malt/pull/3))
- **cellar:** resolve nested directory in keg after bottle extraction ([47426a2](https://github.com/indaco/malt/commit/47426a2)) ([#2](https://github.com/indaco/malt/pull/2))

**Full Changelog:** [v0.2.0...v0.2.1](https://github.com/indaco/malt/compare/v0.2.0...v0.2.1)

### ❤️ Contributors

- [@indaco](https://github.com/indaco)

## v0.2.0 - 2026-04-09

### 🚀 Enhancements

- cask command parity for info, outdated, cleanup ([64cac0c](https://github.com/indaco/malt/commit/64cac0c)) ([#1](https://github.com/indaco/malt/pull/1))

### Other

- update benchmark results 2026-04-09 ([71ef557](https://github.com/indaco/malt/commit/71ef557))

### ❤️ Contributors

- [@indaco](https://github.com/indaco)
- [@github-actions[bot]](https://github.com/github-actions[bot])

## v0.1.1 - 2026-04-09

### 🩹 Fixes

- **search:** consistent TUI output and working JSON mode ([1b3daaf](https://github.com/indaco/malt/commit/1b3daaf))
- **net:** use streamRemaining for HTTP body reads ([cbab4bc](https://github.com/indaco/malt/commit/cbab4bc))

### 🤖 CI

- replace deprecated archives.format with archives.formats in goreleaser config ([8ad73e0](https://github.com/indaco/malt/commit/8ad73e0))

### ❤️ Contributors

- [@indaco](https://github.com/indaco)

## v0.1.0 - 2026-04-09

### 🏡 Chores

- Initial Release

### ❤️ Contributors

- [@indaco](https://github.com/indaco)
