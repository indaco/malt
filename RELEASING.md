# Releasing malt

## Release model

malt uses a **tag-driven, single-supported-minor** model.

- **Minor releases** (`v0.X.0`) are cut from `main`.
- **Patch releases** (`v0.X.Y`) are cut from `release/0.X` branches.
- Only the **latest minor line is supported.** When `v0.11.0` ships, `release/0.10` becomes EOL — users on `v0.10.x` are expected to upgrade.

Pushing a `v*` tag is the single trigger for the [release workflow](.github/workflows/release.yml).

## Cutting a minor (from main)

```bash
just lint                                  # gate on a clean tree
sley bump auto && sley changelog merge     # bumps .version, writes .changes/<TAG>.md
sley tag create --push                     # pushes the tag, fires the workflow
# after the workflow goes green:
just release-branch                        # cuts release/0.X from the new tag
```

The `release/0.X` branch is what makes the patch line possible without blocking main.

## Cutting a patch (from release/0.X)

```bash
git checkout release/0.X && git pull
just backport <sha>                        # cherry-pick the squashed fix from main (per fix)
just patch                                 # gate + bump + changelog
# then push + tag as the recipe prints
```

## The pipeline

Six sequential jobs on a `v*` tag push, designed so any pre-promote failure leaves nothing user-visible:

| Job                    | Side effect                                                        | Reversible?         |
| ---------------------- | ------------------------------------------------------------------ | ------------------- |
| `tag-validate`         | Pre-flight: tag shape, `.version`, changelog, source branch.       | n/a                 |
| `goreleaser`           | Builds + signs draft on `indaco/malt`. Cask rendered, not pushed.  | yes (delete draft)  |
| `verify-artifacts`     | Re-verifies cosign + SHA256, runs binaries from the draft tarball. | n/a                 |
| `publish-cask`         | Pushes the rendered cask to `indaco/homebrew-tap`.                 | yes (revert commit) |
| `create-release-notes` | Flips draft → `--latest`, attaches `.changes/<TAG>.md`.            | yes (re-draft)      |
| `install-smoke`        | Runs the README one-liner end-to-end against the live release.     | n/a (post-publish)  |

If any job before `publish-cask` fails, the cask never lands on the tap and the release stays as a draft (or is never created at all) — `install.sh` keeps serving the previous version.

## Rollback

### Pre-flight failure (`tag-validate` red)

Nothing was created — no draft, no tap commit. The bad tag is the only artifact. Drop it and re-tag once the underlying issue is fixed:

```bash
git push --delete origin <TAG>                 # remove the remote tag
git tag -d <TAG>                               # remove the local tag
# fix .version / .changes/<TAG>.md / branch as the error reported, then re-tag
```

### Pre-promote failure (`goreleaser` or `verify-artifacts` red)

A draft release exists on `indaco/malt`. The tap has not been touched.

```bash
gh release delete <TAG> --yes --cleanup-tag    # removes the draft and the tag
```

Fix the root cause and re-tag. No tap action needed.

### Post-promote failure (`install-smoke` red, or a regression reported after release)

The release is live, the cask is on the tap, `install.sh` is serving the broken version.

```bash
just release-rollback <TAG>
```

The recipe, in order:

1. Confirms with you.
2. Flips the release back to draft (`gh release edit --draft=true`). The tag is preserved.
3. Promotes the previous non-draft release back to `--latest`.
4. Reverts the matching commit on `indaco/homebrew-tap` (refuses if the latest tap commit doesn't reference this tag).
5. Prints a checklist of manual follow-ups.

After running:

- Open a tracking issue describing the regression.
- If many users may have installed, consider a README banner.
- Cut a patch release from `release/0.X` with the actual fix.

### Why we don't `--cleanup-tag` post-promote

Once a release is published, deleting the tag breaks anyone who already installed: `cosign verify-blob` against the asset URL still works, but tooling that re-resolves the tag (homebrew, scripts, audits) starts 404'ing. Drafting preserves the tag and the assets so existing installs remain verifiable.
