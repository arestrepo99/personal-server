# Not secret -- a git remote URL, not a credential. Safe to commit/copy as-is.
# SSH form (not https) because ArgoCD's repo credentials (argocd-repo-credentials.tf)
# authenticate via the deploy key's SSH private key, not a token.
gitops_repo_url = "git@github.com:arestrepo99/personal-server.git"
