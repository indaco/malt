# Releasing malt

## Release model

malt uses a **tag-driven, single-supported-minor** model.

- **Minor releases** (`v0.X.0`) come from `main`.
- **Patch releases** (`v0.X.Y`) come from `release/0.X` branches.
- Only the **latest minor line is supported.** When `v0.11.0` ships, `release/0.10` gets to EOL. Users on `v0.10.x` must upgrade.

A `v*` tag push is the only trigger for the [release workflow](.github/workflows/release.yml).

## Cutting a minor (from main)

```bash
just lint                                  # gate on a clean tree
sley bump auto && sley changelog merge     # bumps .version, writes .changes/<TAG>.md
sley tag create --push                     # pushes the tag, fires the workflow
# after the workflow goes green:
just release-branch                        # cuts release/0.X from the new tag
```

The `release/0.X` branch makes the patch line possible, and it does not block `main`.

## Cutting a patch (from release/0.X)

```bash
git checkout release/0.X && git pull
just backport <sha>                        # cherry-pick the squashed fix from main (per fix)
just patch                                 # gate + bump + changelog
# then push + tag as the recipe prints
```

## The pipeline

A `v*` tag push starts six sequential jobs. If a job fails before the promote step, users see no change:

| Job                    | Side effect                                                        | Reversible?         |
| ---------------------- | ------------------------------------------------------------------ | ------------------- |
| `tag-validate`         | Pre-flight: tag shape, `.version`, changelog, source branch.       | n/a                 |
| `goreleaser`           | Builds + signs draft on `indaco/malt`. Cask rendered, not pushed.  | yes (delete draft)  |
| `verify-artifacts`     | Re-verifies cosign + SHA256, runs binaries from the draft tarball. | n/a                 |
| `publish-cask`         | Pushes the rendered cask to `indaco/homebrew-tap`.                 | yes (revert commit) |
| `create-release-notes` | Flips draft → `--latest`, attaches `.changes/<TAG>.md`.            | yes (re-draft)      |
| `install-smoke`        | Runs the README one-liner end-to-end against the live release.     | n/a (post-publish)  |

If a job before `publish-cask` fails, the cask does not get to the tap. The release stays a draft, or the workflow does not create it. `install.sh` continues to serve the previous version.

## Rollback

### Pre-flight failure (`tag-validate` red)

The workflow created nothing: no draft and no tap commit. The bad tag is the only artifact. Delete the tag. When you have fixed the cause, tag again:

```bash
git push --delete origin <TAG>                 # remove the remote tag
git tag -d <TAG>                               # remove the local tag
# fix .version / .changes/<TAG>.md / branch as the error reported, then re-tag
```

### Pre-promote failure (`goreleaser` or `verify-artifacts` red)

A draft release exists on `indaco/malt`. The tap has no change.

```bash
gh release delete <TAG> --yes --cleanup-tag    # removes the draft and the tag
```

Fix the root cause and tag again. The tap needs no action.

### Post-promote failure (`install-smoke` red, or a regression reported after release)

The release is live, the cask is on the tap, and `install.sh` serves the broken version.

```bash
just release-rollback <TAG>
```

The recipe does these steps in this order:

1. It asks you to confirm.
2. It changes the release back to a draft (`gh release edit --draft=true`). The tag stays.
3. It promotes the previous non-draft release back to `--latest`.
4. It reverts the matching commit on `indaco/homebrew-tap`. If the latest tap commit does not refer to this tag, it stops.
5. It prints a checklist of manual follow-up tasks.

After the recipe:

- Open a tracking issue that describes the regression.
- If the release possibly reached many users, consider a README banner.
- Make a patch release from `release/0.X` with the real fix.

### Why we don't `--cleanup-tag` post-promote

After a release is published, a tag deletion breaks existing installs. `cosign verify-blob` against the asset URL still works. But tools that resolve the tag again (homebrew, scripts, audits) start to get 404 errors. A draft keeps the tag and the assets, so you can still verify existing installs.
