# Cross-repo protocol

Products built on Metaphor span several repos in one session: this
workspace, the framework tree, individual module repos, sibling product
workspaces. This protocol prevents the two classic cross-repo failures:
editing a repo by the wrong repo's rules, and carrying assumptions across
boundaries.

## The law

1. **Read the target repo's own `CLAUDE.md` BEFORE working in it.** Every
   repo in the family may carry one (each app under `apps/`, every clone
   under `modules/`, the framework repos, sibling products). No exceptions —
   even a one-line edit.
2. **The more-local rules win.** Workspace `CLAUDE.md` < app `CLAUDE.md` <
   module `CLAUDE.md`. On conflict, follow the more local file.
3. **Don't carry assumptions across boundaries.** Ports, commands, service
   names, env contracts, codegen rules — verify in the target repo. Two
   repos in the same family can differ on purpose.
4. **Never edit `modules/*` in place.** They are read-only upstream clones;
   local edits are wiped by the next `metaphor sync`. Fix upstream → tag →
   re-pin in `metaphor.yaml` → `metaphor sync --update`.

## Typical targets

| Repo | Role |
|---|---|
| This workspace | the product: apps, deployment, docs |
| Framework repos (`metaphor-cli`, plugin crates) | the `metaphor` CLI and its plugins |
| `backbone-*` module repos | upstream domain modules, pinned by tag |
| Framework crates (`backbone-framework`, …) | the runtime crates services compose |
| Sibling product workspaces | other products on the same framework — same family, different rules |

## When you change upstream

A framework/module fix rides the release train: commit upstream → tag →
bump the pin in this workspace's `metaphor.yaml` → `metaphor sync --update`
→ commit `metaphor.yaml` + `metaphor.lock` together.

The metaphor-agent skill pack is embedded at compile time: after editing
pack assets upstream, rebuild and reinstall the agent binary before
`metaphor agent install` carries the changes into repos.
