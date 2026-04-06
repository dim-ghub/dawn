```bash
rm -rf $HOME/dawn
```

```bash
git config --global user.name "dusk" && git config --global user.email "dusk1@myyahoo.com" && git config --global init.defaultBranch main
```

```bash
ssh-keygen -t ed25519 -C "dusk1@myyahoo.com"
```

```bash
eval "$(ssh-agent -s)"
```

```bash
cat ~/.ssh/id_ed25519.pub
```

save to pgp key on github

```bash
git clone --bare git@github.com:dim-ghub/dawn.git $HOME/dawn
```

type yes

```bash
git_dawn config --local status.showUntrackedFiles no
```

```bash
git_dawn status
```

```bash
git_dawn reset
```

```bash
git_dawn status
```

```bash
git_dawn_add_list && git_dawn commit -m "fresh install first commit to the same old git repo"
```

```bash
git_dawn remote add origin git@github.com:dim-ghub/dawn.git
```

```bash
git_dawn remote set-url origin git@github.com:dim-ghub/dawn.git
```

```bash
ssh -T git@github.com
```

```bash
git_dawn push -u origin main
```