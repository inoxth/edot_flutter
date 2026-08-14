# Publish both packages in lockstep

Status: accepted

## Context

Two packages are published: `inoxth_edot_flutter` and `inoxth_edot_flutter_dio`. ADR-0010 split
them because Dart has no optional dependencies, so bundling the Dio interceptor would impose Dio's
constraint on every consumer.

That split is a packaging decision, not an independence claim. ADR-0013 has both integrations drive
one shared `EdotRequestTrace`, so the URL sanitizer, both exclusion rules and the propagation
decision are applied in one place and the two transports cannot drift. The Dio package is a thin
adapter over machinery that lives in the core package.

Versioning them independently puts that guarantee back in the hands of whoever cuts the release.
Every core change becomes two judgement calls - does Dio need a release, and does its
`inoxth_edot_flutter: ^x.y.z` constraint need bumping - and the second is invisible until a
consumer resolves a Dio version against a plugin it was never tested with.

pub.dev's automated publishing binds a tag pattern to a package. One version across both packages
means one pattern, `v{{version}}`, and one tag that releases the pair.

## Decision

One version across both packages. One `v{{version}}` tag. Both publish from it, core first.

The release is cut by hand: edit both `version:` fields, edit the Dio package's constraint on core,
write both CHANGELOG entries, commit, tag. A Seam 1 test in the Dio package asserts the invariant -
that both versions match and that the constraint is `^<core version>` - so the edit that is easiest
to forget cannot ship.

## Consequences

- **`melos version` is not used.** It cannot do this. Versioning a package to an explicit version
  drops into an interactive changelog prompt that `--yes` does not skip and that fails outright on
  a non-interactive stdin; `--no-changelog` suppresses the prompt and with it the versioning, so
  nothing happens at all. While `publish_to: none` stands, melos also treats both packages as
  private and filters them out. Its one relevant feature, `--dependent-constraints`, could not be
  reached. This was established by running it, not by reading its help.

- **The CHANGELOGs stay hand-written.** They are prose that explains what changed and why, which is
  not what conventional-commit generation produces. Not using melos costs nothing here.

- **The Dio package gets a version bump when only the core changed.** Accepted deliberately:
  version churn is cheap, and drift between two integrations that share their recording is not.

- **The publish jobs are ordered, not parallel.** The Dio package's `^x.y.z` on core cannot resolve
  until core is live on pub.dev, so publishing them concurrently fails roughly half the time.

- **The first version of each package is published by hand.** pub.dev cannot create a package from
  CI: "you can only automate publishing of existing packages." The pipeline owns every release
  after that.

- **This supersedes ADR-0010's verified-publisher clause, for now.** ADR-0010 states that
  organisation identity comes from the `inoxth_` name prefix *plus a verified publisher*. The
  initial releases publish under an unverified personal uploader account, because creating an
  `inox.co.th` publisher requires Google Search Console access that is not yet in place. Until it
  is, organisation identity rests on the name prefix alone: no publisher badge, and package
  ownership tied to one person's account rather than to the organisation. Migrating to a verified
  publisher remains the intended end state - this is deferred, not abandoned.
