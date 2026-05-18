# malt smoke scripts

End-to-end exercises for the install / extract / link / record pipeline.
Each script sandboxes into an isolated `MALT_PREFIX` / `MALT_CACHE` so it
never touches the user's real `/opt/malt`.

## GitHub API rate-limit (`MALT_GITHUB_TOKEN`)

Several scripts install or audit third-party-tap formulae or casks. malt
resolves the owning tap's HEAD commit through `api.github.com`, which
caps unauthenticated callers at **60 requests/hour per IP**. A full
suite run (or running the scripts back-to-back against fresh sandboxes)
can exhaust that cap, after which tap resolves fail with:

```
GitHub API rate limit reached. Set MALT_GITHUB_TOKEN to an authorized
GitHub token to lift the 60/hr anonymous cap.
```

Cascading symptoms include "no DMG cask installed", "expected …/.app
after install", and a recorded `casks.tap = ''` — the install dispatcher
silently degraded when the upstream `.rb` was unreachable.

To raise the cap to 5000 req/hour, export a personal-access token (any
scope works for public reads — no `repo` needed):

```sh
export MALT_GITHUB_TOKEN="$(gh auth token)"  # or paste a classic PAT
```

`mt outdated` and `mt upgrade` honour the same env var, so once set
it transparently unblocks every tap-cask path in the suite.
