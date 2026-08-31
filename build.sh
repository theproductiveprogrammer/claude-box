podman build -t claude-box \
  --build-arg HELIX_REF=gv \
  --build-arg NPM_REGISTRY=https://fsaiartifact.jfrog.io/artifactory/api/npm/atlas-virtual-repository-npm/ \
  --secret id=npmrc,src="$HOME/.npmrc" \
  .
