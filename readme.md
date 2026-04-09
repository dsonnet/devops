curl -o /tmp/bootstrap-server.sh \
  https://raw.githubusercontent.com/Smartoys/devops/main/scripts/bootstrap-server.sh

bash /tmp/bootstrap-server.sh \
  --pubkey "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIG8CMRMKE9vCerU63mDl9K/i+Wd0HEcwLsY/oL0Kk9/k github-actions-deploy" \
  --tunnel-token "eyJ..." \
  --email "david@kemushi.eu" \
  --cf-token "cfut_..."