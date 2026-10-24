# deploy/secrets: encrypted .env files

`<env>.env` is a server's `.env`, encrypted with [SOPS](https://github.com/getsops/sops) and
[age](https://age-encryption.org/). Keys stay readable and values are encrypted, so these files are
safe to commit, and a diff shows *which* setting changed without revealing it.

- `recipients.txt` lists the public keys (`age1…`) that may decrypt. It's safe to commit.
- The private keys never come here: each lives at `~/.config/sops/age/keys.txt` (0600) on a machine
  that's allowed to decrypt.

```bash
bin/secrets init                        # once per machine: create a key, add it as a recipient
bin/secrets encrypt production          # this root's .env -> deploy/secrets/production.env
bin/secrets decrypt production          # print it, decrypted
deploy/setup server --env production --secrets deploy/secrets/production.env ...
```

**Why bother:** losing a server must never lose its `CRYPT_KEY`. Without that key, every encrypted
value in the database (payment credentials, API keys) is unreadable for good.

**Adding someone:** they run `bin/secrets init` on their machine and commit the new line in
`recipients.txt`. Someone who can already decrypt then re-encrypts every file:

```bash
bin/secrets decrypt production > /tmp/p.env && bin/secrets encrypt production /tmp/p.env && rm /tmp/p.env
```
