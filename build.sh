# The problem is public npm is reachable from home but blocked by policy on
# the work network, so one hard-coded registry can't serve both machines. The
# way we solve this is to leave NPM_REGISTRY unset by default (the Dockerfile
# falls back to registry.npmjs.org) and only pass it through when the
# environment sets it, e.g. on the work machine:
#   export NPM_REGISTRY=https://fsaiartifact.jfrog.io/artifactory/api/npm/atlas-virtual-repository-npm/
# That mirror also needs a valid Artifactory auth token in ~/.npmrc.
docker build -t claude-box \
  --build-arg HELIX_REF=gv \
  ${NPM_REGISTRY:+--build-arg NPM_REGISTRY="$NPM_REGISTRY"} \
  --secret id=npmrc,src="$HOME/.npmrc" \
  .
