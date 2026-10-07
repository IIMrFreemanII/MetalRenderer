---
name: github-push-account
description: Pushes to IIMrFreemanII/MetalRenderer need the IIMrFreemanII gh account; daria-diahovets gets 403
metadata:
  node_type: memory
  type: reference
  originSessionId: 7003dfc2-161d-4c21-8e65-6953309d9451
  modified: 2026-10-06T22:20:48.903Z
---

The repo is `IIMrFreemanII/MetalRenderer`. `gh` holds several accounts (daria-diahovets, IIMrFreemanII, a stale mykola-diahovets);
only IIMrFreemanII can push. On 2026-10-07 a push as daria-diahovets failed with 403 and the user ran
`gh auth switch -u IIMrFreemanII && gh auth setup-git` themselves.

**How to apply:** on a 403 when pushing, check `gh auth status` and tell the user which account is active. Don't switch
accounts yourself; let the user pick or run the switch.
